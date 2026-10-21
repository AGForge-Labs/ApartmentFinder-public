"""Exercise the unsigned bundle receipt with invented, credential-free files."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


class UnsignedReceiptTests(unittest.TestCase):
    def run_receipt(self, mutation=None):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        marker = '          import hashlib,json,os,plistlib,sys\n'
        receipt = marker + workflow.split(marker, 1)[1].split('          PY\n', 1)[0]
        receipt = textwrap.dedent(receipt)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'Fictional.app'
            share = app / 'PlugIns/ApartmentFinderShare.appex'
            share.mkdir(parents=True)
            resources = {}
            for name in ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson', 'known-addresses.json'):
                data = ('fictional-' + name).encode()
                (app / name).write_bytes(data)
                resources[name] = hashlib.sha256(data).hexdigest()
            (share / 'known-addresses.json').write_bytes((app / 'known-addresses.json').read_bytes())
            for bundle, identity in ((app, 'dev.galaxybigbird.ApartmentFinder'),
                                     (share, 'dev.galaxybigbird.ApartmentFinder.Share')):
                (bundle / 'Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleIdentifier': identity, 'CFBundleExecutable': 'FictionalExecutable'}))
                (bundle / 'FictionalExecutable').write_bytes(b'fictional-binary')
            (root / 'data').mkdir()
            (root / 'data/public-catalog-review.json').write_text(json.dumps({'resourcesSHA256': resources}))
            if mutation:
                mutation(app, share)
            return subprocess.run([sys.executable, '-B', '-c', receipt, str(app)], cwd=root,
                env={**os.environ, 'EXPECTED_COMMIT': 'a' * 40}, text=True, capture_output=True, timeout=5)

    def test_unsigned_receipt_requires_matching_app_share_and_resources(self):
        result = self.run_receipt()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            'scope': 'unsigned-release-app-and-share', 'candidate': 'a' * 40,
            'app': True, 'embeddedShare': True, 'resourcesMatch': True,
            'distributionSigning': False, 'upload': False,
            'full_acceptance': False, 'release_eligible': False})

    def test_wrong_resource_binary_bundle_or_signature_cannot_produce_a_success_receipt(self):
        mutations = [lambda app, share: (app / 'public-catalog.json').write_bytes(b'changed'),
            lambda app, share: (share / 'known-addresses.json').write_bytes(b'changed'),
            lambda app, share: (share / 'FictionalExecutable').unlink(),
            lambda app, share: (app / '_CodeSignature').mkdir(),
            lambda app, share: (share / '_CodeSignature').mkdir(),
            lambda app, share: (share / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'org.example.wrong', 'CFBundleExecutable': 'FictionalExecutable'}))]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                result = self.run_receipt(mutation)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('resourcesMatch', result.stdout)

    def test_unsigned_step_remains_exact_source_and_credential_free(self):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        step = workflow.split('      - name: Build unsigned Release app and embedded Share extension', 1)[1]
        self.assertIn('[[ "$(git rev-parse HEAD)" == "$EXPECTED_COMMIT" ]]', step)
        self.assertIn('CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build', step)
        self.assertIn('scripts/validate-checkout.py', step)
        for forbidden in ('secrets.', 'authorize_upload', 'sign-upload', 'upload-artifact', 'release_eligible=True'):
            self.assertNotIn(forbidden, step)


if __name__ == '__main__':
    unittest.main()
