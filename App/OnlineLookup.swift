import SwiftUI
import Security
import ApartmentCore

struct RoadTarget: Identifiable {
    let id = UUID()
    var coordinate: Coordinate
    var title: String
    var placeID: String?
    var arrivalNote: String
}

enum ProxyCredential {
    private static var query: [String: Any] {
        [kSecClass as String:kSecClassGenericPassword,
         kSecAttrService as String:"ApartmentFinder.geocoding",
         kSecAttrAccount as String:"private-proxy"]
    }
    static func read() -> String? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data,encoding: .utf8)
    }
    static func save(_ token: String) throws {
        guard token.count >= 32 else { throw CoreError("Use the private proxy token (at least 32 characters), not a Google key.") }
        let updates: [String: Any] = [kSecValueData as String:Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary,updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw CoreError("The proxy token could not be saved.") }
        } else if status != errSecSuccess { throw CoreError("The proxy token could not be updated.") }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private struct LookupResponse: Decodable { var results: [LookupResult] }
private struct LookupResult: Decodable, Identifiable {
    var name: String
    var placeID: String
    var latitude: Double
    var longitude: Double
    var partialMatch: Bool
    var id: String { placeID }
    var target: RoadTarget {
        RoadTarget(coordinate: .init(latitude: latitude,longitude: longitude),title: name,placeID: placeID,
                   arrivalNote: "This is a public address result. Check the local map and confirm the vehicle entrance before entering.")
    }
}

struct OnlineLookup: View {
    @ObservedObject var store: AppStore
    @State var address: String
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var results: [LookupResult] = []
    @State private var message = ""
    @State private var loading = false
    @State private var target: RoadTarget?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Optional public-address lookup").font(.headline)
                    Text("This sends the street address to your configured proxy and Google. Results are temporary and are never added to your saved apartment maps.").font(.caption)
                    TextField("Street address",text: $address)
                    if !ServiceConfiguration.ready || ServiceConfiguration.value("GeocodingProxyURL").isEmpty {
                        Text("Online lookup is off. Configure the free proxy, provider quotas and navigation key first.").foregroundStyle(.orange)
                    }
                    if ProxyCredential.read() == nil {
                        SecureField("Private proxy access token",text: $token)
                        Button("Save token on this iPhone") {
                            do { try ProxyCredential.save(token); token = ""; message = "Proxy token saved." }
                            catch { message = error.localizedDescription }
                        }
                    }
                    Button("Look up with Google Maps") { Task { await lookup() } }
                        .disabled(loading || !ServiceConfiguration.ready || ServiceConfiguration.value("GeocodingProxyURL").isEmpty)
                    if loading { ProgressView() }
                    if !message.isEmpty { Text(message).font(.caption) }
                }
                if !results.isEmpty {
                    Section {
                        Text("Google Maps").font(.system(size: 18,weight: .medium))
                        ForEach(results) { result in
                            Button { target = result.target } label: {
                                VStack(alignment: .leading) {
                                    Text(result.name)
                                    Text(result.partialMatch ? "Partial address match · review carefully" : "Address result · entrance unverified").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }.navigationTitle("Online address")
                .toolbar { Button("Close") { dismiss() } }
                .fullScreenCover(item: $target) { PublicRoadView(target: $0,store: store) }
        }
    }
    @MainActor private func lookup() async {
        results = []; loading = true; defer { loading = false }
        do {
            guard ServiceConfiguration.ready, let url = URL(string: ServiceConfiguration.value("GeocodingProxyURL")),
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  let token = ProxyCredential.read() else { throw CoreError("Configure the HTTPS proxy and save its access token first.") }
            try store.consumeOnline("geocoding",daily: 100,monthly: 3100)
            var request = URLRequest(url: url,cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,timeoutInterval: 12)
            request.httpMethod = "POST"; request.setValue("Bearer \(token)",forHTTPHeaderField: "Authorization")
            request.setValue("application/json",forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["address":address])
            let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil
            let session = URLSession(configuration: config,delegate: NoRedirect(),delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data,response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_000_000 else {
                throw CoreError((response as? HTTPURLResponse)?.statusCode == 429 ? "Online allowance reached. Saved maps still work." : "Online lookup failed. Saved maps still work.")
            }
            results = try JSONDecoder().decode(LookupResponse.self,from: data).results.filter { $0.target.coordinate.isValid }
            message = results.isEmpty ? "No address result in 89113 or 89148." : "Choose an address to preview Google road guidance."
        } catch { message = error.localizedDescription }
    }
}
