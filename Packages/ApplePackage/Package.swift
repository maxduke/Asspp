// swift-tools-version: 5.9

import PackageDescription

var nativeDependencies: [Target.Dependency] = []
var extraDependencies: [Package.Dependency] = []
var nativeTargets: [Target] = []
#if os(Linux)
extraDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0"))
nativeDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#else
nativeDependencies.append("AppleSAP")
nativeTargets.append(.target(
    name: "AppleSAP",
    dependencies: ["AppleSAPCore"],
    publicHeadersPath: "include",
    cSettings: [.unsafeFlags(["-fobjc-arc"])],
    linkerSettings: [.linkedFramework("Foundation")]
))
#endif

let package = Package(
    name: "ApplePackage",
    platforms: [.iOS(.v15), .macCatalyst(.v14), .macOS(.v11)],
    products: [.library(name: "ApplePackage", targets: ["ApplePackage"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.2.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ] + extraDependencies,
    targets: nativeTargets + [
        .target(name: "AppleSAPCore", publicHeadersPath: "include"),
        .target(name: "ApplePackage", dependencies: [
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "Collections", package: "swift-collections"),
            .product(name: "Logging", package: "swift-log"),
        ] + nativeDependencies),
        .testTarget(name: "ApplePackageTests", dependencies: ["ApplePackage", "AppleSAPCore"]),
    ]
)
