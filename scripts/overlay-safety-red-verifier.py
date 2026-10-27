"""Read fictional native result data; accept only the two intended red assertions."""
import json,re,sys

CLASS='PublicCatalogRefreshStoreTests'
EXPECTED={
 'testActualReviewedBundleHasExactAreaAndLockerScope':('Passed',None),
 'testOlderSavedFeedGetsBundleProgressWithoutChangingPrivateOrPersonalData':('Failed','INTEGRATION_RED_BASELINE actual=older expected=bundle'),
 'testFutureRefreshRollbackAndConservativeShare':('Failed','INTEGRATION_RED_OVERLAY actual=missing expected=present'),
}
def validate(summary,tree,log,status):
    if status!=65: raise ValueError('Expected normal Xcode test-failure exit 65')
    fields={'passedTests':1,'failedTests':2,'skippedTests':0,'expectedFailures':0,'totalTestCount':3}
    if any(type(summary.get(k)) is not int or summary[k]!=v for k,v in fields.items()): raise ValueError('Unexpected Xcode test summary')
    cases=[]
    def walk(node):
        if isinstance(node,dict):
            if node.get('nodeType') in ('Test Case','TestCase'):
                label=node.get('nodeIdentifier',node.get('testIdentifier',''))
                if not isinstance(label,str): raise ValueError('Invalid case ID')
                parts=label.removesuffix('()').split('/')
                if len(parts) not in (2,3) or parts[-2]!=CLASS or parts[-1] not in EXPECTED: raise ValueError('Unexpected case ID')
                cases.append((parts[-1],node.get('result')))
            for value in node.values(): walk(value)
        elif isinstance(node,list):
            for value in node: walk(value)
    walk(tree)
    if len(cases)!=3 or len({name for name,_ in cases})!=3 or set(cases)!={(name,v[0]) for name,v in EXPECTED.items()}: raise ValueError('Missing, duplicate, or wrong result case')
    if re.search(r'\b(?:skipped|expected failure|unexpected failure)\b',log,re.I): raise ValueError('Skipped or unexpected case')
    rows=list(re.finditer(r"(?m)^Test Case '([^']+)' (started|passed|failed)(?:\.| at [^\n]+| \([^\n]+\)\.?)$",log))
    seen={}; starts={}
    for row in rows:
        label,outcome=row.groups()
        match=(re.fullmatch(r'-\[[A-Za-z0-9_]+\.PublicCatalogRefreshStoreTests (test[A-Za-z0-9_]+)\]',label) or
               re.fullmatch(r'PublicCatalogRefreshStoreTests\.(test[A-Za-z0-9_]+)(?:\(\))?',label))
        if not match or match[1] not in EXPECTED: raise ValueError('Unexpected log case')
        name=match[1]; seen.setdefault(name,[]).append(outcome)
        if outcome=='started': starts[name]=row.end()
        elif outcome=='failed':
            if name not in starts or EXPECTED[name][1] is None: raise ValueError('Unexpected failure')
            marker=EXPECTED[name][1]
            lines=[line for line in log[starts[name]:row.start()].splitlines() if marker in line]
            if len(lines)!=1 or 'XCTAssertTrue failed' not in lines[0]: raise ValueError('Wrong failure assertion or value')
    if set(seen)!=set(EXPECTED): raise ValueError('Missing case log')
    for name,(expected,_) in EXPECTED.items():
        if seen[name]!=['started',expected.lower()]: raise ValueError('Wrong log result')
    counts=re.findall(r'Executed (\d+) tests?, with (\d+) failures?(?: \((\d+) unexpected\))?',log)
    if not counts or any(row!=('3','2','0') for row in counts): raise ValueError('Unexpected test counts')
    if len(re.findall(r"(?m)^Test Suite 'PublicCatalogRefreshStoreTests' failed at [^\n]+$",log))!=1: raise ValueError('Suite did not complete')
    return {'tests':3,'passed':1,'expectedRed':2,'unexpected':0,'scope':'bundle-integration-red-only','releaseEligible':False,'nativeAcceptance':False}
if __name__=='__main__':
    with open(sys.argv[1],encoding='utf-8') as f: summary=json.load(f)
    with open(sys.argv[2],encoding='utf-8') as f: tree=json.load(f)
    with open(sys.argv[3],encoding='utf-8') as f: log=f.read()
    print(json.dumps(validate(summary,tree,log,int(sys.argv[4])),sort_keys=True))
