"""Guard the focused fictional pin investigation without relaxing UI acceptance."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PinVisibilityTests(unittest.TestCase):
    def test_native_exact_zip_fixture_reaches_committed_source_candidates(self):
        source = (ROOT / 'NativeTests/OnTracImportSetupTests.swift').read_text()
        self.assertLess(source.index('XCTAssertNil(store.personal.activeManifest)'),
                        source.index('try coordinator.commit(full, store: store)'))
        for check in (
            'XCTAssertEqual(store.personal.stops.map(\\.sequence), [1, 2])',
            'XCTAssertEqual(store.personal.stops.map(\\.unit), ["4102", "4108"])',
            'XCTAssertEqual(store.apartmentPlan.groups.map(\\.id), ["fictional-courtyard"])',
            'store.doorMatch(stop, groupID: group.id)',
            'XCTAssertEqual(match.candidates.map(\\.id), ["fictional-position-" + stop.unit])',
            'XCTAssertEqual(candidate.kind, .unitPosition)',
            'XCTAssertEqual(candidate.verification, .sourceMapped)',
            'XCTAssertEqual(candidate.coordinate, expectedCoordinate)',
            'XCTAssertNil(match.readyDoor)',
            'XCTAssertEqual(match.issue, .confirmPin)',
        ):
            self.assertIn(check, source)

    def test_pin_assertion_keeps_button_query_and_failure_only_fixed_diagnostics(self):
        source = (ROOT / 'UITests/OnTracFlowTests.swift').read_text()
        flow = source.split('func testSourceUnitPinAppearsOnMapAfterOnTracImport() {', 1)[1].split('\n    func test', 1)[0]
        self.assertIn('let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.1.")).firstMatch', flow)
        self.assertIn('XCTAssertTrue(pin.waitForExistence(timeout: 5), sourcePinDiagnostics())', flow)
        self.assertIn('XCTAssertTrue(pin.label.contains("4102"))', flow)
        helper = source.split('private func sourcePinDiagnostics() -> String {', 1)[1].split('\n    func test', 1)[0]
        self.assertIn('app.descendants(matching: .any).matching(predicate)', helper)
        self.assertIn('app.buttons.matching(predicate)', helper)
        self.assertIn('elementType.rawValue', helper)
        self.assertIn('min(buttons.count, 3)', helper)
        self.assertIn('min(elements.count, 3)', helper)
        self.assertIn('case "Orange pins need checking": coverage = "sourceCandidates"', helper)
        self.assertIn('default: coverage = "unrecognized"', helper)
        self.assertIn('XCTest evaluates this assertion-message autoclosure only on failure.', source)
        for forbidden in ('print(', 'debugDescription', 'screenshot(', '.frame', '.value',
                          '.identifier', '.coordinate', 'UUID', 'localizedDescription'):
            self.assertNotIn(forbidden, helper)
        self.assertEqual(helper.count('.label'), 1)


if __name__ == '__main__':
    unittest.main()
