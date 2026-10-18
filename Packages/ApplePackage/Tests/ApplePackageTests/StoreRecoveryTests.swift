import Foundation
@testable import ApplePackage
import XCTest

final class StoreRecoveryTests: XCTestCase {
    let redownload = URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload")!
    let update = URL(string: "https://downloaddispatch.itunes.apple.com/up/updateProduct")!
    let app = Software(
        id: 123, bundleID: "example.app", name: "Example", version: "1.0", artistName: "Example",
        sellerName: "Example", description: "", averageUserRating: 0, userRatingCount: 0,
        artworkUrl: "", screenshotUrls: [], minimumOsVersion: "17", releaseDate: "", primaryGenreName: ""
    )

    func product(version: Any = "456", bundleID: String = "example.app", id: Int = 123) -> [String: Any] {
        ["songList": [["URL": "https://example.com/app.ipa", "metadata": [
            "itemId": id, "softwareVersionBundleId": bundleID, "softwareVersionExternalIdentifier": version,
        ]]]]
    }

    func recover(
        _ responses: [[String: Any]], version: String = "", latest: String? = "456",
        requests: inout [(StoreDownloadEndpoint, String)]
    ) async throws -> [String: Any] {
        var recorded: [(StoreDownloadEndpoint, String)] = []
        defer { requests = recorded }
        return try await StoreDownloadEndpoint.recoverProduct(
            app: app, externalVersionID: version,
            send: { endpoint, version in
                recorded.append((endpoint, version))
                return responses[recorded.count - 1]
            },
            endpoints: { (self.redownload, self.update) }, latestVersion: { latest }
        )
    }

    func testEmptyVolumeStorePinsIOSVersionBeforeRedownload() async throws {
        var requests: [(StoreDownloadEndpoint, String)] = []
        _ = try await recover([[:], product()], requests: &requests)
        XCTAssertEqual(requests.map(\.0), [.volumeStore, .redownload(redownload)])
        XCTAssertEqual(requests.map(\.1), ["", "456"])
    }

    func testNoLongerAvailableFallsBackWithSameExplicitVersion() async throws {
        var requests: [(StoreDownloadEndpoint, String)] = []
        _ = try await recover(
            [["customerMessage": "This item is No Longer Available"], product(version: 789)],
            version: "789", requests: &requests
        )
        XCTAssertEqual(requests.map(\.1), ["789", "789"])
    }

    func testExisting5002RecoveryStillWorks() async throws {
        var requests: [(StoreDownloadEndpoint, String)] = []
        _ = try await recover([["failureType": "5002"], product()], requests: &requests)
        XCTAssertEqual(requests.count, 2)
    }

    func testUnavailableRedownloadUsesUpdateWithoutChangingVersion() async throws {
        var requests: [(StoreDownloadEndpoint, String)] = []
        _ = try await recover([[:], ["customerMessage": "No Longer Available"], product()], requests: &requests)
        XCTAssertEqual(requests.map(\.0), [.volumeStore, .redownload(redownload), .update(update)])
        XCTAssertEqual(requests.map(\.1), ["", "456", "456"])
    }

    func testEmptyHTTP500FromRedownloadUsesUpdate() async throws {
        var requests: [(StoreDownloadEndpoint, String)] = []
        _ = try await StoreDownloadEndpoint.recoverProduct(
            app: app, externalVersionID: "456",
            send: { endpoint, version in
                requests.append((endpoint, version))
                switch endpoint {
                case .volumeStore: return [:]
                case .redownload: throw StoreDownloadEndpoint.FetchError.emptyRedownloadResponse
                case .update: return self.product()
                }
            }, endpoints: { (self.redownload, self.update) },
            latestVersion: { XCTFail("Explicit version must not be replaced"); return nil }
        )
        XCTAssertEqual(requests.count, 3)
    }

