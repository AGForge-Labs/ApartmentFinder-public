#if DEBUG
import SwiftUI
import UIKit
import ApartmentCore

/// Simulator-only controls are enabled explicitly by the UI test process.
enum UITestSupport {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--uitesting") }
    static func storeURL() -> URL? {
        guard enabled, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--test-store"),
              ProcessInfo.processInfo.arguments.count > index + 1 else { return nil }
        let id = ProcessInfo.processInfo.arguments[index+1]
        guard UUID(uuidString: id) != nil else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("UITest-\(id).store")
    }
    // Keep the original no-pack UI regression explicit after shipping a public bundle.
    static var loadPublicCatalog: Bool {
        #if targetEnvironment(simulator)
        return !(enabled && storeURL() != nil &&
            ProcessInfo.processInfo.arguments.contains("--without-public-catalog"))
        #else
        return true
        #endif
    }
    static func preferences() -> UserDefaults {
        guard let testStore = storeURL() else { return .standard }
        return UserDefaults(suiteName: "dev.galaxybigbird.ApartmentFinder.\(testStore.deletingPathExtension().lastPathComponent)") ?? .standard
    }
    static func resetInboxIfRequested() {
        guard enabled, ProcessInfo.processInfo.arguments.contains("--reset-test-inbox"),
              let inbox = try? SharedManifestContainer.inbox(), let items = try? inbox.pending() else { return }
        for item in items { try? inbox.remove(item.id) }
    }
    @MainActor static func prepareFictionalManifest(in store: AppStore) throws {
        guard enabled, storeURL() != nil else {
            throw CoreError("Fictional UI fixtures require an isolated test store.")
        }
        guard store.pack?.catalog.packVersion != "fictional-ontrac-v1" else { return }
        SyntheticUIDiagnostics.fixture(.installing, store: store)
        do {
            try store.importPrivatePack(fictionalManifestPayload())
            SyntheticUIDiagnostics.fixture(.ready, store: store)
        } catch {
            SyntheticUIDiagnostics.fixture(.failed, store: store)
            throw error
        }
    }
    static func fictionalManifestPayload() throws -> DataPackPayload {
        let catalog = #"{"schemaVersion":1,"packVersion":"fictional-ontrac-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-map","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-courtyard","name":"Fictional Courtyard","address":"1200 Fictional Courtyard Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented parser and storage test fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
        let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ontrac-v1","features":[{"type":"Feature","id":"fictional-position-4102","geometry":{"type":"Point","coordinates":[0.0,0.0]},"properties":{"communityID":"fictional-courtyard","address":"1200 Fictional Courtyard Way","building":"F","unit":"4102","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression coordinates; no real location is asserted."}},{"type":"Feature","id":"fictional-position-4108","geometry":{"type":"Point","coordinates":[0.001,0.001]},"properties":{"communityID":"fictional-courtyard","address":"1200 Fictional Courtyard Way","building":"F","unit":"4108","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression coordinates; no real location is asserted."}}]}"#
        let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ontrac-v1","features":[]}"#
        return try DataPackPayload(catalog: Data(catalog.utf8), locations: Data(locations.utf8), paths: Data(paths.utf8))
    }
    static func manifestURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OnTrac-simulation.zip")
        let data = Data(base64Encoded: "UEsDBBQAAAAIAAAAIQAeWXZTmQAAAMkAAAAXAAAAbWFuaWZlc3RfMjAyNi0wMS0wMi5jc3ZVzkELgjAcBfB7n+LheYizDnZcZiKIhjOl43AjBHO1rcBvn0JC/U8PHvze/yBMp6UiubAOyVuN7ifC9fdvlZ45Bt0J1+uRcPVEoQmT0ihrN2Q5j4ZBgFMW11lZsBxxeanqK6uOaNkV7OGwo0HoI2ccTZIy7qNofER7SrfeH9F3y4gYEOuXcZMwEq2YViIimB9Co27CkplYhQ9QSwMEFAAAAAgAAAAhABs9htw3AAAARAAAABcAAABtYW5pZmVzdF8yMDI2LTAxLTAxLmNzdnNKLErOT0nV8UksLlFwLUvNK0FiKpRk5kKl3AOCFXLykxNLMvPzdIJTCxX88nUcU1KKUouLuQBQSwECFAMUAAAACAAAACEAHll2U5kAAADJAAAAFwAAAAAAAAAAAAAApIEAAAAAbWFuaWZlc3RfMjAyNi0wMS0wMi5jc3ZQSwECFAMUAAAACAAAACEAGz2G3DcAAABEAAAAFwAAAAAAAAAAAAAApIHOAAAAbWFuaWZlc3RfMjAyNi0wMS0wMS5jc3ZQSwUGAAAAAAIAAgCKAAAAOgEAAAAA")!
        try data.write(to: url, options: .atomic)
        return url
    }
}
@MainActor
struct UITestManifestControls: ToolbarContent {
    @ObservedObject var imports: ManifestImportCoordinator
    @ObservedObject var store: AppStore
    private struct SharedFile: Identifiable { let id = UUID(); let url: URL }
    @State private var sharedFile: SharedFile?
    private var importStatus: String {
        "mixedAttempts=\(imports.uiTestMixedAttempts);importAttempts=\(imports.uiTestImportAttempts);shareAttempts=\(imports.uiTestShareAttempts);lastAction=\(imports.uiTestLastAction?.rawValue ?? "none");fixtureReady=\(store.pack?.catalog.packVersion == "fictional-ontrac-v1");loading=\(imports.loading);documents=\(imports.request?.documents.count ?? 0);errorPresent=\(store.errorMessage != nil || imports.error != nil)"
    }
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Mixed", systemImage: "list.number") {
                imports.recordUITestAction(.mixed)
                do {
                    let arguments = ProcessInfo.processInfo.arguments
                    let replacement = arguments.contains("--replacement-manifest")
                    let name = replacement ? (store.personal.stops.isEmpty ? "Previous-day.csv" : "New-day.csv") : "Mixed-simulation.csv"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    let csv: String
                    if replacement {
                        csv = store.personal.stops.isEmpty
                            ? "sequence,address,unit,notes\n11,7413 W Russell Rd,101,\n19,8960 W Post Rd,101,\n27,7255 W Sunset Rd,2066,\n"
                            : "sequence,address,unit,notes\n11,7413 W Russell Rd,107,\n3,7255 W Sunset Rd,2137,\n1,7255 W Sunset Rd,2066,\n"
                    } else if arguments.contains("--numbered-ontrac-manifest") {
                        // Public community addresses with synthetic deliveries, deliberately
                        // out of order like the exports that exposed the row-number bug.
                        csv = "Barcode,Last Event,Last Event Time,Last GPS Location,Seq No,Address\n" +
                            ",,,,58,5453 S Durango Dr Apt 1002\n" +
                            ",,,,20,8150 Rafael Rivera Way Apt 1011\n" +
                            ",,,,3,200 Synthetic Office St Suite 800\n" +
                            ",,,,21,8251 W Sunset Rd Apt 1024\n" +
                            ",,,,1,7255 W Sunset Rd Apt 2066\n" +
                            ",,,,1.2,7255 W Sunset Rd Apt 2149\n" +
                            ",,,,1,7255 W Sunset Rd Apt 2137\n"
                    } else if arguments.contains("--coverage-level25-durango") {
                        csv = "sequence,address,unit,notes\n1,5453 S Durango Dr,1002,Synthetic test delivery\n2,5453 S Durango Dr,2052,Synthetic test delivery\n"
                    } else if arguments.contains("--coverage-san-tropez") {
                        csv = "sequence,address,unit,notes\n1,8025 W Russell Rd,1001,Synthetic test delivery\n2,8025 W Russell Rd,1043,Synthetic test delivery\n"
                    } else if arguments.contains("--coverage-tango-bay") {
                        csv = "sequence,address,unit,notes\n1,7413 W Russell Rd,101,Synthetic test delivery\n2,7413 W Russell Rd,107,Synthetic test delivery\n"
                    } else if arguments.contains("--coverage-vistana") {
                        csv = "sequence,address,unit,notes\n1,7103 S Durango Dr,102,Synthetic test delivery\n2,7163 S Durango Dr,102,Synthetic test delivery\n"
                    } else if arguments.contains("--coverage-south-beach") {
                        csv = "sequence,address,unit,notes\n1,8920 W Russell Rd,2001,Synthetic test delivery\n2,8920 W Russell Rd,2002,Synthetic test delivery\n"
                    } else if arguments.contains("--community-area-manifest") {
                        // Public operator labels with invented deliveries, never an owner's manifest.
                        csv = "sequence,address,unit,notes\n1,304 E Silverado Ranch Blvd,1193,Synthetic regression\n2,304 E Silverado Ranch Blvd,2171,Synthetic regression\n3,240 E Silverado Ranch Blvd,PUBLIC-TEST-A,Synthetic unmapped unit\n4,240 E Silverado Ranch Blvd,PUBLIC-TEST-B,Synthetic unmapped unit\n"
                    } else if arguments.contains("--estimated-entry-manifest") {
                        // Invented deliveries against reviewed public references, never an owner's route.
                        csv = "sequence,address,unit,notes\n1,9400 Bermuda Rd,126,Synthetic estimated-entry regression\n2,9490 Bermuda Rd,1022,Synthetic separate-street regression\n3,304 E Silverado Ranch Blvd,1014,Synthetic shared-entry regression\n4,304 E Silverado Ranch Blvd,1287,Synthetic unresolved-door regression\n"
                    } else if arguments.contains("--reviewed-89123-manifest") {
                        csv = "sequence,address,unit,notes\n1,1450 E Pebble Rd,1000,Synthetic regression\n2,1450 E Pebble Rd,1001,Synthetic regression\n3,1450 E Pebble Rd,1159,Synthetic regression\n4,8680 Ensworth St,101,Synthetic regression\n5,8680 Ensworth St,201,Synthetic regression\n6,2725 W Wigwam Ave,1041,Synthetic regression\n7,2725 W Wigwam Ave,1044,Synthetic regression\n8,2750 W Wigwam Ave,1101,Synthetic regression\n9,8255 S Las Vegas Blvd,101,Synthetic regression\n"
                    } else if arguments.contains("--tuscano-manifest") {
                        let units = arguments.contains("--unmapped-units") ? ["9998", "9999"] : ["2066", "2137"]
                        csv = "sequence,address,unit,notes\n1,123 Synthetic House Ln,,\n2,7255 W Sunset Rd,\(units[0]),Follow the marked pedestrian entrance and check the building sign before approaching. These are simulated instructions for checking long notes. Leave the parcel only at the unit door after checking the building number.\n3,7255 W Sunset Rd,\(units[1]),Simulator regression\n"
                    } else if arguments.contains("--ambiguous-manifest") {
                        // Riley's formerly duplicated labels are separate properties.
                        // SW1175 retains two genuine source candidates at one street.
                        csv = "sequence,address,unit,notes\n1,6355 S Durango Dr,1075,\n2,6355 S Durango Dr,1175,\n"
                    } else {
                        csv = "sequence,address,unit,notes\n1,123 Synthetic House Ln,,\n2,9314 W Russell Rd,108,\n3,7960 Rafael Rivera Wy,1379,\n4,200 Synthetic Office St Suite 3,,\n5,9314 W Russell Rd,109,\n6,7960 Rafael Rivera Wy,,\n"
                    }
                    try Data(csv.utf8).write(to: url, options: .atomic)
                    imports.open(url, addresses: store.knownApartmentAddresses)
                } catch { store.errorMessage = error.localizedDescription }
            }.labelStyle(.iconOnly).accessibilityIdentifier("test.mixed")
            Button("Test import", systemImage: "square.and.arrow.down") {
                imports.recordUITestAction(.manifestImport)
                do {
                    try UITestSupport.prepareFictionalManifest(in: store)
                    imports.open(try UITestSupport.manifestURL(), addresses: store.knownApartmentAddresses)
                }
                catch { store.errorMessage = error.localizedDescription }
            }.labelStyle(.iconOnly).accessibilityIdentifier("test.import")
                .accessibilityValue(Text(verbatim: importStatus))
            Button("Test share", systemImage: "square.and.arrow.up") {
                imports.recordUITestAction(.share)
                do {
                    try UITestSupport.prepareFictionalManifest(in: store)
                    sharedFile = SharedFile(url: try UITestSupport.manifestURL())
                }
                catch { store.errorMessage = error.localizedDescription }
            }.labelStyle(.iconOnly).accessibilityIdentifier("test.share")
                .sheet(item: $sharedFile) { file in UITestShareSheet(url: file.url) }
        }
    }
}
private struct UITestShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Fixed scalars only. Nothing is recorded outside an explicitly isolated simulator probe.
@MainActor
enum SyntheticUIDiagnostics {
    enum Probe: String { case toolbar, production, bannerPassThrough, toolbarRecheck }
    enum FixturePhase: String { case idle, installing, ready, failed }
    private enum Event: String {
        case rootAppeared, sceneChanged, actionEntered, fixtureStarted, fixtureReady, fixtureFailed
        case openStarted, requestPublished, readFailed, loadingEnded, manifestSheetAppeared
        case manifestPickerChanged, settingsChanged, packPickerChanged, documentPickerObserved
    }
    private struct Snapshot: Encodable {
        let schemaVersion = 1
        var probe = "toolbar"
        var sequence = 0
        var lastEvent = "rootAppeared"
        var scenePhase = "unknown"
        var rootAppearances = 0
        var coordinatorInstance = 0
        var actionCount = 0
        var lastAction = "none"
        var fixturePhase = "idle"
        var coordinatorPhase = "idle"
        var requiresPrivatePack = true
        var privatePackImportPending = false
        var loading = false
        var requestPresent = false
        var documentCount = 0 // Three means more than the two expected documents.
        var manifestSheetAppeared = false
        var manifestPickerRequested = false
        var settingsPresented = false
        var packPickerRequested = false
        var errorPresent = false
        var bannerHitTestingDisabled = false
        var documentPickerWasPresented = false
        var pickerObservationCompleted = false
        var writeFailures = 0
    }
    private static var snapshot = Snapshot()
    private static var coordinatorCount = 0
    private(set) static var pinHostCameraRevision = 0
    private(set) static var pinHostCameraEventUptime: TimeInterval = 0
    static func pinHostCameraChanged() {
        guard enabled, ProcessInfo.processInfo.arguments.contains("--synthetic-pin-host-probe") else { return }
        pinHostCameraRevision = min(4096, pinHostCameraRevision + 1)
        pinHostCameraEventUptime = ProcessInfo.processInfo.systemUptime
    }
    private static var probe: Probe? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--synthetic-diagnostic-probe"),
              index + 1 < arguments.count else { return nil }
        return Probe(rawValue: arguments[index + 1])
    }
    static var enabled: Bool {
        #if targetEnvironment(simulator)
        return UITestSupport.enabled && UITestSupport.storeURL() != nil && probe != nil &&
            ProcessInfo.processInfo.arguments.contains("--synthetic-ui-diagnostics")
        #else
        return false
        #endif
    }
    static var bannerHitTestingDisabled: Bool {
        enabled && probe == .bannerPassThrough
    }
    static func nextCoordinatorInstance() -> Int {
        guard enabled else { return 0 }
        coordinatorCount = min(64, coordinatorCount + 1)
        return coordinatorCount
    }
    private static func capture(_ store: AppStore, imports: ManifestImportCoordinator) {
        snapshot.requiresPrivatePack = store.requiresPrivatePack
        snapshot.privatePackImportPending = store.privatePackImportPending
        snapshot.errorPresent = store.errorMessage != nil || imports.error != nil
        capture(imports)
    }
    private static func capture(_ imports: ManifestImportCoordinator) {
        snapshot.coordinatorInstance = imports.uiTestDiagnosticInstance
        snapshot.loading = imports.loading
        snapshot.requestPresent = imports.request != nil
        snapshot.documentCount = min(3, imports.request?.documents.count ?? 0)
        snapshot.errorPresent = snapshot.errorPresent || imports.error != nil
    }
    static func rootAppeared(store: AppStore, imports: ManifestImportCoordinator, phase: ScenePhase) {
        guard enabled else { return }
        snapshot.rootAppearances = min(64, snapshot.rootAppearances + 1)
        capture(store, imports: imports)
        setScene(phase)
        write(.rootAppeared)
    }
    static func sceneChanged(_ phase: ScenePhase, store: AppStore, imports: ManifestImportCoordinator) {
        guard enabled else { return }
        capture(store, imports: imports)
        setScene(phase)
        write(.sceneChanged)
    }
    private static func setScene(_ phase: ScenePhase) {
        switch phase {
        case .active: snapshot.scenePhase = "active"
        case .inactive: snapshot.scenePhase = "inactive"
        case .background: snapshot.scenePhase = "background"
        @unknown default: snapshot.scenePhase = "unknown"
        }
    }
    static func actionEntered(_ action: ManifestImportCoordinator.UITestAction, imports: ManifestImportCoordinator) {
        guard enabled else { return }
        snapshot.actionCount = min(64, snapshot.actionCount + 1)
        snapshot.lastAction = action.rawValue
        capture(imports)
        write(.actionEntered)
    }
    static func fixture(_ phase: FixturePhase, store: AppStore) {
        guard enabled else { return }
        snapshot.fixturePhase = phase.rawValue
        snapshot.requiresPrivatePack = store.requiresPrivatePack
        snapshot.privatePackImportPending = store.privatePackImportPending
        snapshot.errorPresent = snapshot.errorPresent || phase == .failed
        switch phase {
        case .installing: write(.fixtureStarted)
        case .ready: write(.fixtureReady)
        case .failed: write(.fixtureFailed)
        case .idle: break
        }
    }
    static func openStarted(_ imports: ManifestImportCoordinator) {
        guard enabled else { return }
        capture(imports)
        snapshot.coordinatorPhase = "reading"
        write(.openStarted)
    }
    static func requestPublished(_ imports: ManifestImportCoordinator) {
        guard enabled else { return }
        capture(imports)
        snapshot.coordinatorPhase = "published"
        write(.requestPublished)
    }
    static func readFailed(_ imports: ManifestImportCoordinator) {
        guard enabled else { return }
        capture(imports)
        snapshot.coordinatorPhase = "failed"
        write(.readFailed)
    }
    static func loadingEnded(_ imports: ManifestImportCoordinator) {
        guard enabled else { return }
        capture(imports)
        write(.loadingEnded)
    }
    static func manifestSheetAppeared() {
        guard enabled else { return }
        snapshot.manifestSheetAppeared = true
        write(.manifestSheetAppeared)
    }
    static func manifestPickerChanged(_ requested: Bool) {
        guard enabled else { return }
        snapshot.manifestPickerRequested = requested
        write(.manifestPickerChanged)
        if requested { observeDocumentPicker() }
    }
    static func settingsChanged(_ presented: Bool) {
        guard enabled else { return }
        snapshot.settingsPresented = presented
        write(.settingsChanged)
    }
    static func packPickerChanged(_ requested: Bool) {
        guard enabled else { return }
        snapshot.packPickerRequested = requested
        write(.packPickerChanged)
    }
    // A positive public-UIKit witness only. SwiftUI does not promise this host
    // controller, so a bounded negative observation cannot prove picker absence.
    private static func observeDocumentPicker() {
        guard enabled, probe == .production else { return }
        snapshot.pickerObservationCompleted = false
        Task { @MainActor in
            let delays = [UInt64(0), 500_000_000, 1_000_000_000]
            for (index, delay) in delays.enumerated() {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard enabled, probe == .production else { return }
                snapshot.documentPickerWasPresented = snapshot.documentPickerWasPresented || documentPickerInForegroundScene()
                if index == delays.count - 1 { snapshot.pickerObservationCompleted = true }
                write(.documentPickerObserved)
            }
        }
    }
    private static func documentPickerInForegroundScene() -> Bool {
        var pending = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap { $0.windows }.filter { !$0.isHidden && $0.alpha > 0 }
            .prefix(8).compactMap { $0.rootViewController }
        var visited = Set<ObjectIdentifier>()
        while let controller = pending.popLast(), visited.count < 64 {
            guard visited.insert(ObjectIdentifier(controller)).inserted else { continue }
            if controller is UIDocumentPickerViewController,
               controller.viewIfLoaded?.window != nil, !controller.isBeingDismissed { return true }
            pending.append(contentsOf: controller.children.prefix(8))
            if let presented = controller.presentedViewController { pending.append(presented) }
        }
        return false
    }
    private static func write(_ event: Event) {
        guard enabled, let probe, snapshot.sequence < 4096 else { return }
        // The instrumented replay must preserve the original launch's witness.
        guard !ProcessInfo.processInfo.arguments.contains("--synthetic-pin-host-probe") else { return }
        snapshot.probe = probe.rawValue
        snapshot.bannerHitTestingDisabled = bannerHitTestingDisabled
        snapshot.sequence += 1
        snapshot.lastEvent = event.rawValue
        do {
            let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches/SyntheticUIDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= 8192 else { snapshot.writeFailures = min(64, snapshot.writeFailures + 1); return }
            try data.write(to: directory.appendingPathComponent(probe.rawValue + ".json"), options: .atomic)
        } catch { snapshot.writeFailures = min(64, snapshot.writeFailures + 1) }
    }
}

@MainActor
struct SyntheticBannerHitTestProbe: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if SyntheticUIDiagnostics.bannerHitTestingDisabled {
            content.allowsHitTesting(false)
        } else { content }
    }
}

@MainActor
struct SyntheticDiagnosticStatus: ViewModifier {
    @ObservedObject var imports: ManifestImportCoordinator
    @ViewBuilder func body(content: Content) -> some View {
        if SyntheticUIDiagnostics.enabled {
            content.accessibilityValue(Text(verbatim: imports.uiTestActionStatus))
        } else { content }
    }
}
#endif
