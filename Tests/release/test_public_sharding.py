"""Check actual workflow selection and aggregation without hosted actions."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
PUBLIC = '.github/workflows/public-synthetic-check.yml'
RELEASE = '.github/workflows/public-testflight.yml'
SCRIPT = 'scripts/public-release-validation.sh'


def selection_code(path):
    body = (ROOT / path).read_text()
    header = 'python3 -B - "$RUNNER_TEMP/selected-tests.json" <<\'PY\'\n'
    tail = body.split(header, 1)[1]
    end = '\n          PY' if path == PUBLIC else '\nPY'
    return textwrap.dedent(tail.split(end, 1)[0])


class PublicShardingTests(unittest.TestCase):
    def run_selection(self, path, count, index, profile=None, scope='regression'):
        profile = profile or json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'scripts').mkdir()
            (root / 'scripts/public-synthetic-tests.json').write_text(json.dumps(profile))
            output = root / 'selection.json'
            result = subprocess.run([sys.executable, '-B', '-', str(output)],
                input=selection_code(path), cwd=root, text=True, capture_output=True,
                env={**os.environ, 'PUBLIC_SYNTHETIC_SCOPE': scope,
                     'PUBLIC_TEST_SHARD_COUNT': str(count), 'PUBLIC_TEST_SHARD_INDEX': str(index)}, timeout=5)
            return result.returncode, json.loads(output.read_text()) if output.exists() else None

    def test_both_callers_cover_exact_manifest_once_across_four_shards(self):
        profile = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        for path in (PUBLIC, SCRIPT):
            union = []
            for index, count in enumerate((23, 23, 22, 22)):
                status, selected = self.run_selection(path, 4, index)
                self.assertEqual(status, 0)
                self.assertEqual(selected['native'], profile['native'][index::4])
                self.assertEqual(selected['ui'], profile['ui'][index::4])
                current = selected['native'] + selected['ui']
                self.assertEqual(len(current), count)
                union += current
            self.assertEqual(len(union), len(set(union)))
            self.assertEqual(set(union), set(profile['native'] + profile['ui']))

    def test_unsharded_calls_preserve_existing_manifest(self):
        profile = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        for path in (PUBLIC, SCRIPT):
            status, selected = self.run_selection(path, 1, 0)
            self.assertEqual(status, 0)
            self.assertEqual(selected, profile)

    def test_invalid_index_count_duplicate_and_missing_manifest_fail_closed(self):
        profile = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        duplicate = json.loads(json.dumps(profile)); duplicate['native'][1] = duplicate['native'][0]
        missing = json.loads(json.dumps(profile)); missing['ui'].pop()
        for path in (PUBLIC, SCRIPT):
            for count, index, source in [(0,0,profile),(2,0,profile),(4,-1,profile),(4,4,profile),(1,1,profile),(4,0,duplicate),(4,0,missing)]:
                with self.subTest(path=path,count=count,index=index):
                    status, selected = self.run_selection(path,count,index,source)
                    self.assertNotEqual(status,0)
                    self.assertIsNone(selected)

    def test_focused_scope_remains_original_three_identities(self):
        for path in (PUBLIC, SCRIPT):
            status, selected = self.run_selection(path,1,0,scope='activation-diagnostics')
            self.assertEqual(status,0)
            self.assertEqual(len(selected['native']),2)
            self.assertEqual(len(selected['ui']),1)

    def test_each_aggregate_executes_fail_closed_for_every_non_success_outcome(self):
        for path, job, child in ((PUBLIC,'synthetic','synthetic_shard'),(RELEASE,'validate','validate_shard')):
            body=(ROOT/path).read_text().split('  '+job+':\n',1)[1].split('\n  release:',1)[0]
            self.assertIn('needs: '+child,body)
            self.assertIn('if: ${{ always() }}',body)
            block=textwrap.dedent(body.split('        run: |\n',1)[1])
            for result in ('success','failure','cancelled','skipped',''):
                run=subprocess.run([shutil.which('bash'),'--noprofile','--norc','-c',block],env={**os.environ,'VALIDATION_RESULT':result},capture_output=True,timeout=5)
                self.assertEqual(run.returncode==0,result=='success')

    def test_release_still_depends_on_aggregate_and_protected_environment(self):
        body=(ROOT/RELEASE).read_text()
        release=body.split('  release:\n',1)[1]
        self.assertIn('needs: validate',release)
        self.assertIn("needs.validate.result == 'success'",release)
        self.assertIn('name: release',release)
        self.assertIn('RELEASE_ACCEPTED_COMMIT: ${{ vars.RELEASE_ACCEPTED_COMMIT }}',release)
        self.assertIn('run: python3 -B scripts/public-release.py sign-upload',release)
        for path in (PUBLIC,RELEASE):
            workflow=(ROOT/path).read_text()
            self.assertIn('max-parallel: 4',workflow)
            self.assertIn('fail-fast: false',workflow)
            self.assertNotIn('continue-on-error',workflow)
