"""Portable integrity checks. These do not claim Swift or app acceptance."""
import importlib.util
import base64
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class PublicPreflightTests(unittest.TestCase):
    def test_diagnostic_witness_is_opt_in_simulator_only_and_data_minimized(self):
        support = (ROOT / 'App/UITestSupport.swift').read_text()
        self.assertIn('enum SyntheticUIDiagnostics', support)
        witness = support.split('enum SyntheticUIDiagnostics', 1)[1]
        for gate in ('targetEnvironment(simulator)', '--synthetic-ui-diagnostics',
                     '--synthetic-diagnostic-probe', 'UITestSupport.storeURL() != nil'):
            self.assertIn(gate, witness)
        self.assertIn('SyntheticUIDiagnostics', witness)
        self.assertIn('Library/Caches/SyntheticUIDiagnostics', witness)
        self.assertIn('options: .atomic', witness)
        for forbidden in ('localizedDescription', 'lastPathComponent', 'debugDescription',
                          'store.personal', 'print(', 'NSLog('):
            self.assertNotIn(forbidden, witness)
        root = (ROOT / 'App/RootView.swift').read_text()
        self.assertIn('SyntheticUIDiagnostics.rootAppeared(', root)
        self.assertIn('SyntheticUIDiagnostics.sceneChanged(', root)
        self.assertIn('SyntheticUIDiagnostics.manifestSheetAppeared()', root)
        coordinator = (ROOT / 'App/ManifestImportCoordinator.swift').read_text()
        for event in ('actionEntered', 'openStarted', 'requestPublished', 'readFailed', 'loadingEnded'):
            self.assertIn('SyntheticUIDiagnostics.' + event, coordinator)

    def test_swift_writer_and_host_reader_use_the_same_fixed_schema(self):
        support = (ROOT / 'App/UITestSupport.swift').read_text()
        snapshot = support.split('private struct Snapshot: Encodable {', 1)[1].split('\n    }', 1)[0]
        fields = re.findall(r'^\s*(?:let|var) (\w+) = ("[^"\n]*"|true|false|[0-9]+)', snapshot, re.M)
        value = {key: json.loads(literal) for key, literal in fields}
        diagnostics = module('public_preflight_diagnostics', ROOT / 'scripts/public-synthetic-diagnostics.py')
        self.assertEqual(set(value), set(diagnostics.SCHEMA_FIELDS))
        value.update(sequence=1, rootAppearances=1, coordinatorInstance=1)
        with tempfile.TemporaryDirectory() as temporary:
            container = Path(temporary).resolve()
            directory = container / 'Library/Caches/SyntheticUIDiagnostics'
            directory.mkdir(parents=True)
            (directory / 'toolbar.json').write_text(json.dumps(value))
            status, decoded = diagnostics.read_witness(container, 'toolbar')
        self.assertEqual(status, 'valid')
        self.assertEqual(decoded, value)

    def test_failure_only_probe_cannot_turn_the_original_chooser_failure_green(self):
        source = (ROOT / 'UITests/OnTracFlowTests.swift').read_text()
        self.assertIn('APARTMENTFINDER_SYNTHETIC_DIAGNOSTICS', source)
        self.assertIn('let originalChooserFound = day.waitForExistence(timeout: 10)', source)
        self.assertIn('let originalDiagnostics = chooserDiagnostics()', source)
        self.assertIn('if !originalChooserFound && syntheticDiagnosticsEnabled', source)
        self.assertIn('probeProductionImport()', source)
        self.assertIn('XCTAssertTrue(originalChooserFound, originalDiagnostics)', source)
        helper = source.split('private func probeProductionImport()', 1)[1].split('\n    private func chooseDay()', 1)[0]
        self.assertNotIn('XCTAssert', helper)
        self.assertIn('app.launchArguments[storeIndex + 1] = UUID().uuidString', helper)
        self.assertIn('app.buttons["apartments.import"]', helper)
        self.assertIn('importButton.tap()', helper)
        self.assertNotIn('withNormalizedOffset', helper)
        self.assertNotIn('fixture', helper.lower())
        routes = (ROOT / 'App/ApartmentRoutesView.swift').read_text()
        self.assertIn('imports.recordUITestAction(.productionImport)', routes)
        self.assertIn('.fileImporter(isPresented: $importing', routes)
        self.assertNotIn('--hide-test-toolbar', routes)
        capture = source.split('private func capture(_ name: String) {', 1)[1].split('\n    }', 1)[0]
        self.assertIn('if syntheticDiagnosticsEnabled { return }', capture)
        self.assertIn('if !syntheticDiagnosticsEnabled &&', source)

    def test_banner_comparison_is_gated_and_preserves_the_original_failure(self):
        support = (ROOT / 'App/UITestSupport.swift').read_text()
        self.assertIn('case toolbar, production, bannerPassThrough, toolbarRecheck', support)
        self.assertIn('enabled && probe == .bannerPassThrough', support)
        modifier = support.split('struct SyntheticBannerHitTestProbe: ViewModifier {', 1)[1]
        self.assertIn('if SyntheticUIDiagnostics.bannerHitTestingDisabled', modifier)
        self.assertIn('content.allowsHitTesting(false)', modifier)
        self.assertIn('} else { content }', modifier)
        root = (ROOT / 'App/RootView.swift').read_text()
        self.assertRegex(root, r'background\(\.regularMaterial\)\s+#if DEBUG\s+\.modifier\(SyntheticBannerHitTestProbe\(\)\)\s+#endif')
        source = (ROOT / 'UITests/OnTracFlowTests.swift').read_text()
        helper = source.split('private func probeToolbarHitRegion(_ probe: String)', 1)[1].split('\n    @discardableResult', 1)[0]
        self.assertNotIn('XCTAssert', helper)
        self.assertNotIn('tapTestImport()', helper)
        self.assertNotIn('withNormalizedOffset', helper)
        self.assertIn('["bannerPassThrough", "toolbarRecheck"].contains(probe)', helper)
        self.assertIn('app.launchArguments[storeIndex + 1] = UUID().uuidString', helper)
        self.assertIn('app.launchArguments[probeIndex + 1] = probe', helper)
        self.assertIn('controls.count == 1, control.isEnabled, control.isHittable', helper)
        self.assertLess(helper.index('activationDiagnostics()'), helper.index('control.tap()'))
        chooser = source.split('private func chooseDay() -> Bool {', 1)[1].split('\n    func test', 1)[0]
        self.assertLess(chooser.index('probeProductionImport()'), chooser.index('probeToolbarHitRegion("bannerPassThrough")'))
        self.assertLess(chooser.index('probeToolbarHitRegion("bannerPassThrough")'), chooser.index('probeToolbarHitRegion("toolbarRecheck")'))
        self.assertLess(chooser.index('probeToolbarHitRegion("toolbarRecheck")'), chooser.index('XCTAssertTrue(originalChooserFound, originalDiagnostics)'))
        self.assertIn('return false', chooser)

    def test_no_pack_banner_has_its_own_layout_slot_and_preserves_pack_import(self):
        source = (ROOT / 'App/RootView.swift').read_text()
        layout = source.split('    var body: some View {', 1)[1].split('        .fileImporter(', 1)[0]
        self.assertIn('VStack(spacing: 0)', layout)
        self.assertEqual(layout.count('TabView(selection: $selectedTab)'), 1)
        self.assertNotIn('.safeAreaInset(', layout)
        self.assertLess(layout.index('if store.requiresPrivatePack'), layout.index('TabView(selection: $selectedTab)'))
        self.assertIn('Button("Import private map pack", systemImage: "folder") { importingPack = true }', layout)
        self.assertIn('.disabled(store.privatePackImportPending || location.recordingNeedsFinish)', layout)
        self.assertRegex(layout, r'TabView\(selection: \$selectedTab\) \{[\s\S]*\}\s+\.disabled\(store.privatePackImportPending\)\s+\}')
        for boundary in ('.fileImporter(isPresented: $importingPack, allowedContentTypes: [.folder])',
                         'importSelectedPrivatePack(result, into: store, location: location)',
                         '.onOpenURL { url in imports.open(', '.task { imports.refresh(store: store) }',
                         '.sheet(item: $imports.request)', '.alert("ApartmentFinder"'):
            self.assertIn(boundary, source)
        self.assertNotIn('.id(', layout)
        self.assertNotIn('.ignoresSafeArea(', layout)
        ui = (ROOT / 'UITests/OnTracFlowTests.swift').read_text()
        flow = ui.split('func testSourceUnitPinAppearsOnMapAfterOnTracImport() {', 1)[1].split('\n    func test', 1)[0]
        self.assertLess(flow.index('let packImport = app.buttons["Import private map pack"]'), flow.index('tapTestImport()'))
        for check in ('XCTAssertTrue(packImport.isEnabled)', 'XCTAssertTrue(packImport.isHittable)',
                      'XCTAssertFalse(packImport.frame.intersects(app.navigationBars["Apartments"].frame))'):
            self.assertIn(check, flow)

    def test_picker_witness_is_bounded_positive_only_and_never_loads_views(self):
        support = (ROOT / 'App/UITestSupport.swift').read_text()
        sampler = support.split('private static func observeDocumentPicker()', 1)[1].split('private static func write(', 1)[0]
        self.assertIn('guard enabled, probe == .production', sampler)
        self.assertIn('[UInt64(0), 500_000_000, 1_000_000_000]', sampler)
        self.assertIn('snapshot.documentPickerWasPresented || documentPickerInForegroundScene()', sampler)
        self.assertIn('snapshot.pickerObservationCompleted = true', sampler)
        self.assertIn('controller is UIDocumentPickerViewController', sampler)
        self.assertIn('controller.viewIfLoaded?.window != nil', sampler)
        self.assertNotRegex(sampler, r'controller\.view\b')
        self.assertIn('visited.count < 64', sampler)
        self.assertIn('.prefix(8)', sampler)
        for forbidden in ('print(', 'NSLog(', '.title', '.description', '.accessibilityLabel', '.url'):
            self.assertNotIn(forbidden, sampler)

    def test_diagnostic_scope_keeps_selection_and_allows_practical_hung_job_cleanup(self):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        self.assertIn('activation-diagnostics', workflow)
        self.assertIn('default: regression', workflow)
        self.assertIn('timeout-minutes: 90', workflow)
        self.assertIn('85 * 60', workflow)
        self.assertIn("inputs.scope == 'activation-diagnostics' && 5 || 90", workflow)
        self.assertIn("inputs.scope == 'activation-diagnostics' && 10 || 90", workflow)
        self.assertIn('-default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 600', workflow)
        self.assertNotIn('timeout-minutes: 35', workflow)
        self.assertNotIn('32 * 60', workflow)
        self.assertIn('TEST_RUNNER_APARTMENTFINDER_SYNTHETIC_DIAGNOSTICS=1', workflow)
        self.assertIn('public-synthetic-diagnostics.py run', workflow)
        self.assertIn('PUBLIC_SYNTHETIC_SCOPE', workflow)
        self.assertNotIn('done < <(', workflow)
        self.assertIn('"${#FILTERS[@]}" == "$EXPECTED_NATIVE_COUNT"', workflow)
        self.assertIn('sys.exit(cleanup_failed)', workflow)
        self.assertIn('local original_status=$?', workflow)
        self.assertNotIn('upload-artifact', workflow)
        self.assertIn('testFictionalPackAndExactZIPReachTheTwoDayImportRequestOnIOS', workflow)
        self.assertIn('testProductionAppBundleLoadsReviewedPublicCatalogWithoutMapImport', workflow)
        self.assertIn('testSourceUnitPinAppearsOnMapAfterOnTracImport', workflow)

    def test_workflow_command_prefixes_are_nonempty_for_macos_nounset_in_both_scopes(self):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        preamble = '          WORK=' + workflow.split('          WORK=', 1)[1].split('          "${WORK[@]}" bash', 1)[0]
        run_selection = re.search(r'^          if \[\[ "\$PUBLIC_SYNTHETIC_SCOPE" == activation-diagnostics \]\]; then\n            RUN=.*?^          fi', workflow, re.M | re.S).group()
        capture = shlex.quote(sys.executable) + ' -c ' + shlex.quote('import json,sys; print(json.dumps(sys.argv[1:]))')
        for scope in ('regression', 'map-interaction-regression', 'activation-diagnostics'):
            with self.subTest(scope=scope):
                script = ('set -euo pipefail\nPUBLIC_SYNTHETIC_SCOPE=' + scope +
                          '\nDIAGNOSTIC_WORK_DEADLINE=12345\nDEVICE=synthetic-device\n' +
                          textwrap.dedent(preamble) + textwrap.dedent(run_selection) + '\n' +
                          capture + ' "${WORK[@]}"\n' + capture + ' "${RUN[@]}"\n')
                result = subprocess.run(['bash'], input=script, text=True, capture_output=True, timeout=2)
                self.assertEqual(result.returncode, 0, result.stderr)
                work, run = map(json.loads, result.stdout.splitlines())
                if scope != 'activation-diagnostics':
                    self.assertEqual(work, ['env'])
                    self.assertEqual(run, ['env'])
                else:
                    self.assertEqual(work, ['python3', '-B', 'scripts/public-synthetic-diagnostics.py',
                        'work', '--deadline-epoch', '12345', '--'])
                    self.assertEqual(run, ['python3', '-B', 'scripts/public-synthetic-diagnostics.py',
                        'run', '--deadline-epoch', '12345', '--device', 'synthetic-device', '--'])

    def test_map_scope_executes_exact_existing_ui_methods_and_rejects_missing_methods(self):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        header = '          "${WORK[@]}" python3 -B - "$RUNNER_TEMP/selected-tests.json" <<\'PY\'\n'
        producer = textwrap.dedent(workflow.split(header, 1)[1].split('          PY\n', 1)[0])
        profile = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        expected = {'native': [], 'ui': profile['ui'] + [
            'ApartmentFinderUITests/HeadingUpNavigationTests/testStartsHeadingUpAndResumePreservesChosenStop',
            'ApartmentFinderUITests/HeadingUpNavigationTests/testResumePreservesActualPinchZoomAndSelectedStop',
            'ApartmentFinderUITests/MapAppearanceTests/testMapTypePersistsAcrossDoorReviewDeliveryAdvanceAndRelaunch',
        ]}
        self.assertEqual(len(expected['ui']), 5)
        self.assertIn("'map-interaction-regression':5", workflow)
        self.assertIn('if [[ "$PUBLIC_SYNTHETIC_SCOPE" == map-interaction-regression ]]; then EXPECTED_NATIVE_COUNT=5; fi', workflow)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            (root / 'UITests').mkdir()
            (root / 'scripts/iterate.py').write_text((ROOT / 'scripts/iterate.py').read_text())
            for name in ('OnTracFlowTests.swift', 'HeadingUpNavigationTests.swift', 'MapAppearanceTests.swift'):
                (root / 'UITests' / name).write_text((ROOT / 'UITests' / name).read_text())
            (root / 'scripts/public-synthetic-tests.json').write_text(json.dumps(profile))
            output = root / 'selection.json'
            arguments = [sys.executable, '-B', '-c', producer, str(output)]
            environment = {**os.environ, 'PUBLIC_SYNTHETIC_SCOPE': 'map-interaction-regression'}
            result = subprocess.run(arguments, cwd=root, env=environment, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text()), expected)
            source = root / 'UITests/HeadingUpNavigationTests.swift'
            source.write_text(source.read_text().replace('func testResumePreservesActualPinchZoomAndSelectedStop()',
                                                         'func removedPinchRegression()'))
            output.unlink()
            result = subprocess.run(arguments, cwd=root, env=environment, text=True, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_community_area_scope_runs_exact_production_bundle_storage_and_physical_ui_cases(self):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        header = '          "${WORK[@]}" python3 -B - "$RUNNER_TEMP/selected-tests.json" <<\'PY\'\n'
        producer = textwrap.dedent(workflow.split(header, 1)[1].split('          PY\n', 1)[0])
        expected = {
            'native': [
                'ApartmentFinderTests/PublicCatalogBundleStoreTests/testProductionAppBundleLoadsReviewedPublicCatalogWithoutMapImport',
                'ApartmentFinderTests/PublicCatalogBundleStoreTests/testSavedPackSupplementPreservesGenerationAndPersonalBytesAcrossReopen',
            ],
            'ui': [
                'ApartmentFinderUITests/CommunityMapControlsTests/testPausedControlsStayCompactAndKeepTheirActions',
                'ApartmentFinderUITests/CommunityMapControlsTests/testLyricAndTrendShowTheirCommunityAreasWithoutInventingDoors',
                'ApartmentFinderUITests/OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport',
                'ApartmentFinderUITests/MapAppearanceTests/testMapTypePersistsAcrossDoorReviewDeliveryAdvanceAndRelaunch',
            ],
        }
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'selection.json'
            result = subprocess.run([sys.executable, '-B', '-c', producer, str(output)], cwd=ROOT,
                env={**os.environ, 'PUBLIC_SYNTHETIC_SCOPE': 'community-area-controls-regression'},
                text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text()), expected)
        self.assertIn("'community-area-controls-regression':6", workflow)
        self.assertIn('if [[ "$PUBLIC_SYNTHETIC_SCOPE" == community-area-controls-regression ]]; then EXPECTED_NATIVE_COUNT=6; fi', workflow)

    def test_workflow_optional_test_flags_are_nounset_safe_and_preserve_argument_boundaries(self):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        expansion = '${TEST_LIMITS[@]+"${TEST_LIMITS[@]}"}'
        self.assertIn('"${FILTERS[@]}" ' + expansion + ' test', workflow)
        self.assertNotIn('"${FILTERS[@]}" "${TEST_LIMITS[@]}" test', workflow)
        capture = shlex.quote(sys.executable) + ' -c ' + shlex.quote('import json,sys; print(json.dumps(sys.argv[1:]))')
        for assignment, expected in (('()', ['before', 'after']),
                ('("-flag" "value with spaces" "literal*")', ['before', '-flag', 'value with spaces', 'literal*', 'after'])):
            with self.subTest(assignment=assignment):
                script = 'set -euo pipefail\nTEST_LIMITS=' + assignment + '\n' + capture + ' before ' + expansion + ' after\n'
                result = subprocess.run(['bash'], input=script, text=True, capture_output=True, timeout=2)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), expected)

    def test_workflow_selection_producer_preserves_regression_and_exact_focused_subset(self):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        header = '          "${WORK[@]}" python3 -B - "$RUNNER_TEMP/selected-tests.json" <<\'PY\''
        block = header + '\n' + workflow.split(header + '\n', 1)[1].split(
            '          if [[ "$PUBLIC_SYNTHETIC_SCOPE" == activation-diagnostics ]]; then\n            RUN=', 1)[0]
        profile = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        focused = {'native': [
            'ApartmentFinderTests/OnTracImportSetupTests/testFictionalPackAndExactZIPReachTheTwoDayImportRequestOnIOS',
            'ApartmentFinderTests/PublicCatalogBundleStoreTests/testProductionAppBundleLoadsReviewedPublicCatalogWithoutMapImport',
        ], 'ui': ['ApartmentFinderUITests/OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport']}
        for kind, identities in focused.items():
            self.assertTrue(set(identities) <= set(profile[kind]))
        missing = json.loads(json.dumps(profile))
        missing['native'].remove(focused['native'][1])
        substituted = json.loads(json.dumps(profile))
        substituted['native'][substituted['native'].index(focused['native'][1])] = 'ApartmentFinderTests/OtherTests/testOther'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            for scope, source, expected in (
                    ('regression', profile, profile), ('activation-diagnostics', profile, focused),
                    ('activation-diagnostics', missing, None), ('activation-diagnostics', substituted, None)):
                with self.subTest(scope=scope, bundled_method_present=source == profile):
                    (root / 'scripts/public-synthetic-tests.json').write_text(json.dumps(source))
                    for name in ('selected-tests.json', 'selected-identities.txt'):
                        (root / name).unlink(missing_ok=True)
                    result = subprocess.run(['bash'], input='set -euo pipefail\nWORK=(env)\n' + textwrap.dedent(block),
                        cwd=root, text=True, capture_output=True, timeout=2,
                        env={**os.environ, 'PUBLIC_SYNTHETIC_SCOPE': scope, 'RUNNER_TEMP': str(root)})
                    if expected is None:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertFalse((root / 'selected-tests.json').exists())
                        self.assertFalse((root / 'selected-identities.txt').exists())
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(json.loads((root / 'selected-tests.json').read_text()), expected)
                        self.assertEqual((root / 'selected-identities.txt').read_text().splitlines(),
                                         expected['native'] + expected['ui'])

    def test_workflow_identity_producer_rejects_empty_omitted_duplicate_invalid_and_substituted_selections(self):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        header = '"${WORK[@]}" python3 -B - "$RUNNER_TEMP/selected-tests.json" > "$RUNNER_TEMP/selected-identities.txt" <<\'PY\''
        code = textwrap.dedent(workflow.split(header + '\n', 1)[1].split('\n          PY', 1)[0])
        expected = {'native': [
                        'ApartmentFinderTests/OnTracImportSetupTests/testFictionalPackAndExactZIPReachTheTwoDayImportRequestOnIOS',
                        'ApartmentFinderTests/PublicCatalogBundleStoreTests/testProductionAppBundleLoadsReviewedPublicCatalogWithoutMapImport'],
                    'ui': ['ApartmentFinderUITests/OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport']}
        invalid = ({'native': [], 'ui': []},
                   {'native': expected['native'][:1], 'ui': expected['ui']},
                   {'native': expected['native'][:1] * 2, 'ui': expected['ui']},
                   {'native': [expected['native'][0], 'unsafe;extra'], 'ui': expected['ui']},
                   {'native': [expected['native'][0], 'ApartmentFinderTests/OtherTests/testOther'], 'ui': expected['ui']},
                   {'native': expected['native'][:1], 'ui': expected['ui'] + expected['native'][1:]})
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'selection.json'
            for selection in (expected, *invalid):
                source.write_text(json.dumps(selection))
                result = subprocess.run([sys.executable, '-B', '-', str(source)], input=code,
                    text=True, capture_output=True, timeout=2,
                    env={**os.environ, 'PUBLIC_SYNTHETIC_SCOPE': 'activation-diagnostics'})
                if selection == expected:
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stdout.splitlines(), expected['native'] + expected['ui'])
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, '')

    def test_workflow_cleanup_cannot_hide_a_failure_or_ignore_incomplete_cleanup(self):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        body = workflow.split('          cleanup() {\n', 1)[1].split('\n          trap cleanup EXIT', 1)[0]
        cleanup = textwrap.dedent('          cleanup() {\n' + body)
        for original, cleanup_result, expected in ((0, 0, 0), (0, 1, 1), (65, 1, 65), (124, 1, 124)):
            with self.subTest(original=original, cleanup=cleanup_result):
                script = ('set -euo pipefail\nPUBLIC_SYNTHETIC_SCOPE=activation-diagnostics\n'
                          'DIAGNOSTICS_COLLECTED=1\nDEVICE=synthetic-only\n'
                          f'python3() {{ return {cleanup_result}; }}\n' + cleanup +
                          f'\ntrap cleanup EXIT\nexit {original}\n')
                result = subprocess.run(['bash'], input=script, text=True, capture_output=True, timeout=2)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_debug_manifest_buttons_are_individual_native_toolbar_controls(self):
        support = (ROOT / 'App/UITestSupport.swift').read_text()
        controls = support.split('struct UITestManifestControls:', 1)[1].split('private struct UITestShareSheet:', 1)[0]
        self.assertTrue(controls.startswith(' ToolbarContent'))
        self.assertIn('ToolbarItemGroup(placement: .topBarTrailing)', controls)
        self.assertNotIn('HStack {', controls)
        self.assertEqual(controls.count('.labelStyle(.iconOnly)'), 3)
        self.assertEqual(controls.count('.sheet(item: $sharedFile)'), 1)
        for title, action, identity in (('Mixed', 'mixed', 'test.mixed'),
                                        ('Test import', 'manifestImport', 'test.import'),
                                        ('Test share', 'share', 'test.share')):
            self.assertRegex(controls, r'Button\("' + title + r'", systemImage: "[^"]+"\) \{\s+imports.recordUITestAction\(\.' + action + r'\)')
            self.assertIn('.accessibilityIdentifier("' + identity + '")', controls)
        coordinator = (ROOT / 'App/ManifestImportCoordinator.swift').read_text()
        self.assertIn('func recordUITestAction(', coordinator)
        root = (ROOT / 'App/RootView.swift').read_text()
        self.assertIn('@StateObject private var imports = ManifestImportCoordinator()', root)
        routes = (ROOT / 'App/ApartmentRoutesView.swift').read_text()
        self.assertEqual(routes.count('UITestManifestControls(imports: imports, store: store)'), 2)
        self.assertNotRegex(routes, r'ToolbarItem\(placement: \.topBarTrailing\) \{\s+if UITestSupport.enabled')

    def test_ontrac_ui_setup_uses_the_validated_fixture_without_bypassing_import(self):
        support = (ROOT / 'App/UITestSupport.swift').read_text()
        encoded = re.search(r'Data\(base64Encoded: "([A-Za-z0-9+/=]+)"\)', support).group(1)
        archive = ROOT / 'Tests/ApartmentCoreTests/Fixtures/ontrac-synthetic.zip'
        self.assertEqual(base64.b64decode(encoded, validate=True), archive.read_bytes())
        self.assertIn('static func fictionalManifestPayload() throws -> DataPackPayload', support)
        self.assertIn('guard enabled, storeURL() != nil else', support)
        self.assertIn('guard store.pack?.catalog.packVersion != "fictional-ontrac-v1" else', support)
        self.assertIn('try store.importPrivatePack(fictionalManifestPayload())', support)
        self.assertIn('imports.open(try UITestSupport.manifestURL(), addresses: store.knownApartmentAddresses)', support)
        native = (ROOT / 'NativeTests/OnTracImportSetupTests.swift').read_text()
        for boundary in ('UITestSupport.fictionalManifestPayload()', 'UITestSupport.manifestURL()',
                         'SharedManifestContainer.data(url)', 'ManifestReader.read(', 'coordinator.open('):
            self.assertIn(boundary, native)
        self.assertNotIn('coordinator.request =', native)

    def test_append_restore_fixture_keeps_the_known_door_identity(self):
        source = (ROOT / 'NativeTests/ApartmentRouteFollowupTests.swift').read_text()
        locations = json.loads(re.search(r'let locations = #"(.*?)"#', source).group(1))
        door = re.search(r'let door = Place\(id: "owner-4108",(.*?)\n        try store!\.importBackup',
                         source, re.S).group(1)
        identity = dict(re.findall(r'\b(communityID|building|unit|floor): "([^"]*)"', door))
        candidates = [feature['properties'] for feature in locations['features']
                      if feature['properties']['communityID'] == identity['communityID']
                      and feature['properties']['unit'] == identity['unit']]
        self.assertEqual(len(candidates), 1)
        for field in ('building', 'floor'):
            self.assertEqual(identity.get(field, ''), candidates[0][field],
                             'A known checked door must not contradict its fictional source identity')

    def test_fictional_native_pack_payloads_contain_schema_valid_locations(self):
        fixtures = 0
        for path in sorted((ROOT / 'NativeTests').glob('*.swift')):
            fields = dict(re.findall(r'let (catalog|locations|paths) = #"(.*?)"#', path.read_text()))
            if set(fields) != {'catalog', 'locations', 'paths'}:
                continue
            with self.subTest(source=path.name):
                fixtures += 1
                catalog, locations, paths = (json.loads(fields[key]) for key in ('catalog', 'locations', 'paths'))
                self.assertTrue(catalog['communities'], 'Complete private-pack fixtures need communities')
                self.assertTrue(locations['features'], 'DataPackPayload rejects a complete pack without mapped locations')
                communities = {item['id'] for item in catalog['communities']}
                sources = {item['id'] for item in catalog['sources']}
                self.assertEqual(set(catalog['scopeZIPs']), {'89113', '89148'})
                for collection in (locations, paths):
                    self.assertEqual(collection['type'], 'FeatureCollection')
                    self.assertEqual(collection['schemaVersion'], 1)
                    self.assertEqual(collection['packVersion'], catalog['packVersion'])
                for point in locations['features']:
                    self.assertEqual(point['geometry']['type'], 'Point')
                    lon, lat = point['geometry']['coordinates']
                    self.assertTrue(-180 <= lon <= 180 and -90 <= lat <= 90)
                    properties = point['properties']
                    self.assertTrue({'communityID', 'address', 'building', 'unit', 'floor', 'kind', 'verification', 'sourceIDs', 'notes'} <= set(properties))
                    self.assertIn(properties['communityID'], communities)
                    self.assertTrue(properties['sourceIDs'])
                    self.assertTrue(set(properties['sourceIDs']) <= sources)
        self.assertEqual(fixtures, 10, 'Review new or removed embedded fixtures explicitly')

    def test_reviewed_native_inventory_matches_current_source(self):
        artifact = module('public_preflight_artifact', ROOT / 'scripts/testflight-artifact.py')
        self.assertEqual(artifact.expected_test_count(ROOT), 128)
        profile = json.loads((ROOT / 'scripts/iteration-profile.json').read_text())
        self.assertEqual(profile['full_acceptance'], {'native': 86, 'ui': 42, 'original_pngs': 45})


    def test_public_selection_is_exact_and_excludes_private_acceptance(self):
        selection = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        iteration = module('public_preflight_iteration', ROOT / 'scripts/iterate.py')
        self.assertEqual(selection['schema_version'], 1)
        for key, folder, target, count in (
            ('core', 'Tests/ApartmentCoreTests', '', 123),
            ('native', 'NativeTests', 'ApartmentFinderTests/', 71),
            ('ui', 'UITests', 'ApartmentFinderUITests/', 2),
        ):
            values = selection[key]
            self.assertEqual(len(values), count)
            self.assertEqual(len(values), len(set(values)))
            self.assertTrue(set(values) <= {target + item for item in iteration.test_ids(ROOT, folder)})
        self.assertEqual({item for item in selection['core'] if item.startswith('PublicCatalogBudgetTests/')}, {
            'PublicCatalogBudgetTests/testBundledCatalogAcceptsReviewedGrowthThroughExactPublicBoundary',
            'PublicCatalogBudgetTests/testPublicBoundaryStillRejectsOversizeSymlinksDirectoriesAndMalformedSchema',
            'PublicCatalogBudgetTests/testOversizedPrivateImportStillRejectsEveryEntryPointAndPreservesSelection',
            'PublicCatalogBudgetTests/testLargerPublicSupplementPreservesImportedGenerationAndPersonalDoorPrecedence',
            'PublicCatalogBudgetTests/testReviewedCatalogLoadingMeasurements',
        })
        self.assertEqual(set(selection['ui']), {
            'ApartmentFinderUITests/OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport',
            'ApartmentFinderUITests/OnTracFlowTests/testZIPPreviewCancellationEmptyDayAndApartmentNavigation',
        })
        for identity in selection['core']:
            cls = identity.split('/')[0]
            sources = [path.read_text() for path in (ROOT / 'Tests/ApartmentCoreTests').glob('*.swift')
                       if re.search(r'\bclass\s+' + cls + r'\s*:', path.read_text())]
            self.assertEqual(len(sources), 1)
            self.assertNotIn('PrivatePackFixture', sources[0])
        for identity in selection['native']:
            _, cls, name = identity.split('/')
            source = (ROOT / 'NativeTests' / (cls + '.swift')).read_text()
            start = source.index('func ' + name + '(')
            end = source.find('\n    func test', start + 1)
            body = source[start:end if end >= 0 else len(source)]
            self.assertNotIn('PrivatePackFixture', body)
            if cls == 'AppStoreTests':
                self.assertNotIn('storeURL()', body, 'Mixed helper defaults to the genuine private pack')

    def test_public_workflow_is_manual_and_data_isolated(self):
        path = ROOT / '.github/workflow-drafts/public-synthetic-check.yml'
        if not path.exists():
            path = ROOT / '.github/workflows/public-synthetic-check.yml'
        self.assertTrue(path.is_file())
        workflow = path.read_text()
        self.assertIn('workflow_dispatch:', workflow)
        self.assertIn('runs-on: macos-15-intel', workflow)
        self.assertIn('DEVELOPER_DIR: /Applications/Xcode_26.2.app/Contents/Developer', workflow)
        self.assertIn('com.apple.CoreSimulator.SimRuntime.iOS-26-2', workflow)
        self.assertIn('github.event.repository.private == false', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('contents: read', workflow)
        for forbidden in ('pull_request_target:', 'schedule:', 'push:', 'secrets.', 'upload-artifact', 'actions/cache', 'validate-ios.sh', 'testflight-upload'):
            self.assertNotIn(forbidden, workflow)
        self.assertIn('public-synthetic-tests.json', workflow)
        self.assertIn('verify_native_ids', workflow)
        self.assertIn('verify_core_ids', workflow)
        self.assertIn('full_acceptance=False', workflow)


class WorkflowResultProcessingTests(unittest.TestCase):
    """Execute the workflow's result block with synthetic command fixtures."""
    identities = [
        'ApartmentFinderTests/OnTracImportSetupTests/testFictionalPackAndExactZIPReachTheTwoDayImportRequestOnIOS',
        'ApartmentFinderTests/PublicCatalogBundleStoreTests/testProductionAppBundleLoadsReviewedPublicCatalogWithoutMapImport',
        'ApartmentFinderUITests/OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport',
    ]

    def run_result_block(self, build_status=0, result_exists=True,
                         summary_status=0, tests_status=0, summary=None, tree=None, baseline_status=0):
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text()
        block = workflow.split('            DIAGNOSTICS_COLLECTED=1\n          fi\n', 1)[1]
        summary = summary if summary is not None else {
            'totalTestCount': 3, 'passedTests': 3, 'failedTests': 0,
            'skippedTests': 0, 'expectedFailures': 0,
        }
        tree = tree if tree is not None else {'testNodes': [
            {'nodeType': 'Test Case', 'nodeIdentifier': identity + '()', 'result': 'Passed'}
            for identity in self.identities
        ]}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'summary-source.json').write_text(json.dumps(summary))
            (root / 'tests-source.json').write_text(json.dumps(tree))
            (root / 'selected-tests.json').write_text(json.dumps({
                'native': self.identities[:2], 'ui': self.identities[2:],
            }))
            script = r'''set -euo pipefail
WORK=(bounded_work)
RUN=(run_build)
FILTERS=("-only-testing:synthetic")
TEST_LIMITS=()
BASELINE_STATUS="$BASELINE_FIXTURE_STATUS"
DEVICE=synthetic-only
bounded_work() {
  printf 'work:%s\n' "$*" >> "$CALLS"
  "$@"
}
run_build() { "$@"; }
xcodebuild() {
  printf 'build\n' >> "$CALLS"
  if [[ "$RESULT_EXISTS" == 1 ]]; then mkdir -p "$RUNNER_TEMP/synthetic.xcresult"; fi
  return "$BUILD_STATUS"
}
xcrun() {
  [[ "$#" == 6 && "$1 $2 $3" == 'xcresulttool get test-results' && "$5" == --path ]] || return 99
  [[ "$6" == "$RUNNER_TEMP/synthetic.xcresult" ]] || return 99
  if [[ "$4" == summary ]]; then
    cat "$RUNNER_TEMP/summary-source.json"
    return "$SUMMARY_STATUS"
  fi
  [[ "$4" == tests ]] || return 99
  cat "$RUNNER_TEMP/tests-source.json"
  return "$TESTS_STATUS"
}
python3() {
  if [[ "$*" == '-B scripts/validate-checkout.py '* ]]; then
    printf 'checkout-validation\n' >> "$CALLS"
  else
    printf 'identity-and-count-gates\n' >> "$CALLS"
    "$REAL_PYTHON" "$@"
  fi
}
'''
            result = subprocess.run(['bash'], input=script + textwrap.dedent(block),
                cwd=ROOT, text=True, capture_output=True, timeout=5,
                env={**os.environ, 'RUNNER_TEMP': str(root), 'CALLS': str(root / 'calls'),
                     'REAL_PYTHON': sys.executable, 'PUBLIC_SYNTHETIC_SCOPE': 'activation-diagnostics',
                     'BUILD_STATUS': str(build_status), 'RESULT_EXISTS': str(int(result_exists)),
                     'BASELINE_FIXTURE_STATUS': str(baseline_status),
                     'SUMMARY_STATUS': str(summary_status), 'TESTS_STATUS': str(tests_status)})
            calls = (root / 'calls').read_text().splitlines()
            extracted = {name: json.loads((root / (name + '.json')).read_text())
                         for name in ('summary', 'tests') if (root / (name + '.json')).exists()}
        return result, calls, extracted

    def test_failed_xcodebuild_still_extracts_existing_results_and_keeps_original_status(self):
        for build_status in (65, 124):
            for summary_status, tests_status in ((0, 0), (7, 0), (0, 8), (7, 8)):
                with self.subTest(build=build_status, summary=summary_status, tests=tests_status):
                    result, calls, extracted = self.run_result_block(
                        build_status=build_status, summary_status=summary_status, tests_status=tests_status)
                    self.assertEqual(result.returncode, build_status, result.stderr)
                    self.assertEqual(set(extracted), {'summary', 'tests'})
                    self.assertEqual(sum('xcresulttool get test-results summary ' in item for item in calls), 1)
                    self.assertEqual(sum('xcresulttool get test-results tests ' in item for item in calls), 1)
                    self.assertNotIn('checkout-validation', calls)
                    self.assertNotIn('"passed":', result.stdout)

    def test_failed_result_data_cannot_replace_the_original_xcodebuild_status(self):
        tree = {'testNodes': [{'nodeType': 'Test Case',
            'nodeIdentifier': self.identities[0] + '()', 'result': 'Failed'}]}
        result, calls, extracted = self.run_result_block(build_status=65, tree=tree)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(set(extracted), {'summary', 'tests'})
        self.assertNotIn('identity-and-count-gates', calls)
        self.assertNotIn('checkout-validation', calls)

    def test_incomplete_baseline_cannot_pass_or_replace_the_original_xcodebuild_failure(self):
        for build_status, expected in ((0, 17), (65, 65), (124, 124)):
            with self.subTest(build_status=build_status):
                result, calls, extracted = self.run_result_block(build_status=build_status, baseline_status=17)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(set(extracted), {'summary', 'tests'})
                self.assertNotIn('identity-and-count-gates', calls)
                self.assertNotIn('checkout-validation', calls)
                self.assertNotIn('"passed":', result.stdout)

    def test_missing_result_keeps_failure_and_cannot_pass_a_successful_build(self):
        for build_status in (0, 65, 124):
            with self.subTest(build=build_status):
                result, calls, extracted = self.run_result_block(
                    build_status=build_status, result_exists=False)
                self.assertEqual(result.returncode, build_status or 1, result.stderr)
                self.assertEqual(extracted, {})
                self.assertFalse(any('xcresulttool' in item for item in calls))
                self.assertNotIn('checkout-validation', calls)

    def test_success_still_requires_both_extractions_and_exact_identity_count_gates(self):
        result, calls, extracted = self.run_result_block()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(extracted), {'summary', 'tests'})
        self.assertIn('identity-and-count-gates', calls)
        self.assertIn('checkout-validation', calls)
        self.assertEqual(json.loads(result.stdout), {
            'scope': 'public-synthetic-activation-diagnostics', 'passed': 3,
            'full_acceptance': False, 'release_eligible': False,
        })
        invalid_results = [
            {'summary_status': 7}, {'tests_status': 8},
            {'tree': {'testNodes': []}},
            {'tree': {'testNodes': [
                {'nodeType': 'Test Case', 'nodeIdentifier': self.identities[0] + '()', 'result': 'Passed'},
                {'nodeType': 'Test Case', 'nodeIdentifier': self.identities[1] + '()', 'result': 'Passed'},
                {'nodeType': 'Test Case', 'nodeIdentifier': 'ApartmentFinderUITests/OtherTests/testOther()', 'result': 'Passed'},
            ]}},
        ]
        nodes = extracted['tests']['testNodes']
        for index in range(len(nodes)):
            invalid_results.append({'tree': {'testNodes': nodes[:index] + nodes[index + 1:]}})
        invalid_results.append({'tree': {'testNodes': [nodes[0], nodes[0], nodes[2]]}})
        invalid_results.append({'tree': {'testNodes': nodes + [nodes[1]]}})
        for identity, status in (('unsafe;extra', 'Passed'), (self.identities[1] + '()', 'Failed'),
                                 (self.identities[1] + '()', 'Skipped'), (self.identities[1] + '()', 'Expected Failure')):
            invalid_results.append({'tree': {'testNodes': [nodes[0],
                dict(nodes[1], nodeIdentifier=identity, result=status), nodes[2]]}})
        for field in ('failedTests', 'skippedTests', 'expectedFailures'):
            summary = dict(extracted['summary'])
            summary[field] = 1
            if field != 'expectedFailures':
                summary['passedTests'] = 2
            invalid_results.append({'summary': summary})
        summary = dict(extracted['summary'], totalTestCount=0, passedTests=0)
        invalid_results.append({'summary': summary})
        for count in (2, 4):
            invalid_results.append({'summary': dict(extracted['summary'], totalTestCount=count, passedTests=count)})
        invalid_results.append({'summary': dict(extracted['summary'], passedTests=2)})
        for field in extracted['summary']:
            summary = dict(extracted['summary'])
            del summary[field]
            invalid_results.append({'summary': summary})
            for value in (None, True, '3'):
                invalid_results.append({'summary': dict(extracted['summary'], **{field: value})})
        for changes in invalid_results:
            with self.subTest(changes=changes):
                result, calls, _ = self.run_result_block(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('checkout-validation', calls)
                self.assertNotIn('"passed":', result.stdout)


if __name__ == '__main__':
    unittest.main()
