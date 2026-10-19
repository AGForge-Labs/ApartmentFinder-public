import SwiftUI
import UniformTypeIdentifiers
import ApartmentCore

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

func readSelectedFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let granted = url.startAccessingSecurityScopedResource()
    defer { if granted { url.stopAccessingSecurityScopedResource() } }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= maximumBytes else { throw CoreError("The selected file is too large.") }
    let data = try Data(contentsOf: url)
    guard data.count <= maximumBytes else { throw CoreError("The selected file is too large.") }
    return data
}

func readSelectedDataPack(_ url: URL) throws -> DataPackPayload {
    let granted = url.startAccessingSecurityScopedResource()
    defer { if granted { url.stopAccessingSecurityScopedResource() } }
    var failure: NSError?
    var result: Result<DataPackPayload, Error>?
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &failure) { coordinated in
        result = Result { try DataPackPayload.read(directory: coordinated) }
    }
    if let failure { throw failure }
    guard let result else { throw CoreError("The selected map-pack folder could not be read.") }
    return try result.get()
}

@MainActor
func importSelectedPrivatePack(_ result: Result<URL, Error>, into store: AppStore, location: LocationService) {
    if case .failure(let error) = result {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError { return }
        store.errorMessage = error.localizedDescription
        return
    }
    guard !location.recordingNeedsFinish else {
        store.errorMessage = "Finish and save the recorded path section before importing a map pack. Your recorded points are unchanged."
        return
    }
    Task {
        do {
            let url = try result.get()
            guard !location.recordingNeedsFinish else {
                throw CoreError("Finish and save the recorded path section before importing a map pack. Your recorded points are unchanged.")
            }
            try await store.importPrivatePack(from: url)
        } catch is CancellationError {
            // Cancelled before activation; the existing selection stays installed.
        } catch { store.errorMessage = error.localizedDescription }
    }
}

struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    @Binding var offline: Bool
    @State private var exporting = false
    @State private var importing = false
    @State private var importingPack = false
    @State private var confirmImport = false
    @State private var document = BackupDocument(data: Data())
    @State private var pendingBackup: Data?
    @State private var pathEditor: PathSegment?
    @State private var pinEditor: Place?
    @AppStorage("installationProbeCounter") private var probeCounter = 0
    var body: some View {
        NavigationStack {
            List {
                Section("On this phone") {
                    LabeledContent("Communities",value: "\(store.communities.count)")
                    LabeledContent("Mapped unit positions",value: "\(store.pack?.places.filter { $0.kind == .unitPosition }.count ?? 0)")
                    LabeledContent("Verified doors",value: "\(store.places.filter { $0.kind == .door && $0.verification == .fieldVerified }.count)")
                    LabeledContent("Personal pins / paths",value: "\(store.personal.places.count) / \(store.personal.paths.count)")
                    Text("Inventory research is incomplete. Mapped unit positions do not establish exact doors.").font(.caption).foregroundStyle(.orange)
                    Text("Map pack \(store.pack?.catalog.packVersion ?? "not loaded")").font(.caption).foregroundStyle(.secondary)
                    Text(store.packStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Import private map pack", systemImage: "folder") { importingPack = true }
                        .disabled(store.privatePackImportPending || location.recordingNeedsFinish)
                    if location.recordingNeedsFinish { Text("Save the recorded path section before importing a map pack.").font(.caption) }
                    if store.privatePackImportPending { ProgressView("Importing map pack…") }
                    Text("Select the folder containing your complete map pack. Personal pins, paths and stops stay separate.").font(.caption)
                }
                Section("Maps and navigation") {
                    Toggle("Use offline local map",isOn: $offline)
                    Text("Local maps, lookups and confirmed internal routes stay on the phone. Satellite imagery and public-road navigation need a connection.").font(.caption)
                    Text(ServiceConfiguration.status).font(.caption).foregroundStyle(.secondary)
                    Button("Allow location during active trips") { location.requestBackgroundPermission() }
                    Button("Stop navigation and recording") { location.stop() }
                    Link("© OpenStreetMap contributors · ODbL",destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                }
                Section("Backup") {
                    Button("Export personal pins, paths and stops",systemImage: "square.and.arrow.up") {
                        do { document = BackupDocument(data: try store.personal.data()); exporting = true }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                    Button("Import a backup",systemImage: "square.and.arrow.down") { importing = true }
                        .disabled(store.privatePackImportPending)
                    Text("Export before changing the Apple signing account or deleting the app. Updates preserve your corrections separately from the research pack.").font(.caption)
                }
                Section("Installation check") {
                    LabeledContent("Saved test counter",value: "\(probeCounter)")
                    Button("Increase test counter") { probeCounter += 1 }
                    Text("The counter should survive app updates and weekly renewal with the same signing identity.").font(.caption)
                    Text("Signing ID: \(Bundle.main.bundleIdentifier ?? "unknown")").font(.caption.monospaced()).textSelection(.enabled)
                }
                Section("Community coverage") {
                    ForEach(store.communities) { community in
                        NavigationLink {
                            CoverageDetail(store: store,community: community,editPin: { pinEditor = $0 },editPath: { pathEditor = $0 })
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(community.name)
                                Text("\(community.zip) · \(store.places.filter { $0.communityID == community.id }.count) positions").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.disabled(store.privatePackImportPending).navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .fileExporter(isPresented: $exporting,document: document,contentType: .json,defaultFilename: "ApartmentFinder-backup-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
                    if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
                }
                .fileImporter(isPresented: $importing,allowedContentTypes: [.json]) { result in
                    do {
                        let data = try readSelectedFile(result.get(),maximumBytes: 25_000_000)
                        _ = try PersonalBackup.read(data); pendingBackup = data; confirmImport = true
                    } catch { store.errorMessage = error.localizedDescription }
                }
                .fileImporter(isPresented: $importingPack, allowedContentTypes: [.folder]) { result in
                    importSelectedPrivatePack(result, into: store, location: location)
                }
                .confirmationDialog("Merge backed-up pins and paths, and replace the active stop list?",isPresented: $confirmImport,titleVisibility: .visible) {
                    Button("Import backup") {
                        do { if let pendingBackup { try store.importBackup(pendingBackup) }; pendingBackup = nil }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                } message: { Text("Matching pin/path IDs use the backup version. Other personal pins and paths remain. Export first if you want to keep the current versions.") }
                .sheet(item: $pathEditor) { PathEditor(store: store,location: location,path: $0,offline: offline) }
                .sheet(item: $pinEditor) { PinEditor(store: store,location: location,place: $0,offline: offline) }
        }
    }
}

private struct CoverageDetail: View {
    @ObservedObject var store: AppStore
    var community: Community
    var editPin: (Place) -> Void
    var editPath: (PathSegment) -> Void
    private var places: [Place] { store.places.filter { $0.communityID == community.id } }
    var body: some View {
        List {
            Section("Evidence") {
                Text(community.address)
                LabeledContent("Unit positions",value: "\(places.filter { $0.kind == .unitPosition }.count)")
                LabeledContent("Verified doors",value: "\(places.filter { $0.kind == .door && $0.verification == .fieldVerified }.count)")
                ForEach(community.gapNotes,id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(store.pack?.catalog.sources.filter { community.sourceIDs.contains($0.id) } ?? []) { source in
                    if let url = URL(string: source.url) { Link(source.title,destination: url).font(.caption) }
                }
            }
            Section("Paths") {
                ForEach(store.paths.filter { $0.communityID == community.id }) { path in
                    Button { editPath(path) } label: {
                        VStack(alignment: .leading) {
                            Text("\(path.mode.rawValue.capitalized) · \(Int(Geometry.length(path.coordinates))) m")
                            Text(path.blocked ? "Blocked" : path.confirmed ? "Personally confirmed" : "Unconfirmed · excluded from routing").font(.caption).foregroundStyle(.secondary)
                            if !path.notes.isEmpty { Text(path.notes).font(.caption) }
                        }
                    }
                }
            }
            Section("Personal pins") {
                ForEach(store.personal.places.filter { $0.communityID == community.id }) { place in
                    Button { editPin(place) } label: { PlaceRow(place: place) }.buttonStyle(.plain)
                }
            }
        }.navigationTitle(community.name)
    }
}
