import UIKit
import SwiftUI
import UniformTypeIdentifiers
import ApartmentCore

@MainActor
final class ShareViewController: UIViewController {
    private var hosting: UIViewController?
    override func viewDidLoad() {
        super.viewDidLoad()
        show(AnyView(ProgressView("Reading manifest…").padding()))
        Task {
            do {
                let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                guard providers.count == 1, let provider = providers.first else { throw CoreError("Share one ZIP export or CSV manifest at a time.") }
                let (data, name) = try await attachment(provider)
                let addresses = try knownAddresses()
                let documents = try await Task.detached(priority: .userInitiated) {
                    try ManifestReader.read(data, filename: name, knownAddresses: addresses)
                }.value
                show(AnyView(ManifestImportView(documents: documents, sharing: true, save: { document in
                    _ = try SharedManifestContainer.inbox().enqueue(document)
                }, cancel: { [weak self] in self?.finish() }).tint(.teal)))
            } catch {
                show(AnyView(VStack(spacing: 20) {
                    Text("Could not read manifest").font(.headline)
                    Text(error.localizedDescription)
                    Button("Close") { self.finish() }
                }.padding()))
            }
        }
    }
    private func knownAddresses() throws -> [String] {
        let installed = (try? SharedManifestContainer.privatePacks()).flatMap { try? $0.knownAddresses() }
        let bundled = Bundle.main.url(forResource: "known-addresses", withExtension: "json").flatMap {
            try? KnownAddressIndex.read(DataPackPayload.readCatalogFile($0)).addresses
        }
        if let bundled {
            return KnownAddressIndex.supplementalAddresses(installed: installed ?? [], bundled: bundled)
        }
        if let installed { return installed }
        throw CoreError("The installed app is missing a valid address index.")
    }
    private func attachment(_ provider: NSItemProvider) async throws -> (Data, String) {
        let types = [UTType.zip, .commaSeparatedText, .plainText, .data]
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            throw CoreError("Choose an OnTrac ZIP export or a CSV file.")
        }
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CoreError("The exporting app did not provide a file.") }
                    // The provider deletes its temporary file after this callback.
                    let data = try SharedManifestContainer.data(url)
                    var name = suggested ?? url.lastPathComponent
                    if !["zip","csv","txt"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
                        name += data.starts(with: [0x50,0x4b]) ? ".zip" : ".csv"
                    }
                    continuation.resume(returning: (data, name))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func finish() { extensionContext?.completeRequest(returningItems: nil) }
    private func show(_ content: AnyView) {
        hosting?.willMove(toParent: nil); hosting?.view.removeFromSuperview(); hosting?.removeFromParent()
        let controller = UIHostingController(rootView: content)
        addChild(controller); view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self); hosting = controller
    }
}
