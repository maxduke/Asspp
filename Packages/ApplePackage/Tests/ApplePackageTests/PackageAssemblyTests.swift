import Foundation
@testable import ApplePackage
import XCTest
import ZIPFoundation

final class PackageAssemblyTests: XCTestCase {
    func archive(entries: [String: [String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("store-fixture-\(UUID().uuidString).ipa")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, plist) in entries {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            })
        }
        return url
    }

    func testDRMFreePackageStillReceivesAccountMetadata() async throws {
        let url = try archive(entries: ["Payload/Example.app/Info.plist": [
            "CFBundleExecutable": "Example", "CFBundleSupportedPlatforms": ["iPhoneOS"],
        ]])
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["apple-id": "fixture@example.com"], format: .binary, options: 0
        )
        try await SignatureInjector.inject(sinfs: [], iTunesMetadata: metadata, into: url.path)
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive["iTunesMetadata.plist"])
        var output = Data()
        _ = try archive.extract(entry) { output.append($0) }
        XCTAssertEqual(output, metadata)
        XCTAssertNil(archive["Payload/Example.app/SC_Info/Example.sinf"])
    }

    func testNestedIOSAppCannotQualifyWrongTopLevelPlatform() throws {
        let url = try archive(entries: [
            "Payload/Example.app/Info.plist": ["CFBundleSupportedPlatforms": ["AppleTVOS"]],
            "Payload/Example.app/Watch/Nested.app/Info.plist": ["CFBundleSupportedPlatforms": ["iPhoneOS"]],
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try PackagePlatformValidator.ensurePackage(at: url, supports: .iPhone))
        XCTAssertNoThrow(try PackagePlatformValidator.ensurePackage(at: url, supports: .appleTV))
    }
}
