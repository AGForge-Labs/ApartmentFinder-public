import Foundation
import XCTest
import ApartmentCore
@testable import ApartmentFinder

// Native source only: these methods require an Apple-built host and have not run on Windows.
@MainActor
final class PublicCatalogSetResourceParityTests: XCTestCase {
    func testAppHostContainsCompleteReviewedBootstrapBundleAndBaselineResources() throws {
        let resources = try SharedManifestContainer.publicCatalogResourceURLs(in: .main)
        let context = try PublicCatalogBootstrapResources.readReviewed(resources: resources)
        XCTAssertEqual(context.anchor.minimumRootSequence, 92)
        XCTAssertEqual(context.anchor.packVersion, "2026.10.25.13-public-valley-ventana-provider-unit-areas")
        let snapshot = PublicCatalogVerifiedPublicSnapshot.bundle(context: context)
        XCTAssertFalse(snapshot.pack.catalog.communities.isEmpty)
        XCTAssertFalse(snapshot.pack.places.isEmpty)
        XCTAssertEqual(snapshot.index.addresses, KnownAddressIndex(catalog: snapshot.pack.catalog).addresses)
    }
    func testSharedResourceProviderProducesSameVerifiedPublicPackAndAddressIdentity() throws {
        let mainBundle = Bundle.main
        let shareBundle = try embeddedShareBundle(in: mainBundle)
        let mainResources = try SharedManifestContainer.publicCatalogResourceURLs(in: mainBundle)
        let shareResources = try SharedManifestContainer.publicCatalogResourceURLs(in: shareBundle)
        let main = try PublicCatalogBootstrapResources.readReviewed(resources: mainResources)
        let shared = try PublicCatalogBootstrapResources.readReviewed(resources: shareResources)
        XCTAssertNotEqual(mainBundle.bundleURL.standardizedFileURL, shareBundle.bundleURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: mainResources.anchor), try Data(contentsOf: shareResources.anchor))
        XCTAssertEqual(try Data(contentsOf: mainResources.registry), try Data(contentsOf: shareResources.registry))
        for name in PublicCatalogUpdateManifest.fileNames {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(mainResources.bundleFiles[name])), try Data(contentsOf: XCTUnwrap(shareResources.bundleFiles[name])), name)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(mainResources.baselineFiles[name])), try Data(contentsOf: XCTUnwrap(shareResources.baselineFiles[name])), name)
        }
        let mainSnapshot = PublicCatalogVerifiedPublicSnapshot.bundle(context: main)
        let shareSnapshot = PublicCatalogVerifiedPublicSnapshot.bundle(context: shared)
        XCTAssertEqual(mainSnapshot.identity, shareSnapshot.identity)
        XCTAssertEqual(mainSnapshot.pack.catalog.communities.map(\.id), shareSnapshot.pack.catalog.communities.map(\.id))
        XCTAssertEqual(mainSnapshot.pack.places, shareSnapshot.pack.places)
        XCTAssertEqual(mainSnapshot.index.addresses, shareSnapshot.index.addresses)
        // This loads resources from the actual embedded extension; native execution remains unrun on Windows.
    }
    private func embeddedShareBundle(in mainBundle: Bundle) throws -> Bundle {
        let plugins = try XCTUnwrap(mainBundle.builtInPlugInsURL, "The native host must contain its embedded Share extension")
        let namedURL = plugins.appendingPathComponent("ApartmentFinderShare.appex", isDirectory: true)
        if FileManager.default.fileExists(atPath: namedURL.path), let named = Bundle(url: namedURL) {
            XCTAssertEqual(named.bundleIdentifier, "dev.galaxybigbird.ApartmentFinder.Share")
            return named
        }
        let extensionURLs = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension == "appex" }
        let share = extensionURLs.compactMap { Bundle(url: $0) }.first { $0.bundleIdentifier == "dev.galaxybigbird.ApartmentFinder.Share" }
        return try XCTUnwrap(share, "Required embedded ApartmentFinder Share extension is missing; resource parity cannot be established")
    }
    func testSharedProviderRejectsIncompletePublicResourceBundle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fictional-incomplete-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = ["CFBundleIdentifier": "org.example.fictional-incomplete", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("public-set-bootstrap-anchor.json"))
        let bundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertThrowsError(try SharedManifestContainer.publicCatalogResourceURLs(in: bundle))
    }
}
