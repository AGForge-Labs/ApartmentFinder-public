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
        let catalog = #"{"schemaVersion":1,"packVersion":"fictional-ontrac-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-map","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-courtyard","name":"Fictional Courtyard","address":"1200 Fictional Courtyard Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented parser and storage test fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
        let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ontrac-v1","features":[{"type":"Feature","id":"fictional-position-4102","geometry":{"type":"Point","coordinates":[0.0,0.0]},"properties":{"communityID":"fictional-courtyard","address":"1200 Fictional Courtyard Way","building":"F","unit":"4102","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression coordinates; no real location is asserted."}},{"type":"Feature","id":"fictional-position-4108","geometry":{"type":"Point","coordinates":[0.001,0.001]},"properties":{"communityID":"fictional-courtyard","address":"1200 Fictional Courtyard Way","building":"F","unit":"4108","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression coordinates; no real location is asserted."}}]}"#
        let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ontrac-v1","features":[]}"#
        try store.importPrivatePack(DataPackPayload(catalog: Data(catalog.utf8), locations: Data(locations.utf8), paths: Data(paths.utf8)))
    }
    static func manifestURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OnTrac-simulation.zip")
        let data = Data(base64Encoded: "UEsDBBQAAAAIAAAAIQAeWXZTmQAAAMkAAAAXAAAAbWFuaWZlc3RfMjAyNi0wMS0wMi5jc3ZVzkELgjAcBfB7n+LheYizDnZcZiKIhjOl43AjBHO1rcBvn0JC/U8PHvze/yBMp6UiubAOyVuN7ifC9fdvlZ45Bt0J1+uRcPVEoQmT0ihrN2Q5j4ZBgFMW11lZsBxxeanqK6uOaNkV7OGwo0HoI2ccTZIy7qNofER7SrfeH9F3y4gYEOuXcZMwEq2YViIimB9Co27CkplYhQ9QSwMEFAAAAAgAAAAhABs9htw3AAAARAAAABcAAABtYW5pZmVzdF8yMDI2LTAxLTAxLmNzdnNKLErOT0nV8UksLlFwLUvNK0FiKpRk5kKl3AOCFXLykxNLMvPzdIJTCxX88nUcU1KKUouLuQBQSwECFAMUAAAACAAAACEAHll2U5kAAADJAAAAFwAAAAAAAAAAAAAApIEAAAAAbWFuaWZlc3RfMjAyNi0wMS0wMi5jc3ZQSwECFAMUAAAACAAAACEAGz2G3DcAAABEAAAAFwAAAAAAAAAAAAAApIHOAAAAbWFuaWZlc3RfMjAyNi0wMS0wMS5jc3ZQSwUGAAAAAAIAAgCKAAAAOgEAAAAA")!
        try data.write(to: url, options: .atomic)
        return url
    }
}
struct UITestManifestControls: View {
    @ObservedObject var imports: ManifestImportCoordinator
    @ObservedObject var store: AppStore
    private struct SharedFile: Identifiable { let id = UUID(); let url: URL }
    @State private var sharedFile: SharedFile?
    var body: some View {
        HStack {
            Button("Mixed") {
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
            }.accessibilityIdentifier("test.mixed")
            Button("Test import") {
                do {
                    try UITestSupport.prepareFictionalManifest(in: store)
                    imports.open(try UITestSupport.manifestURL(), addresses: store.knownApartmentAddresses)
                }
                catch { store.errorMessage = error.localizedDescription }
            }.accessibilityIdentifier("test.import")
            Button("Test share") {
                do {
                    try UITestSupport.prepareFictionalManifest(in: store)
                    sharedFile = SharedFile(url: try UITestSupport.manifestURL())
                }
                catch { store.errorMessage = error.localizedDescription }
            }.accessibilityIdentifier("test.share")
        }
        .sheet(item: $sharedFile) { file in UITestShareSheet(url: file.url) }
    }
}
private struct UITestShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
