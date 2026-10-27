"""Accept only the four specified synthetic XCTest results, including two red."""
import re, sys

EXPECTED = {
    'testPublicUnknownReceivesQualifiedPresenceWithoutCreatingPoint': 'failed',
    'testExistingLiteralUnitWinsEvenWhenFloorOrBuildingDiffersAndOtherAreaIsAdded': 'failed',
    'testExistingPresentOrAbsentPublicEvidenceIsNeverReplaced': 'passed',
    'testConflictingSourceIdentityCannotAddAnArea': 'passed',
}
MARKERS = {
    'testPublicUnknownReceivesQualifiedPresenceWithoutCreatingPoint': 'OVERLAY_RED_LOCKER_STATUS actual=unknown expected=present',
    'testExistingLiteralUnitWinsEvenWhenFloorOrBuildingDiffersAndOtherAreaIsAdded': 'OVERLAY_RED_UNIT_MERGE actual=1 expected=2',
}

def validate(body, exit_code):
    if exit_code != 1: raise ValueError('Expected normal XCTest failure exit 1')
    if re.search(r'\b(?:skipped|expected failure|unexpected failure)\b', body, re.I):
        raise ValueError('Skip or unexpected failure')
    rows = list(re.finditer(r"(?m)^Test Case '([^']+)' (started|passed|failed)(?:\.| at [^\n]+| \([^\n]+\)\.?)$", body))
    results = {}
    starts = {}
    for row in rows:
        label, outcome = row.groups()
        match = (re.fullmatch(r'-\[[A-Za-z0-9_]+\.ReviewedProgressOverlayTests (test[A-Za-z0-9_]+)\]',label)
                 or re.fullmatch(r'ReviewedProgressOverlayTests\.(test[A-Za-z0-9_]+)(?:\(\))?',label))
        if not match or match[1] not in EXPECTED: raise ValueError('Unexpected test identity')
        name=match[1]
        results.setdefault(name, []).append(outcome)
        if outcome == 'started': starts[name] = row.end()
        elif outcome == 'failed':
            if name not in starts or name not in MARKERS: raise ValueError('Unbound failing case')
            block=body[starts[name]:row.start()]
            lines=[line for line in block.splitlines() if MARKERS[name] in line]
            if len(lines)!=1 or 'XCTAssertEqual failed' not in lines[0]: raise ValueError('Wrong assertion or value: '+name)
    if set(results) != set(EXPECTED): raise ValueError('Missing tests')
    for name, outcome in EXPECTED.items():
        if results[name] != ['started', outcome]: raise ValueError('Wrong or duplicate test result: '+name)
    counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures?(?: \((\d+) unexpected\))?', body)
    if not counts or any(row != ('4', '2', '0') for row in counts):
        raise ValueError('Unexpected test totals')
    if len(re.findall(r"(?m)^Test Suite 'ReviewedProgressOverlayTests' failed at [^\n]+$",body)) != 1:
        raise ValueError('Missing or duplicate completed suite terminator')
    return dict(tests=4, expectedRed=2, passed=2, releaseEligible=False)

if __name__ == '__main__':
    import json
    print(json.dumps(validate(open(sys.argv[1],encoding='utf-8').read(), int(sys.argv[2])),sort_keys=True))
