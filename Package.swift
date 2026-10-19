// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ApartmentCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ApartmentCore", targets: ["ApartmentCore"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "ApartmentCore", dependencies: ["ZIPFoundation"]),
        .testTarget(name: "ApartmentCoreTests", dependencies: ["ApartmentCore"], exclude: ["Fixtures"])
    ]
)
