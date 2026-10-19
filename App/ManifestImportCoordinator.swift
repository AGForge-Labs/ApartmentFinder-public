import SwiftUI
import ApartmentCore

struct ManifestImportRequest: Identifiable {
    let id = UUID()
    let documents: [ManifestDocument]
    var shared: SharedManifest?
}
@MainActor
final class ManifestImportCoordinator: ObservableObject {
    @Published var request: ManifestImportRequest?
    @Published var pendingCount = 0
    @Published var unreadable: [ManifestInboxIssue] = []
    @Published var error: String?
    @Published var loading = false
    #if DEBUG
    enum UITestAction: String { case mixed, manifestImport, share, productionImport }
    @Published private(set) var uiTestMixedAttempts = 0
    @Published private(set) var uiTestImportAttempts = 0
    @Published private(set) var uiTestShareAttempts = 0
    @Published private(set) var uiTestProductionAttempts = 0
    @Published private(set) var uiTestLastAction: UITestAction?
    let uiTestDiagnosticInstance = SyntheticUIDiagnostics.nextCoordinatorInstance()
    var uiTestActionStatus: String {
        "mixedAttempts=\(uiTestMixedAttempts);importAttempts=\(uiTestImportAttempts);shareAttempts=\(uiTestShareAttempts);productionAttempts=\(uiTestProductionAttempts);lastAction=\(uiTestLastAction?.rawValue ?? "none")"
    }
    func recordUITestAction(_ action: UITestAction) {
        uiTestLastAction = action
        switch action {
        case .mixed: uiTestMixedAttempts += 1
        case .manifestImport: uiTestImportAttempts += 1
        case .share: uiTestShareAttempts += 1
        case .productionImport: uiTestProductionAttempts += 1
        }
        SyntheticUIDiagnostics.actionEntered(action, imports: self)
    }
    #endif
    private var reading = false
    private var deferredIDs = Set<String>()
    private let inboxProvider: () throws -> ManifestInbox

    init(inboxProvider: @escaping () throws -> ManifestInbox = { try SharedManifestContainer.inbox() }) {
        self.inboxProvider = inboxProvider
    }

    func open(_ url: URL, addresses: [String]) {
        guard !loading, request == nil else { error = "Finish the current import before opening another file."; return }
        loading = true
        #if DEBUG
        SyntheticUIDiagnostics.openStarted(self)
        #endif
        Task {
            defer {
                loading = false
                #if DEBUG
                SyntheticUIDiagnostics.loadingEnded(self)
                #endif
            }
            do {
                let data = try SharedManifestContainer.data(url)
                let name = url.lastPathComponent
                let documents = try await Task.detached(priority: .userInitiated) {
                    try ManifestReader.read(data, filename: name, knownAddresses: addresses)
                }.value
                request = ManifestImportRequest(documents: documents)
                #if DEBUG
                SyntheticUIDiagnostics.requestPublished(self)
                #endif
            } catch {
                self.error = error.localizedDescription
                #if DEBUG
                SyntheticUIDiagnostics.readFailed(self)
                #endif
            }
        }
    }
    func refresh(store: AppStore, includeDeferred: Bool = false) {
        guard !reading, !loading, request == nil else { return }
        reading = true; defer { reading = false }
        do {
            let inbox = try inboxProvider()
            if let cutoff = store.personal.activeManifest?.sharedThrough { try inbox.remove(through: cutoff) }
            var pending = try inbox.pending()
            for item in pending where try store.hasImportedManifest(item.id) { try inbox.remove(item.id) }
            let review = try inbox.review()
            pending = review.manifests
            unreadable = review.issues
            pendingCount = pending.count
            if let first = pending.first(where: { includeDeferred || !deferredIDs.contains($0.id) }) {
                request = ManifestImportRequest(documents: [first.document], shared: first)
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancel() {
        if let shared = request?.shared { deferredIDs.insert(shared.id) }
        request = nil
    }
    func commit(_ document: ManifestDocument, store: AppStore) throws {
        guard document.result.canImport else { throw CoreError("This manifest cannot be imported.") }
        if let shared = request?.shared {
            guard try store.importSharedManifest(shared) else {
                throw CoreError("This shared manifest was already imported. Choose the new manifest file.")
            }
        } else {
            try store.importManifest(document)
        }
        request = nil
        deferredIDs.removeAll()
        // Persistence above is the import. Queue cleanup is retryable, and the
        // saved cutoff prevents old manifests being offered after an app restart.
        do {
            let inbox = try inboxProvider()
            if let cutoff = store.personal.activeManifest?.sharedThrough { try inbox.remove(through: cutoff) }
            pendingCount = try inbox.pending().count
        } catch {
            pendingCount = 0
            self.error = "Your new manifest is loaded. Older shared files could not be cleared yet: \(error.localizedDescription)"
        }
    }
    func discardUnreadable(_ issue: ManifestInboxIssue) {
        do {
            try inboxProvider().discardUnreadable(issue)
            unreadable.removeAll { $0.id == issue.id }
        } catch { self.error = error.localizedDescription }
    }
    func discardPending() {
        guard let shared = request?.shared else { return }
        do {
            try inboxProvider().remove(shared.id)
            pendingCount = max(0, pendingCount - 1); request = nil
        } catch { self.error = error.localizedDescription }
    }
}
