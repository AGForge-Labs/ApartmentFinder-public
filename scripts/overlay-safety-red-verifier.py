"""Fail closed unless four specific fictional safety assertions fail."""
import json,re,sys

EXPECTED={
 'testPointedLockerCannotEnterMissingPublicLocker':('XCTAssertNil failed','OVERLAY_SAFETY_POINTED_LOCKER actual=present expected=missing'),
 'testAbsentLockerCannotEnterMissingPublicLocker':('XCTAssertNil failed','OVERLAY_SAFETY_ABSENT_LOCKER actual=present expected=missing'),
 'testUnrelatedCommunityMetadataCannotChange':('XCTAssertEqual failed','OVERLAY_SAFETY_METADATA actual=changed expected=unchanged'),
 'testDuplicateIncomingUnitIdentityRejectsEntireOverlay':('XCTAssertTrue failed','OVERLAY_SAFETY_DUPLICATE_UNIT actual=2 expected=0'),
}
def validate(body,status):
    if status!=1: raise ValueError('Not a normal XCTest red exit')
    if re.search(r'\b(?:skipped|expected failure|unexpected failure)\b',body,re.I): raise ValueError('Skipped or unexpected result')
    rows=list(re.finditer(r"(?m)^Test Case '([^']+)' (started|passed|failed)(?:\.| at [^\n]+| \([^\n]+\)\.?)$",body))
    seen={}; started={}
    for row in rows:
        label,outcome=row.groups()
        match=(re.fullmatch(r'-\[[A-Za-z0-9_]+\.ReviewedProgressOverlaySafetyTests (test[A-Za-z0-9_]+)\]',label) or
               re.fullmatch(r'ReviewedProgressOverlaySafetyTests\.(test[A-Za-z0-9_]+)(?:\(\))?',label))
        if not match or match[1] not in EXPECTED: raise ValueError('Unexpected case identity')
        name=match[1]; seen.setdefault(name,[]).append(outcome)
        if outcome=='started': started[name]=row.end()
        elif outcome=='failed':
            if name not in started: raise ValueError('Failure without start')
            kind,marker=EXPECTED[name]
            lines=[x for x in body[started[name]:row.start()].splitlines() if marker in x]
            if len(lines)!=1 or kind not in lines[0]: raise ValueError('Wrong assertion or actual value')
    if set(seen)!=set(EXPECTED) or any(seen[n]!=['started','failed'] for n in EXPECTED): raise ValueError('Missing or duplicated test result')
    counts=re.findall(r'Executed (\d+) tests?, with (\d+) failures?(?: \((\d+) unexpected\))?',body)
    if not counts or any(x!=('4','4','0') for x in counts): raise ValueError('Unexpected test totals')
    if len(re.findall(r"(?m)^Test Suite 'ReviewedProgressOverlaySafetyTests' failed at [^\n]+$",body))!=1: raise ValueError('Missing suite completion')
    return {'tests':4,'expectedRed':4,'unexpected':0,'scope':'fictional-safety-red-diagnostic','nativeAcceptance':False,'releaseEligible':False}
if __name__=='__main__':
    print(json.dumps(validate(open(sys.argv[1],encoding='utf-8').read(),int(sys.argv[2])),sort_keys=True))
