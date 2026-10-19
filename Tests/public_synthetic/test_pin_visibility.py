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
        self.assertIn('maps.descendants(matching: .any)', helper)
        self.assertIn('"Unit 4102"', helper)
        self.assertIn('"Stop 1, unit 4102, building F, Suggested location"', helper)
        self.assertIn('XCTest evaluates this assertion-message autoclosure only on failure.', source)
        for forbidden in ('print(', 'debugDescription', 'screenshot(', '.frame', '.value',
                          '.identifier', '.coordinate', 'UUID', 'localizedDescription'):
            self.assertNotIn(forbidden, helper)
        self.assertEqual(helper.count('.label'), 1)

    def test_real_pin_grouping_and_selection_preserve_original_acceptance(self):
        source = (ROOT / 'App/ApartmentDeliveryMap.swift').read_text()
        button = source.split('private func pinButton(_ pin: Pin) -> some View {', 1)[1].split('\n    private func center', 1)[0]
        self.assertIn('Button { select(pin.stop.id) } label:', button)
        self.assertIn('.accessibilityElement(children: .combine)', button)
        self.assertLess(button.index('.accessibilityElement(children: .combine)'),
                        button.index('.accessibilityLabel('))
        self.assertIn('.accessibilityIdentifier("mini.pin.\\(pin.stop.sequence).\\(pin.place.id)")', button)
        self.assertNotIn('accessibilityRepresentation', source)
        self.assertNotIn('accessibilityChildren', source)
        ui = (ROOT / 'UITests/OnTracFlowTests.swift').read_text()
        flow = ui.split('func testSourceUnitPinAppearsOnMapAfterOnTracImport() {', 1)[1].split('\n    func test', 1)[0]
        self.assertIn('XCTAssertTrue(pin.waitForExistence(timeout: 5), sourcePinDiagnostics())', flow)
        self.assertLess(flow.index('laterPin.tap()'), flow.index('pin.tap()'))
        self.assertIn('XCTAssertTrue(app.staticTexts["Unit 4108"].waitForExistence(timeout: 5))', flow)
        self.assertIn('XCTAssertTrue(app.staticTexts["Unit 4102"].waitForExistence(timeout: 5))', flow)
        self.assertIn('XCTAssertTrue(pin.isHittable)', flow)
        self.assertIn('XCTAssertTrue(laterPin.isHittable)', flow)
        self.assertIn('XCTAssertTrue(app.buttons["mini.delivered"].label.contains("4108"))', flow)
        self.assertIn('XCTAssertTrue(app.buttons["mini.delivered"].label.contains("4102"))', flow)
        self.assertIn('app.maps.firstMatch.frame.contains(CGPoint(x: pin.frame.midX, y: pin.frame.midY))', flow)
        root = (ROOT / 'App/RootView.swift').read_text()
        self.assertIn('Text("Your saved apartment maps")', root)
        self.assertNotIn('Your saved apartment maps · 89113 + 89148', root)


if __name__ == '__main__':
    unittest.main()
