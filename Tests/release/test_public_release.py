import contextlib
import importlib.util
import io
import hashlib
import json
from types import SimpleNamespace
from unittest.mock import patch
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("public_release", ROOT / "scripts/public-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = "a" * 40

def request():
    return {
        "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS",
        "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REPOSITORY": release.REPOSITORY, "GITHUB_REF": "refs/heads/main",
        "GITHUB_WORKFLOW_REF": release.REPOSITORY + "/.github/workflows/public-testflight.yml@refs/heads/main",
        "GITHUB_WORKFLOW_SHA": SHA, "GITHUB_SHA": SHA, "EXPECTED_COMMIT": SHA,
        "GITHUB_ACTOR_ID": "105477711", "GITHUB_TRIGGERING_ACTOR": "Galaxybigbird",
        "GITHUB_RUN_ATTEMPT": "1", "RELEASE_AUTHORIZED": "true",
        "RELEASE_BUILD_NUMBER": "100.1", "RELEASE_ENVIRONMENT": "release",
        "RELEASE_ACCEPTED_COMMIT": SHA,
    }

class PublicReleaseTests(unittest.TestCase):
    def test_only_exact_owner_dispatched_reviewed_default_branch_is_allowed(self):
        self.assertEqual(release.validate_context(request(), signing=True), "100.1")

    def test_wrong_repo_fork_event_owner_ref_workflow_sha_and_rerun_are_rejected(self):
        changes = {
            "GITHUB_ACTIONS": "false", "RUNNER_OS": "Linux",
            "RUNNER_ENVIRONMENT": "self-hosted", "GITHUB_EVENT_NAME": "pull_request_target",
            "GITHUB_REPOSITORY": "attacker/fork", "GITHUB_REF": "refs/heads/feature",
            "GITHUB_WORKFLOW_REF": release.REPOSITORY + "/.github/workflows/other.yml@refs/heads/main",
            "GITHUB_WORKFLOW_SHA": "b" * 40, "GITHUB_SHA": "b" * 40,
            "EXPECTED_COMMIT": "main", "GITHUB_ACTOR_ID": "1",
            "GITHUB_TRIGGERING_ACTOR": "another-user", "GITHUB_RUN_ATTEMPT": "2",
            "RELEASE_AUTHORIZED": "false",
        }
        for key, value in changes.items():
            with self.subTest(field=key), self.assertRaises(ValueError):
                release.validate_context({**request(), key: value}, signing=True)

    def test_signing_requires_accepted_commit_in_release_environment(self):
        for field in ("RELEASE_ACCEPTED_COMMIT", "RELEASE_ENVIRONMENT"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.validate_context({**request(), field: ""}, signing=True)
        env = request()
        env.pop("RELEASE_ACCEPTED_COMMIT")
        env.pop("RELEASE_ENVIRONMENT")
        self.assertEqual(release.validate_context(env), "100.1")

    def test_build_numbers_cannot_inject_commands_or_restart_at_public_run_one(self):
        for value in ("", "0", "1; echo private", "../1", "1.100", "1.2.3.4"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.validate_context({**request(), "RELEASE_BUILD_NUMBER": value})
        if "OfflineTikTokPlayer" in release.REPOSITORY:
            with self.assertRaises(ValueError):
                release.validate_context({**request(), "RELEASE_BUILD_NUMBER": "13.1"})

    def test_private_inputs_and_pack_overrides_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            release.reject_private_inputs(path, {})
            (path / "private-data").mkdir()
            with self.assertRaises(ValueError):
                release.reject_private_inputs(path, {})
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                release.reject_private_inputs(Path(folder), {"APARTMENTFINDER_PRIVATE_PACK_DIRECTORY": "private"})

    def test_child_output_and_errors_never_publish_raw_signing_material(self):
        output = io.StringIO()
        command = [sys.executable, "-c", "print('PRIVATE-OUTPUT-MARKER'); raise SystemExit(9)"]
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(RuntimeError) as error:
                release.run_redacted(command, env=dict(os.environ), cwd=ROOT)
        self.assertNotIn("PRIVATE-OUTPUT-MARKER", output.getvalue() + str(error.exception))

    def test_successful_child_output_is_also_suppressed(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            release.run_redacted([sys.executable, "-c", "print('PRIVATE-OUTPUT-MARKER')"],
                                 env=dict(os.environ), cwd=ROOT)
        self.assertNotIn("PRIVATE-OUTPUT-MARKER", output.getvalue())

    def test_signed_package_must_match_exact_public_resources_commit_and_build(self):
        actual = {"build_number": "100.1", "resources_sha256": {"public-catalog.json": "digest"}}
        manifest = {**actual, "commit": SHA}
        release.validate_package_manifest(manifest, actual, actual["resources_sha256"], request())
        for bad in ({**manifest, "commit": "b" * 40}, {**manifest, "build_number": "1.1"}):
            with self.assertRaises(ValueError):
                release.validate_package_manifest(bad, actual, actual["resources_sha256"], request())
        with self.assertRaises(ValueError):
            release.validate_package_manifest(manifest, actual, {"public-catalog.json": "tampered"}, request())

    def test_reviewed_ipa_resources_match_checkout_before_upload_key(self):
        names = ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson',
                 'known-addresses.json', 'reviewed-progress-catalog.json',
                 'reviewed-progress-locations.geojson', 'reviewed-progress-paths.geojson',
                 'reviewed-baseline-manifest.json', 'reviewed-baseline-catalog.json',
                 'reviewed-baseline-locations.geojson', 'reviewed-baseline-paths.geojson')
        resources = {name: hashlib.sha256(('synthetic:' + name).encode()).hexdigest() for name in names}
        bad_sets = [('all reviewed files missing', {name: digest for name, digest in resources.items()
                     if not name.startswith('reviewed-')})]
        for name in names[-7:]:
            bad_sets.append((name + ' missing', {key: value for key, value in resources.items() if key != name}))
            bad_sets.append((name + ' changed', {**resources, name: '0' * 64}))
        for label, ipa_resources in [('complete', resources), *bad_sets]:
            with self.subTest(case=label), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root / 'Config').mkdir()
                (root / 'Config/TestFlight.json').write_text('{}')
                (root / 'data').mkdir()
                for name in names:
                    (root / 'data' / name).write_bytes(('synthetic:' + name).encode())
                output = root / 'build/testflight'
                output.mkdir(parents=True)
                actual = {'build_number': '100.1', 'resources_sha256': ipa_resources}
                (output / 'build-manifest.json').write_text(json.dumps({**actual, 'commit': SHA}))
                signing = SimpleNamespace(inspect_ipa=lambda *_: actual)
                with patch.object(release, 'ROOT', root), patch.object(release, 'load_script', return_value=signing), \
                     patch.object(release, 'run_redacted') as command:
                    if label == 'complete':
                        release.perform_release({**request(), 'RUNNER_TEMP': folder}, '100.1')
                    else:
                        with self.assertRaises(ValueError):
                            release.perform_release({**request(), 'RUNNER_TEMP': folder}, '100.1')
                calls = [call.args[0] for call in command.call_args_list]
                self.assertEqual(any('prepare-upload-key' in call for call in calls), label == 'complete')
                self.assertEqual(any('deliver' in call for call in calls), label == 'complete')
                self.assertTrue(any(str(root / 'scripts/testflight-cleanup.sh') in call for call in calls))

    def test_public_signing_uses_explicit_build_instead_of_reset_workflow_number(self):
        signing = release.load_script("testflight")
        env = {**request(), "PUBLIC_RELEASE_CONTEXT": "true", "GITHUB_RUN_NUMBER": "1"}
        self.assertEqual(signing.requested_build(env), "100.1")
        with self.assertRaises(ValueError):
            signing.requested_build({**env, "RELEASE_ACCEPTED_COMMIT": ""})

if __name__ == "__main__":
    unittest.main()
