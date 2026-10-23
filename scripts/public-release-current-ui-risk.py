"""Fixed27.1 owner-selected app-regression waiver; never report failed tests as passed."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
BASE='708ef295532acb95c211bb76135ffd9ee01610da'
PRIOR_RUN=39868707775
REPO='AGForge-Labs/ApartmentFinder-public'
ALLOWED={'.github/workflows/public-testflight.yml','scripts/public-release-current-ui-risk.py'}

def require(value):
    if not value:raise ValueError('Fixed27.1 owner-selected release source or context mismatch')

def read_api(path):
    request=urllib.request.Request('https://api.github.com/repos/'+REPO+path,
        headers={'Accept':'application/vnd.github+json','User-Agent':'Finder-owner-selected-fixed-source-release'})
    with urllib.request.urlopen(request,timeout=20) as response:
        raw=response.read(1000001)
        require(response.status==200 and len(raw)<=1000000)
        return json.loads(raw)

def main():
    spec=importlib.util.spec_from_file_location('release_guard',ROOT/'scripts/public-release.py')
    guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)
    env=dict(os.environ)
    guard.validate_context(env);guard.verify_checkout(env)
    require(env.get('RELEASE_CURRENT_UI_RISK_ACCEPTED')=='true')
    require(env.get('RELEASE_KNOWN_MAP_RISK_ACCEPTED')!='true' and env.get('RELEASE_BUILD_NUMBER')=='27.1')
    parents=subprocess.check_output(['git','show','-s','--format=%P','HEAD'],cwd=ROOT,text=True).split()
    require(parents==[BASE])
    changed=subprocess.check_output(['git','diff','--name-only','--no-renames',BASE,'HEAD'],cwd=ROOT,text=True).splitlines()
    require(len(changed)==2 and set(changed)==ALLOWED)
    prior=read_api('/actions/runs/'+str(PRIOR_RUN))
    require(prior.get('id')==PRIOR_RUN and prior.get('head_sha')==BASE and prior.get('run_attempt')==1)
    require(prior.get('workflow_id')==390747513 and prior.get('status')=='completed' and prior.get('conclusion')=='failure')
    require(prior.get('repository',{}).get('full_name')==REPO and prior['repository'].get('private') is False)
    jobs=read_api('/actions/runs/'+str(PRIOR_RUN)+'/jobs?per_page=100')
    require(jobs.get('total_count')==len(jobs.get('jobs',[]))==2)
    require({j.get('name'):(j.get('id'),j.get('conclusion')) for j in jobs['jobs']}==
            {'validate':(120137398118,'failure'),'release':(120160670793,'skipped')})
    print(json.dumps(dict(scope='owner-selected-fixed27.1-no-app-tests',source=env['EXPECTED_COMMIT'],
        applicationSource=BASE,applicationBytesUnchanged=True,priorRun=PRIOR_RUN,priorConclusion='failure',
        disclosedPriorResults={'corePassed':180,'nativePassed':75,'uiPassed':9,'uiFailed':1},
        knownFailure='Three-second unit-entry predicate timed out before offline-refresh assertions; a later value read was2066.',
        offlineRefreshUIVerified=False,applicationTestsRerun=False,regressionTestsSkipped=True,
        fullAcceptance=False,ownerAcceptedAppRegressionRisk=True),sort_keys=True))

if __name__=='__main__':main()
