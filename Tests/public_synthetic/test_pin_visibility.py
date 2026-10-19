"""Guard the focused fictional pin investigation without relaxing UI acceptance."""
from pathlib import Path
import re
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
        self.assertIn('let originalPinFound = pin.waitForExistence(timeout: 5)', flow)
        self.assertIn('let originalPinDiagnostics = originalPinFound ? \"\" : sourcePinDiagnostics()', flow)
        self.assertIn('XCTAssertTrue(originalPinFound, originalPinDiagnostics)', flow)
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
        self.assertIn('Save both normal-launch values before any diagnostic relaunch.', source)
        for forbidden in ('print(', 'debugDescription', 'screenshot(', '.frame', '.value',
                          '.identifier', '.coordinate', 'UUID', 'localizedDescription'):
            self.assertNotIn(forbidden, helper)
        self.assertEqual(helper.count('.label'), 1)

    def test_pin_host_probe_preserves_normal_result_and_uses_only_isolated_relaunch(self):
        source = (ROOT / 'UITests/OnTracFlowTests.swift').read_text()
        flow = source.split('func testSourceUnitPinAppearsOnMapAfterOnTracImport() {', 1)[1].split('\n    func test', 1)[0]
        self.assertLess(flow.index('let originalPinFound'), flow.index('probePinHost()'))
        self.assertLess(flow.index('let originalPinDiagnostics'), flow.index('probePinHost()'))
        self.assertIn('if !originalPinFound && syntheticDiagnosticsEnabled', flow)
        self.assertIn('XCTAssertTrue(originalPinFound, originalPinDiagnostics)', flow)
        self.assertIn('guard originalPinFound else { return }', flow)
        helper = source.split('private func probePinHost() {', 1)[1].split('\n    private func', 1)[0]
        self.assertNotIn('XCTAssert', helper)
        self.assertNotIn('reach(', helper)
        self.assertNotIn('tapTestImport(', helper)
        self.assertIn('app.launchArguments[storeIndex + 1] = UUID().uuidString', helper)
        self.assertIn('--synthetic-pin-host-probe', helper)
        self.assertIn('guard remaining() > 0', helper)
        self.assertIn('coverageElements.count == 1', helper)
        self.assertIn('range(of: pattern, options: .regularExpression)', helper)
        self.assertNotIn('debugDescription', helper)
        self.assertNotIn('screenshot(', helper)
        probe = (ROOT / 'App/SyntheticPinHostProbe.swift').read_text()
        for required in ('#if DEBUG', 'targetEnvironment(simulator)', 'SyntheticUIDiagnostics.enabled',
                         '--synthetic-pin-host-probe', 'MKAnnotationView', 'MKMapView',
                         'ObjectIdentifier', 'accessibilityElements'):
            self.assertIn(required, probe)
        for forbidden in ('print(', 'NSLog(', 'value(forKey', 'layoutIfNeeded(', 'setNeedsLayout(',
                          'addGestureRecognizer', 'accessibilityActivate', 'UIViewControllerRepresentable'):
            self.assertNotIn(forbidden, probe)

    def test_probe_schema_is_closed_and_shared_with_reader(self):
        probe = (ROOT / 'App/SyntheticPinHostProbe.swift').read_text()
        ui = (ROOT / 'UITests/OnTracFlowTests.swift').read_text()
        writer_pattern = re.search(r'static let snapshotPattern = #"([^"\n]+)"#', probe).group(1)
        reader = ui.split('private func probePinHost() {', 1)[1].split('\n    private func', 1)[0]
        reader_pattern = re.search(r'let pattern = #"([^"\n]+)"#', reader).group(1)
        self.assertEqual(reader_pattern, writer_pattern.replace('sample=[1-3]', 'sample=3'))
        python_pattern = reader_pattern.replace(r'\z', r'\Z')
        payload = reader_pattern.removeprefix(r'\A').removesuffix(r'\z')
        payload = payload.replace('(true|false)', 'false').replace('[0-3]', '0')
        self.assertIsNotNone(re.fullmatch(python_pattern, payload))
        for invalid in (payload + ';unexpected=1', payload.replace('window=false', 'window=unknown'),
                        payload.replace('nativeID=0', 'nativeID=999'), '\n' + payload):
            self.assertIsNone(re.fullmatch(python_pattern, invalid))
        self.assertIn('private static var emittedSnapshots', probe)
        self.assertIn('emittedSnapshots < 3', probe)
        self.assertIn('scheduledSamples < 24', probe)
        self.assertIn('var views: [UIView] = [host]', probe)
        self.assertIn('native.record(host)', probe)
        self.assertIn('ancestorTruncated', probe)
        for line in (ROOT / 'App/ApartmentDeliveryMap.swift').read_text().splitlines():
            if '#if DEBUG' in line:
                self.assertIn('targetEnvironment(simulator)', line)

    def test_failed_grouping_is_removed_and_real_selection_acceptance_remains(self):
        source = (ROOT / 'App/ApartmentDeliveryMap.swift').read_text()
        button = source.split('private func pinButton(_ pin: Pin) -> some View {', 1)[1].split('\n    private func center', 1)[0]
        self.assertIn('Button { select(pin.stop.id) } label:', button)
        self.assertNotIn('.accessibilityElement(children: .combine)', button)
        self.assertIn('.accessibilityIdentifier("mini.pin.\\(pin.stop.sequence).\\(pin.place.id)")', button)
        self.assertNotIn('accessibilityRepresentation', source)
        self.assertNotIn('accessibilityChildren', source)
        ui = (ROOT / 'UITests/OnTracFlowTests.swift').read_text()
        flow = ui.split('func testSourceUnitPinAppearsOnMapAfterOnTracImport() {', 1)[1].split('\n    func test', 1)[0]
        self.assertIn('let originalPinFound = pin.waitForExistence(timeout: 5)', flow)
        self.assertIn('let originalPinDiagnostics = originalPinFound ? \"\" : sourcePinDiagnostics()', flow)
        self.assertIn('XCTAssertTrue(originalPinFound, originalPinDiagnostics)', flow)
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
