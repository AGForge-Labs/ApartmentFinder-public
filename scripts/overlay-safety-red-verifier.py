"""Require eight exact fictional XCTest passes, not release acceptance."""
import json,re,sys

EXPECTED={
 'ReviewedProgressOverlayTests':{
  'testPublicUnknownReceivesQualifiedPresenceWithoutCreatingPoint',
  'testExistingLiteralUnitWinsEvenWhenFloorOrBuildingDiffersAndOtherAreaIsAdded',
  'testExistingPresentOrAbsentPublicEvidenceIsNeverReplaced',
  'testConflictingSourceIdentityCannotAddAnArea',
 },
 'ReviewedProgressOverlaySafetyTests':{
  'testPointedLockerCannotEnterMissingPublicLocker',
  'testAbsentLockerCannotEnterMissingPublicLocker',
  'testUnrelatedCommunityMetadataCannotChange',
  'testDuplicateIncomingUnitIdentityRejectsEntireOverlay',
 },
}
def validate(body,status):
    if status!=0: raise ValueError('Swift test did not succeed')
    if re.search(r'\b(?:skipped|expected failure|unexpected failure)\b',body,re.I): raise ValueError('Skipped or unexpected result')
    rows=re.findall(r"(?m)^Test Case '([^']+)' (started|passed|failed)(?:\.| at [^\n]+| \([^\n]+\)\.?)$",body)
    seen={}
    for label,outcome in rows:
        m=(re.fullmatch(r'-\[[A-Za-z0-9_]+\.(ReviewedProgressOverlay(?:Safety)?Tests) (test[A-Za-z0-9_]+)\]',label) or
           re.fullmatch(r'(ReviewedProgressOverlay(?:Safety)?Tests)\.(test[A-Za-z0-9_]+)(?:\(\))?',label))
        if not m or m[1] not in EXPECTED or m[2] not in EXPECTED[m[1]]: raise ValueError('Unexpected test identity')
        seen.setdefault((m[1],m[2]),[]).append(outcome)
    expected={(suite,name) for suite,names in EXPECTED.items() for name in names}
    if set(seen)!=expected or any(seen[key]!=['started','passed'] for key in expected): raise ValueError('Missing, duplicate or failing case')
    counts=re.findall(r'Executed (\d+) tests?, with (\d+) failures?(?: \((\d+) unexpected\))?',body)
    if not counts or ('8','0','0') not in counts or any(row not in (('4','0','0'),('8','0','0')) for row in counts): raise ValueError('Unexpected test totals')
    for suite in EXPECTED:
        if len(re.findall(r"(?m)^Test Suite '"+re.escape(suite)+r"' passed at [^\n]+$",body))!=1: raise ValueError('Missing suite completion')
    return {'tests':8,'passed':8,'failed':0,'scope':'fictional-eight-test-green-diagnostic','nativeAcceptance':False,'releaseEligible':False}
if __name__=='__main__':
    print(json.dumps(validate(open(sys.argv[1],encoding='utf-8').read(),int(sys.argv[2])),sort_keys=True))
