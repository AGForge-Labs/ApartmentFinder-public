import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('recovery', ROOT/'scripts/public-release-recovery.py')
recovery = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(recovery)


def evidence():
    passed = dict(id=recovery.PASS_RUN, head_sha=recovery.BASE, run_attempt=2, workflow_id=388994070,
                  path='.github/workflows/public-synthetic-check.yml', status='completed', conclusion='success',
                  repository=dict(full_name=recovery.REPO, private=False))
    jobs = dict(total_count=1, jobs=[dict(id=119312538227,head_sha=recovery.BASE,run_attempt=2,status='completed',conclusion='success',
                steps=[dict(name=name,status='completed',conclusion='success') for name in recovery.REQUIRED_STEPS])])
    failed = dict(id=recovery.FAILED_RUN,head_sha=recovery.BASE,run_attempt=1,workflow_id=390747513,status='completed',conclusion='cancelled')
    failed_jobs = dict(total_count=2,jobs=[dict(name='validate',conclusion='cancelled'),dict(name='release',conclusion='skipped')])
    return [passed,jobs,failed,failed_jobs]


class PublicReleaseRecoveryTests(unittest.TestCase):
    def test_only_fixed_prior_pass_and_known_pre_sign_failure_are_reusable(self):
        recovery.verify_evidence(*evidence())
        for key,value in [('head_sha','b'*40),('run_attempt',1),('conclusion','failure'),('status','in_progress'),('workflow_id',1)]:
            changed=evidence();changed[0][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError): recovery.verify_evidence(*changed)

    def test_unsigned_build_and_exact_job_are_required(self):
        changed=evidence();changed[1]['jobs'][0]['steps']=[]
        with self.assertRaises(ValueError): recovery.verify_evidence(*changed)
        changed=evidence();changed[1]['jobs'][0]['id']=1
        with self.assertRaises(ValueError): recovery.verify_evidence(*changed)

    def test_active_or_uncertain_prior_upload_is_rejected(self):
        for outcome in ('success','in_progress','failure',None):
            changed=evidence();changed[3]['jobs'][1]['conclusion']=outcome
            with self.subTest(outcome=outcome),self.assertRaises(ValueError): recovery.verify_evidence(*changed)

    def test_application_data_tests_signing_and_configuration_must_be_unchanged(self):
        recovery.verify_changes(sorted(recovery.ALLOWED))
        for path in ('App/ApartmentDeliveryMap.swift','data/public-catalog.json','UITests/MapAppearanceTests.swift',
                     'scripts/public-release.py','scripts/testflight.py','Config/TestFlight.json','project-testflight.yml'):
            with self.subTest(path=path),self.assertRaises(ValueError): recovery.verify_changes([path])

    def test_normal_application_validation_and_environment_boundary_remain(self):
        workflow=(ROOT/'.github/workflows/public-testflight.yml').read_text()
        self.assertIn('if: ${{ !inputs.accept_known_map_regression }}',workflow)
        self.assertIn('run: bash scripts/public-release-validation.sh',workflow)
        self.assertIn("needs.validate.result == 'success'",workflow)
        self.assertIn('name: release',workflow)
        self.assertIn('run: python3 -B scripts/public-release.py sign-upload',workflow)