    func testLicenseTokenAndUnrelatedFailuresDoNotRetry() async throws {
        for response: [String: Any] in [
            ["failureType": "9610"], ["failureType": "2042"], ["failureType": "2034"],
            ["customerMessage": "Account disabled"],
        ] {
            var requests: [(StoreDownloadEndpoint, String)] = []
            _ = try await recover([response], requests: &requests)
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testSuccessfulPrimaryResponseDoesNotFetchBagOrCatalog() async throws {
        _ = try await StoreDownloadEndpoint.recoverProduct(
            app: app, externalVersionID: "", send: { _, _ in self.product() },
            endpoints: { XCTFail("Unnecessary bag request"); return (nil, nil) },
            latestVersion: { XCTFail("Unnecessary catalog request"); return nil }
        )
    }

    func testDelistedAppCanRedownloadWithoutVersion() async throws {
        var requests: [(StoreDownloadEndpoint, String)] = []
        _ = try await recover([[:], product()], latest: nil, requests: &requests)
        XCTAssertEqual(requests.map(\.1), ["", ""])
    }

    func testUnpinnedDelistedAppDoesNotUseUpdate() async throws {
        var requests: [(StoreDownloadEndpoint, String)] = []
        do {
            _ = try await recover([[:], ["customerMessage": "No Longer Available"]], latest: nil, requests: &requests)
            XCTFail("Unavailable response must fail")
        } catch { XCTAssertEqual(requests.count, 2) }
    }

    func testRecoveryRejectsWrongApplicationBundleOrVersion() throws {
        for response in [product(id: 999), product(bundleID: "other.app"), product(version: "999"), [:]] {
            XCTAssertThrowsError(try StoreDownloadEndpoint.validateProduct(response, app: app, version: "456"))
        }
        XCTAssertNoThrow(try StoreDownloadEndpoint.validateProduct(product(version: 456), app: app, version: "456"))
    }

    func testDispatchURLsAndRedirectsCannotLeakCredentials() throws {
        for url in [
            "http://downloaddispatch.itunes.apple.com/r/redownload",
            "https://downloaddispatch.itunes.apple.com.evil.test/r/redownload",
            "https://user@downloaddispatch.itunes.apple.com/r/redownload",
            "https://downloaddispatch.itunes.apple.com/r/redownload?redirect=1",
            "https://downloaddispatch.itunes.apple.com/up/updateProduct",
            "https://downloaddispatch.itunes.apple.com/%72/redownload",
        ] {
            XCTAssertThrowsError(try StoreDownloadEndpoint.dispatch(URL(string: url)!))
        }
        for url in ["https://evil.test/", "http://buy.itunes.apple.com/", "https://buy.itunes.apple.com:444/"] {
            XCTAssertFalse(StoreDownloadEndpoint.isTrustedRedirect(URL(string: url)!))
        }
        XCTAssertTrue(StoreDownloadEndpoint.isTrustedRedirect(URL(string: "https://p25-buy.itunes.apple.com/path")!))
    }

    func testVersionCatalogAllowsEmptyCatalogButRejectsMalformedOffers() throws {
        XCTAssertNil(try PlatformVersionLookup.parseCatalog(["results": [:]], appID: 123))
        XCTAssertThrowsError(try PlatformVersionLookup.parseCatalog(["results": ["123": ["offers": [["version": ["externalId": "invalid"]]]]]], appID: 123))
        for identifier: Any in [456, "456"] {
            let root: [String: Any] = ["results": ["123": ["offers": [["version": ["externalId": identifier]]]]]]
            XCTAssertEqual(try PlatformVersionLookup.parseCatalog(root, appID: 123)?.externalVersionID, "456")
        }
    }

    func testVersionCatalogReadsBuyParameters() throws {
        let root: [String: Any] = ["results": ["123": ["offers": [["buyParams": "salableAdamId=123&appExtVrsId=456"]]]]]
        XCTAssertEqual(try PlatformVersionLookup.parseCatalog(root, appID: 123)?.externalVersionID, "456")
    }

    func testPublicCatalogRequiresMatchingIOSApp() throws {
        func catalog(bundleID: String = "example.app", family: String = "iphone") -> [String: Any] {
            ["data": [["id": "123", "type": "apps", "attributes": [
                "deviceFamilies": [family], "platformAttributes": ["ios": ["bundleId": bundleID, "externalVersionId": 456]],
            ]]]]
        }
        XCTAssertEqual(try PlatformVersionLookup.parseIOSCatalog(catalog(), app: app), "456")
        XCTAssertThrowsError(try PlatformVersionLookup.parseIOSCatalog(catalog(bundleID: "other.app"), app: app))
        XCTAssertThrowsError(try PlatformVersionLookup.parseIOSCatalog(catalog(family: "appletv"), app: app))
        XCTAssertThrowsError(try PlatformVersionLookup.parseIOSCatalog(["data": []], app: app))
    }
}

extension StoreRecoveryTests {
    func testLegacyIOSPackagesAndPlatformMismatch() throws {
        XCTAssertNoThrow(try PackagePlatformValidator.validate([:], supports: .iPhone))
        XCTAssertNoThrow(try PackagePlatformValidator.validate(["CFBundleSupportedPlatforms": ["iPhoneOS"]], supports: .iPad))
        XCTAssertThrowsError(try PackagePlatformValidator.validate(["CFBundleSupportedPlatforms": []], supports: .iPhone))
        XCTAssertThrowsError(try PackagePlatformValidator.validate(["CFBundleSupportedPlatforms": ["AppleTVOS"]], supports: .iPhone))
        XCTAssertThrowsError(try PackagePlatformValidator.validate([:], supports: .appleTV))
    }
}

extension StoreRecoveryTests {
    func testRecoveredLicenseFailureRetainsItsMeaning() async throws {
        var requests: [(StoreDownloadEndpoint, String)] = []
        let result = try await recover([[:], ["failureType": "9610"]], requests: &requests)
        XCTAssertEqual(result["failureType"] as? String, "9610")
        XCTAssertEqual(requests.count, 2)
    }

    func testCatalogFailureDoesNotSendAnUnpinnedRequest() async throws {
        var sends = 0
        do {
            _ = try await StoreDownloadEndpoint.recoverProduct(
                app: app, externalVersionID: "", send: { _, _ in sends += 1; return [:] },
                endpoints: { (self.redownload, self.update) },
                latestVersion: { throw NSError(domain: "fixture.catalog", code: 500) }
            )
            XCTFail("Catalog failure must propagate")
        } catch { XCTAssertEqual(sends, 1) }
    }
}

extension StoreRecoveryTests {
    func testMalformedSongListIsNotAnAvailabilityFailure() {
        XCTAssertFalse(StoreDownloadEndpoint.shouldRedownload(["songList": "invalid"]))
        XCTAssertFalse(StoreDownloadEndpoint.isUnavailable(["songList": "invalid", "customerMessage": "No Longer Available"]))
    }
}

extension StoreRecoveryTests {
    func testMalformedCatalogItemsAndOffersCannotTriggerAnotherCatalog() {
        XCTAssertThrowsError(try PlatformVersionLookup.parseCatalog(["results": ["123": "invalid"]], appID: 123))
        XCTAssertThrowsError(try PlatformVersionLookup.parseCatalog(["results": ["123": ["offers": "invalid"]]], appID: 123))
    }
}
