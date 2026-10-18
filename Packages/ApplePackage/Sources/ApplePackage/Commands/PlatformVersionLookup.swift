// Based on ApplePackage 1.2.7; consumer catalog fallback follows majd/ipatool.

import AsyncHTTPClient
import Foundation

public struct PlatformVersionMetadata: Equatable, Hashable {
    public var appID: Int64
    public var bundleID: String?
    public var name: String?
    public var displayVersion: String?
    public var externalVersionID: String
    public var buyParams: String?
}

public enum PlatformVersionLookup {
    public static func lookup(
        appID: Int64, countryCode: String, entityType: EntityType
    ) async throws -> PlatformVersionMetadata {
        let client = Configuration.makeHTTPClient(redirectConfiguration: .follow(max: 8, allowCycles: false))
        defer { _ = client.shutdown() }
        let catalogs = entityType == .appleTV ? ["atv9"] : ["enterprisestore", "iphone", "ipad"]
        for catalog in catalogs {
            let result = try await fetchCatalog(client: client, appID: appID, countryCode: countryCode, catalog: catalog)
            if let metadata = try parseCatalog(result, appID: appID) { return metadata }
        }
        try ensureFailed(Strings.noItemsInResponse)
    }

    /// A public catalog 404 is the only condition that permits an unpinned
    /// redownload of an owned, delisted app. Network/malformed responses abort.
    static func latestIOSVersion(app: Software, store: String, entityType: EntityType = .iPhone) async throws -> String? {
        guard let country = Configuration.countryCode(for: store) else {
            try ensureFailed(Strings.unsupportedStoreIdentifier(store))
        }
        let client = Configuration.makeHTTPClient(redirectConfiguration: .follow(max: 8, allowCycles: false))
        defer { _ = client.shutdown() }
        for catalog in ["enterprisestore", "iphone", "ipad"] {
            let result = try await fetchCatalog(client: client, appID: app.id, countryCode: country, catalog: catalog)
            if let metadata = try parseCatalog(result, appID: app.id) {
                if let bundleID = metadata.bundleID, !app.bundleID.isEmpty, bundleID != app.bundleID {
                    try ensureFailed("Version catalog returned a different bundle identifier")
                }
                return metadata.externalVersionID
            }
        }
        let family = entityType == .iPad ? "ipad" : "iphone"
        let url = "https://apps.apple.com/api/apps/v1/catalog/\(country.lowercased())/apps/\(app.id)?platform=\(family)"
        let request = try HTTPClient.Request(url: url, method: .GET)
        let response = try await client.execute(request: request).get()
        if response.status == .notFound { return nil }
        try ensure(response.status == .ok, Strings.requestFailed(status: response.status.code))
        guard let body = response.body,
              let root = try JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any]
        else { try ensureFailed(Strings.invalidResponse) }
        return try parseIOSCatalog(root, app: app, entityType: entityType)
    }

    private static func fetchCatalog(
        client: HTTPClient, appID: Int64, countryCode: String, catalog: String
    ) async throws -> [String: Any] {
        var components = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        components.queryItems = [
            .init(name: "version", value: "2"), .init(name: "id", value: String(appID)),
            .init(name: "p", value: "mdm-lockup"), .init(name: "caller", value: "MDM"),
            .init(name: "platform", value: catalog), .init(name: "cc", value: countryCode.lowercased()),
            .init(name: "l", value: "en"),
        ]
        let request = try HTTPClient.Request(
            url: components.url!.absoluteString, method: .GET,
            headers: .init([("User-Agent", Configuration.userAgent)])
        )
        let response = try await client.execute(request: request).get()
        try ensure(response.status == .ok, Strings.requestFailed(status: response.status.code))
        guard let body = response.body,
              let root = try JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any]
        else { try ensureFailed(Strings.invalidResponse) }
        return root
    }

    /// Missing apps/offers allow trying the next catalog; a malformed offer is
    /// an error and must not silently choose another version.
    static func parseCatalog(_ root: [String: Any], appID: Int64) throws -> PlatformVersionMetadata? {
        guard let results = root["results"] as? [String: Any] else { try ensureFailed(Strings.invalidResponse) }
        guard let value = results[String(appID)] else { return nil }
        guard let item = value as? [String: Any] else { try ensureFailed(Strings.invalidResponse) }
        guard let rawOffers = item["offers"] else { return nil }
        guard let offers = rawOffers as? [[String: Any]] else { try ensureFailed(Strings.invalidResponse) }
        guard !offers.isEmpty else { return nil }
        let offer = offers[0]
        let version = offer["version"] as? [String: Any]
        let buyParams = offer["buyParams"] as? String
        let params = buyParams.flatMap { URLComponents(string: "applepackage://buy?\($0)") }
        let identifier = StoreDownloadEndpoint.stringValue(version?["externalId"]) ??
            params?.queryItems?.first { $0.name == "appExtVrsId" }?.value
        guard let identifier, let number = UInt64(identifier), number > 0 else {
            try ensureFailed(Strings.missingVersionIdentifiers)
        }
        return PlatformVersionMetadata(
            appID: appID, bundleID: item["bundleId"] as? String, name: item["name"] as? String,
            displayVersion: version?["display"] as? String, externalVersionID: identifier, buyParams: buyParams
        )
    }

    static func parseIOSCatalog(_ root: [String: Any], app: Software, entityType: EntityType = .iPhone) throws -> String {
        guard let items = root["data"] as? [[String: Any]], items.count == 1,
              let item = items.first, item["id"] as? String == String(app.id), item["type"] as? String == "apps",
              let attributes = item["attributes"] as? [String: Any],
              let families = attributes["deviceFamilies"] as? [String], families.contains(entityType == .iPad ? "ipad" : "iphone"),
              let platforms = attributes["platformAttributes"] as? [String: Any],
              let ios = platforms["ios"] as? [String: Any],
              let bundleID = ios["bundleId"] as? String,
              app.bundleID.isEmpty || bundleID == app.bundleID,
              let version = StoreDownloadEndpoint.stringValue(ios["externalVersionId"]),
              let number = UInt64(version), number > 0
        else { try ensureFailed("iOS catalog returned invalid app or version metadata") }
        return version
    }
}
