"""One fixed-source recovery. Application tests are reused, never reported as rerun."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BASE = 'd7f43ed3729e4006035e8d85f813429b84b5b9af'
PASS_RUN = 39615213146
FAILED_RUN = 39637858856
REPO = 'AGForge-Labs/ApartmentFinder-public'
ALLOWED = {'.github/workflows/public-testflight.yml', 'scripts/public-release-recovery.py',
           'Tests/release/test_public_release_recovery.py'}
REQUIRED_STEPS = {'Selected synthetic core tests with exact identity verification',
                  'Compile production targets and run only synthetic native and UI tests',
                  'Build unsigned Release app and embedded Share extension'}


def require(condition):
    if not condition:
        raise ValueError('Fixed-source release recovery verification failed')


def verify_changes(changed):
    require(type(changed) is list and changed and set(changed) <= ALLOWED and len(changed) == len(set(changed)))


def verify_evidence(passed, jobs, failed, failed_jobs):
    require(passed.get('id') == PASS_RUN and passed.get('head_sha') == BASE and passed.get('run_attempt') == 2)
    require(passed.get('workflow_id') == 388994070 and passed.get('path') == '.github/workflows/public-synthetic-check.yml')
    require(passed.get('status') == 'completed' and passed.get('conclusion') == 'success')
    require(passed.get('repository', {}).get('full_name') == REPO and passed['repository'].get('private') is False)
    require(jobs.get('total_count') == 1 and len(jobs.get('jobs', [])) == 1)
    job = jobs['jobs'][0]
    require(job.get('id') == 119312538227 and job.get('head_sha') == BASE and job.get('run_attempt') == 2)
    require(job.get('status') == 'completed' and job.get('conclusion') == 'success')
    successful = {step.get('name') for step in job.get('steps', []) if step.get('status') == 'completed' and step.get('conclusion') == 'success'}
    require(REQUIRED_STEPS <= successful)
    require(failed.get('id') == FAILED_RUN and failed.get('head_sha') == BASE and failed.get('run_attempt') == 1)
    require(failed.get('workflow_id') == 390747513 and failed.get('status') == 'completed' and failed.get('conclusion') == 'cancelled')
    require(failed_jobs.get('total_count') == 2 and len(failed_jobs.get('jobs', [])) == 2)
    outcomes = {job.get('name'): job.get('conclusion') for job in failed_jobs['jobs']}
    require(outcomes == {'validate': 'cancelled', 'release': 'skipped'})


def read_api(path):
    # Public metadata only; no signing token, credential helper or new permission.
    request = urllib.request.Request('https://api.github.com/repos/' + REPO + path,
        headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'Finder-fixed-source-release-recovery'})
    with urllib.request.urlopen(request, timeout=20) as response:
        require(response.status == 200)
        raw = response.read(1000001)
        require(len(raw) <= 1000000)
        return json.loads(raw)


def main():
    spec = importlib.util.spec_from_file_location('release_guard', ROOT / 'scripts/public-release.py')
    guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
    env = dict(os.environ)
    guard.validate_context(env)
    guard.verify_checkout(env)
    require(env.get('RELEASE_KNOWN_MAP_RISK_ACCEPTED') == 'true')
    subprocess.run(['git', 'merge-base', '--is-ancestor', BASE, 'HEAD'], cwd=ROOT, check=True)
    changed = subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', BASE, 'HEAD'], cwd=ROOT, text=True).splitlines()
    verify_changes(changed)
    verify_evidence(read_api('/actions/runs/' + str(PASS_RUN) + '/attempts/2'),
                    read_api('/actions/runs/' + str(PASS_RUN) + '/attempts/2/jobs?per_page=100'),
                    read_api('/actions/runs/' + str(FAILED_RUN)),
                    read_api('/actions/runs/' + str(FAILED_RUN) + '/jobs?per_page=100'))
    receipt = dict(scope='owner-accepted-fixed-source-recovery', source=env['EXPECTED_COMMIT'],
                   applicationSource=BASE, applicationBytesUnchanged=True, reusedPassRun=PASS_RUN,
                   reusedPassAttempt=2, laterFailedRun=FAILED_RUN, laterFailureRetained=True,
                   knownIssue='pan assertion failed, followed by Simulator SpringBoard launch failure',
                   applicationTestsRerun=False, unsignedReleasePreviouslyPassed=True,
                   fullAcceptance=False, ownerAcceptedKnownRisk=True)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
