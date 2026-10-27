import hashlib
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/testflight-artifact.py'
spec = importlib.util.spec_from_file_location('testflight_artifact', SCRIPT)
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


class PreservedArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        # Verifier unit tests inspect synthetic resource digests, never the owner's
        # private catalog. This directory is not native or release acceptance.
        self.fixture_root = self.directory / 'synthetic-checkout'
        for folder in ('Config', 'NativeTests', 'UITests'):
            shutil.copytree(ROOT / folder, self.fixture_root / folder)
        (self.fixture_root / 'data').mkdir()
        for name in ('catalog.json', 'locations.geojson', 'paths.geojson'):
            (self.fixture_root / 'data' / name).write_text(json.dumps({'synthetic-verifier-resource': name}))
        signed = self.directory / 'testflight'
        signed.mkdir()
        ipa = signed / 'ApartmentFinder-TestFlight.ipa'
        ipa.write_bytes(b'fixture-signed-ipa')
        self.commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        config = json.loads((self.fixture_root / 'Config/TestFlight.json').read_text(encoding='utf-8'))
        self.actual = {
            'bundle_id': config['bundle_id'], 'team_id': config['team_id'],
            'version': config['marketing_version'], 'build_number': '12.1',
            'ipa_sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
            'resources_sha256': {
                name: hashlib.sha256((self.fixture_root / 'data' / name).read_bytes()).hexdigest()
                for name in ('catalog.json', 'locations.geojson', 'paths.geojson')
            },
        }
        self.write_manifest()
        (signed / 'SHA256.txt').write_text(self.actual['ipa_sha256'] + '  ApartmentFinder-TestFlight.ipa\n')
        self.summary = {'result': 'Passed', 'passedTests': 140, 'totalTestCount': 140,
                        'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0}
        self.write_summary()
        attachments = self.directory / 'test-attachments'
        attachments.mkdir()
        records = []
        for index, (test, names) in enumerate(artifact.REQUIRED_SCREENSHOTS.items()):
            items = []
            for offset, name in enumerate(names):
                filename = f'{index}-{offset}.png'
                (attachments / filename).write_bytes(b'fixture-image')
                items.append({'suggestedHumanReadableName': name, 'exportedFileName': filename})
            records.append({'testIdentifier': test, 'attachments': items})
        (attachments / 'manifest.json').write_text(json.dumps(records))

    def write_manifest(self):
        (self.directory / 'testflight' / 'build-manifest.json').write_text(
            json.dumps(dict(self.actual, commit=self.commit)))

    def write_summary(self):
        (self.directory / 'test-summary.json').write_text(json.dumps(self.summary))

    def verify(self, digest=None):
        # Git provenance is independent of resource hashing in this isolated unit
        # fixture; command-line tests below still exercise the real checkout HEAD.
        checkout_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True)
        with patch.object(artifact.subprocess, 'check_output', return_value=checkout_commit):
            return artifact.verify(self.directory, '12.1', digest or self.actual['ipa_sha256'],
                                   root=self.fixture_root, commit=self.commit,
                                   inspect=lambda _ipa, _config, _version: self.actual)

    def test_exact_signed_build_and_reviewed_screenshots_pass(self):
        result = self.verify()
        self.assertEqual(result['native_tests'], 140)
        self.assertEqual(result['required_screenshots'], 48)

    def test_native_evidence_can_be_checked_without_signing_or_an_ipa(self):
        (self.directory / 'testflight' / 'ApartmentFinder-TestFlight.ipa').unlink()
        result = artifact.verify_native_evidence(self.directory, root=ROOT)
        self.assertEqual(result, {'native_tests': 140, 'required_screenshots': 48})

    def test_native_only_command_checks_evidence_without_entering_signing(self):
        (self.directory / 'testflight' / 'ApartmentFinder-TestFlight.ipa').unlink()
        command = [sys.executable, '-B', str(SCRIPT), str(self.directory), '--native-only']
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True,
                                env=dict(os.environ, GITHUB_SHA=self.commit))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout),
                         {'commit': self.commit, 'native_tests': 140, 'required_screenshots': 48})
        result = subprocess.run(command + ['--write-outputs'], cwd=ROOT, text=True,
                                capture_output=True, env=dict(os.environ, GITHUB_SHA=self.commit))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Native-only checks cannot write upload outputs', result.stderr)
        for commit, message in (('', 'Missing exact validation commit'),
                                ('0' * 40, 'Checkout differs from validation commit')):
            with self.subTest(commit=commit):
                result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True,
                                        env=dict(os.environ, GITHUB_SHA=commit))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_native_gate_rejects_old_or_incomplete_simulator_runs(self):
        valid = dict(self.summary)
        for changes in ({'passedTests': 38, 'totalTestCount': 38},
                        {'passedTests': 51, 'totalTestCount': 51},
                        {'passedTests': 61, 'totalTestCount': 61},
                        {'passedTests': 63, 'totalTestCount': 63},
                        {'passedTests': 64, 'totalTestCount': 64},
                        {'passedTests': 65, 'totalTestCount': 65},
                        {'passedTests': 66, 'totalTestCount': 66},
                        {'passedTests': 74, 'totalTestCount': 74},
                        {'passedTests': 75, 'totalTestCount': 75},
                        {'passedTests': 84, 'totalTestCount': 84},
                        {'passedTests': 87, 'totalTestCount': 87},
                        {'passedTests': 89, 'totalTestCount': 89},
                        {'passedTests': 90, 'totalTestCount': 90},
                        {'passedTests': 94, 'totalTestCount': 94},
                        {'passedTests': 95, 'totalTestCount': 95},
                        {'passedTests': 97, 'totalTestCount': 97},
                        {'passedTests': 98, 'totalTestCount': 98},
                        {'passedTests': 105, 'totalTestCount': 105},
                        {'passedTests': 108, 'totalTestCount': 108},
                        {'passedTests': 114, 'totalTestCount': 114},
                        {'passedTests': 115, 'totalTestCount': 115},
                        {'passedTests': 125, 'totalTestCount': 125},
                        {'passedTests': 131, 'totalTestCount': 131},
                        {'passedTests': 137, 'totalTestCount': 137},
                        {'passedTests': 60}, {'result': 'Failed'},
                        {'failedTests': 1}, {'skippedTests': 1}, {'expectedFailures': 1}):
            with self.subTest(changes=changes):
                self.summary = dict(valid, **changes)
                self.write_summary()
                with self.assertRaisesRegex(ValueError, 'Simulator suite'):
                    artifact.verify_native_evidence(self.directory, root=ROOT)

    def test_native_gate_rejects_duplicate_or_escaping_screenshots(self):
        manifest = self.directory / 'test-attachments' / 'manifest.json'
        records = json.loads(manifest.read_text())
        records[0]['attachments'].append(dict(records[0]['attachments'][0]))
        manifest.write_text(json.dumps(records))
        with self.assertRaisesRegex(ValueError, 'Missing or duplicate screenshot'):
            artifact.verify_native_evidence(self.directory, root=ROOT)
        records[0]['attachments'].pop()
        (self.directory / 'outside.png').write_bytes(b'fixture-image')
        records[0]['attachments'][0]['exportedFileName'] = '../outside.png'
        manifest.write_text(json.dumps(records))
        with self.assertRaisesRegex(ValueError, 'Screenshot missing or outside artifact'):
            artifact.verify_native_evidence(self.directory, root=ROOT)

    def test_selected_stop_completion_requires_its_screenshot_evidence(self):
        test = 'ApartmentMiniRouteTests/testTappedLaterMapPinCompletesSelectedUnitAndReturnsToFirstPendingStop()'
        self.assertIn(test, artifact.REQUIRED_SCREENSHOTS)
        self.assertEqual(len(artifact.REQUIRED_SCREENSHOTS[test]), 3)
        manifest = self.directory / 'test-attachments' / 'manifest.json'
        records = json.loads(manifest.read_text())
        selected = next(record for record in records if record['testIdentifier'] == test)
        selected['attachments'].pop()
        manifest.write_text(json.dumps(records))
        with self.assertRaisesRegex(ValueError, 'Missing or duplicate screenshot'):
            artifact.verify_native_evidence(self.directory, root=ROOT)

    def test_spanish_ridge_sections_require_their_screenshot_evidence(self):
        test = 'FinderTabTests/testSpanishRidgeSectionsRemainDistinctAndDisputedBuildingStaysUnknown()'
        self.assertEqual(len(artifact.REQUIRED_SCREENSHOTS[test]), 3)
        manifest = self.directory / 'test-attachments' / 'manifest.json'
        records = json.loads(manifest.read_text())
        selected = next(record for record in records if record['testIdentifier'] == test)
        original = list(selected['attachments'])
        for missing in original:
            with self.subTest(name=missing['suggestedHumanReadableName']):
                selected['attachments'] = [item for item in original if item != missing]
                manifest.write_text(json.dumps(records))
                with self.assertRaisesRegex(ValueError, 'Missing or duplicate screenshot'):
                    artifact.verify_native_evidence(self.directory, root=ROOT)

    def test_heading_up_evidence_requires_camera_arrow_pause_delivery_undo_and_resume(self):
        names = (
            'Mini-route starts facing synthetic west with blue direction arrow',
            'Show-all north-up map keeps the west-pointing blue arrow',
            'Heading-up delivery advances selected unit and retains following',
            'Panned mini-route remains paused across GPS updates',
            'Mini-route Undo restores stops while following stays paused',
            'Resume following restores west-up camera after manual pan',
            "Heading-up Resume preserves the user's zoom",
        )
        manifest = self.directory / 'test-attachments' / 'manifest.json'
        original = json.loads(manifest.read_text())
        for name in names:
            with self.subTest(missing=name):
                records = json.loads(json.dumps(original))
                removed = 0
                for record in records:
                    old = record['attachments']
                    record['attachments'] = [a for a in old if a['suggestedHumanReadableName'] != name]
                    removed += len(old) - len(record['attachments'])
                self.assertEqual(removed, 1, 'Each expected heading-up screenshot must exist in the valid artifact')
                manifest.write_text(json.dumps(records))
                with self.assertRaisesRegex(ValueError, 'Missing or duplicate screenshot'):
                    artifact.verify_native_evidence(self.directory, root=ROOT)

    def test_estimated_entry_regions_require_both_qualified_outcome_screenshots(self):
        test = 'EstimatedEntranceSideUITests/testEstimatedEntryRegionsKeepStreetFloorAndSharedDoorUncertaintyVisible()'
        names = (
            'Copper Creek estimates retain exact streets and qualified floors',
            'Lyric pair remains ambiguous and unit 1287 has no invented point',
        )
        self.assertEqual(artifact.REQUIRED_SCREENSHOTS[test], names)
        manifest = self.directory / 'test-attachments' / 'manifest.json'
        original = json.loads(manifest.read_text())
        for name in names:
            with self.subTest(missing=name):
                records = json.loads(json.dumps(original))
                selected = next(record for record in records if record['testIdentifier'] == test)
                self.assertEqual(sum(item['suggestedHumanReadableName'] == name for item in selected['attachments']), 1)
                selected['attachments'] = [item for item in selected['attachments']
                                           if item['suggestedHumanReadableName'] != name]
                manifest.write_text(json.dumps(records))
                with self.assertRaisesRegex(ValueError, 'Missing or duplicate screenshot'):
                    artifact.verify_native_evidence(self.directory, root=ROOT)

    def test_wrong_commit_or_ipa_digest_cannot_be_uploaded(self):
        self.commit = '0' * 40
        with self.assertRaisesRegex(ValueError, 'Checkout differs'):
            self.verify()
        self.commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        with self.assertRaisesRegex(ValueError, 'Preserved IPA differs'):
            self.verify('1' * 64)

    def test_missing_test_evidence_and_changed_data_are_rejected(self):
        self.summary['skippedTests'] = 1
        self.write_summary()
        with self.assertRaisesRegex(ValueError, 'failures or skips'):
            self.verify()
        self.summary['skippedTests'] = 0
        self.write_summary()
        (self.directory / 'test-attachments' / '0-0.png').unlink()
        with self.assertRaisesRegex(ValueError, 'Screenshot missing'):
            self.verify()
        (self.directory / 'test-attachments' / '0-0.png').write_bytes(b'fixture-image')
        self.actual['resources_sha256']['catalog.json'] = 'f' * 64
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'Bundled catalog.json differs'):
            self.verify()


if __name__ == '__main__':
    unittest.main()
