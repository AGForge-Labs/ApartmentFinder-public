import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PublicCatalogUpdateClient: Sendable {
    public typealias Fetch = @Sendable (URL, Int) async throws -> Data
    public static let latestURL = URL(string: "https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/latest.json")!
    private let fetch: Fetch
    public init(fetch: @escaping Fetch = PublicCatalogUpdateTransport.fetch) { self.fetch = fetch }

    public func latestManifest() async throws -> Data {
        try Task.checkCancellation()
        let data = try await fetch(Self.latestURL, PublicCatalogUpdateManifest.maximumBytes)
        _ = try PublicCatalogUpdateManifest.read(data)
        try Task.checkCancellation()
        return data
    }
    public func payload(manifestData: Data) async throws -> PublicCatalogUpdatePayload {
        let manifest = try PublicCatalogUpdateManifest.read(manifestData)
        var files: [String: Data] = [:]
        for name in PublicCatalogUpdateManifest.fileNames {
            try Task.checkCancellation()
            let url = Self.latestURL.deletingLastPathComponent().appendingPathComponent("revisions").appendingPathComponent(manifest.revision).appendingPathComponent(name)
            let maximum = manifest.files[name]!.bytes
            let data = try await fetch(url, maximum)
            guard data.count == maximum else { throw CoreError("The downloaded public catalog file has an unexpected length.") }
            files[name] = data
        }
        try Task.checkCancellation()
        return try PublicCatalogUpdatePayload(manifestData: manifestData, files: files)
    }
}

public enum PublicCatalogUpdateTransport {
    /// Bounded unauthenticated GET. Redirects, credentials and arbitrary URLs are rejected.
    public static func fetch(_ url: URL, maximum: Int) async throws -> Data {
        try await fetch(url, maximum: maximum, configuration: .ephemeral)
    }
    static func fetch(_ url: URL, maximum: Int, configuration: URLSessionConfiguration) async throws -> Data {
        try validateURL(url)
        guard (1...64_000_000).contains(maximum) else { throw CoreError("Unsupported public download budget.") }
        let request = BoundedRequest(url: url, maximum: maximum, configuration: configuration)
        return try await request.run()
    }
    static func validateURL(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.host == "raw.githubusercontent.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw CoreError("The public catalog URL is outside the fixed feed.")
        }
        if url == PublicCatalogUpdateClient.latestURL { return }
        let prefix = "/AGForge-Labs/ApartmentFinder-public/catalog-data/revisions/"
        guard parts.percentEncodedPath.hasPrefix(prefix) else { throw CoreError("Unsupported public catalog path.") }
        let suffix = String(parts.percentEncodedPath.dropFirst(prefix.count)).split(separator: "/", omittingEmptySubsequences: false)
        guard suffix.count == 2, PublicCatalogUpdateManifest.isRevision(String(suffix[0])),
              PublicCatalogUpdateManifest.fileNames.contains(String(suffix[1])) else { throw CoreError("Unsafe public catalog revision path.") }
    }
    static func validateResponse(statusCode: Int, finalURL: URL?, expectedURL: URL, declaredLength: Int64, maximum: Int) throws {
        guard statusCode == 200, finalURL == expectedURL else { throw CoreError("The public catalog server returned an unsupported response or redirect.") }
        guard declaredLength < 0 || declaredLength <= Int64(maximum) else { throw CoreError("The public catalog response exceeds its download budget.") }
    }

    private final class BoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let url: URL
        private let maximum: Int
        private let configuration: URLSessionConfiguration
        private let lock = NSLock()
        private var data = Data()
        private var continuation: CheckedContinuation<Data, Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var finished = false
        private var cancelled = false
        init(url: URL, maximum: Int, configuration: URLSessionConfiguration) { self.url = url; self.maximum = maximum; self.configuration = configuration }
        func run() async throws -> Data {
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { self.start($0) }
            }, onCancel: { self.cancel() })
        }
        private func start(_ continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 120
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.httpMethod = "GET"; request.setValue("application/json, application/geo+json", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let task = session.dataTask(with: request)
            self.session = session; self.task = task
            lock.unlock()
            task.resume()
        }
        private func cancel() {
            lock.lock(); cancelled = true; let started = continuation != nil; lock.unlock()
            if started { finish(.failure(CancellationError())) }
        }
        private func finish(_ result: Result<Data, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation, session = self.session, task = self.task
            self.continuation = nil; self.session = nil; self.task = nil
            lock.unlock()
            task?.cancel(); session?.invalidateAndCancel()
            continuation?.resume(with: result)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
            finish(.failure(CoreError("Public catalog redirects are prohibited.")))
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Permit normal TLS trust evaluation, never an HTTP authentication credential lookup.
            #if canImport(Security)
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            #endif
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(CoreError("The public feed requested authentication.")))
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            do {
                guard let http = response as? HTTPURLResponse else { throw CoreError("Non-HTTP public catalog response.") }
                try PublicCatalogUpdateTransport.validateResponse(statusCode: http.statusCode, finalURL: http.url,
                                                                 expectedURL: url, declaredLength: http.expectedContentLength, maximum: maximum)
                completionHandler(.allow)
            } catch { completionHandler(.cancel); finish(.failure(error)) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            guard bytes.count <= maximum - data.count else {
                lock.unlock(); finish(.failure(CoreError("The public catalog exceeded its actual byte budget."))); return
            }
            data.append(bytes); lock.unlock()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)); return }
            lock.lock(); let result = data; lock.unlock()
            finish(.success(result))
        }
    }
}
