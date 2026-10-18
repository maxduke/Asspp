// Based on ApplePackage 1.2.7; endpoint recovery follows majd/ipatool.

import AsyncHTTPClient
import Foundation

extension StoreDownloadEndpoint {
    enum FetchError: Error {
        case emptyRedownloadResponse
    }

    static func fetchProductWithFallback(
        client: HTTPClient,
        account: inout Account,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String,
        entityType: EntityType = .iPhone
    ) async throws -> [String: Any] {
        // Keep the evolving cookies in one account across the whole retry chain.
        // A reference lets the testable state machine send sequential requests
        // without escaping an inout parameter in an async closure.
        let session = DownloadSession(account: account)
        defer { account = session.account }
        return try await recoverProduct(
            app: app,
            externalVersionID: externalVersionID,
            send: { endpoint, version in
                try await endpoint.fetchProduct(
                    client: client, account: &session.account, app: app,
                    deviceIdentifier: deviceIdentifier, externalVersionID: version
                )
            },
            endpoints: {
                let bag = try await Bag.fetchBag()
                return (bag.redownloadEndpoint, bag.updateEndpoint)
            },
            latestVersion: {
                try await PlatformVersionLookup.latestIOSVersion(app: app, store: session.account.store, entityType: entityType)
            }
        )
    }

    /// Recovery is deliberately limited to known availability responses. Token,
    /// license, rate limit, transport and other server errors keep their meaning.
    static func recoverProduct(
        app: Software,
        externalVersionID: String,
        send: (StoreDownloadEndpoint, String) async throws -> [String: Any],
        endpoints: () async throws -> (URL?, URL?),
        latestVersion: () async throws -> String?
    ) async throws -> [String: Any] {
        let initial = try await send(.volumeStore, externalVersionID)
        guard shouldRedownload(initial) else { return initial }

        let (redownloadURL, updateURL) = try await endpoints()
        guard let redownloadURL else { return initial }
        let redownload = try dispatch(redownloadURL)
        let version: String
        if externalVersionID.isEmpty {
            version = try await latestVersion() ?? ""
        } else {
            version = externalVersionID
        }
        let result: [String: Any]
        do {
            result = try await send(redownload, version)
        } catch FetchError.emptyRedownloadResponse where !version.isEmpty && updateURL != nil {
            let update = try dispatch(updateURL!, update: true)
            let result = try await send(update, version)
            try validateProduct(result, app: app, version: version)
            return result
        }
        if isUnavailable(result), !version.isEmpty, let updateURL {
            let update = try dispatch(updateURL, update: true)
            let result = try await send(update, version)
            try validateProduct(result, app: app, version: version)
            return result
        }
        try validateProduct(result, app: app, version: version)
        return result
    }

    static func shouldRedownload(_ response: [String: Any]) -> Bool {
        if response["failureType"] as? String == retryableFailureType { return true }
        guard response["songList"] == nil || response["songList"] is [Any],
              (response["failureType"] as? String ?? "").isEmpty,
              (response["songList"] as? [Any] ?? []).isEmpty
        else { return false }
        return (response["customerMessage"] as? String ?? "").isEmpty || isUnavailable(response)
    }

    static func isUnavailable(_ response: [String: Any]) -> Bool {
        guard response["songList"] == nil || response["songList"] is [Any],
              (response["failureType"] as? String ?? "").isEmpty,
              (response["songList"] as? [Any] ?? []).isEmpty
        else { return false }
        let message = (response["customerMessage"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return message == "no longer available" || message.hasSuffix(" no longer available")
    }

    static func validateProduct(_ response: [String: Any], app: Software, version: String) throws {
        // Structured failures are interpreted by Download/VersionFinder, e.g.
        // licenseRequired must still reach Asspp's existing license prompt.
        if !(response["failureType"] as? String ?? "").isEmpty { return }
        if let message = response["customerMessage"] as? String, !message.isEmpty {
            try ensureFailed(message)
        }
        guard let items = response["songList"] as? [[String: Any]], items.count == 1,
              let item = items.first,
              let metadata = item["metadata"] as? [String: Any],
              stringValue(metadata["itemId"]) == String(app.id),
              let bundleID = metadata["softwareVersionBundleId"] as? String,
              !bundleID.isEmpty, app.bundleID.isEmpty || bundleID == app.bundleID,
              version.isEmpty || stringValue(metadata["softwareVersionExternalIdentifier"]) == version,
              let url = item["URL"] as? String, !url.isEmpty
        else {
            try ensureFailed("Download response does not match the requested app or version")
        }
    }

    func fetchProduct(
        client: HTTPClient,
        account: inout Account,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String
    ) async throws -> [String: Any] {
        var currentURL = try url(pod: account.pod, deviceIdentifier: deviceIdentifier)
        for redirect in 0 ... 4 {
            try Task.checkCancellation()
            let request = try makeRequest(
                account: account, app: app, url: currentURL,
                guid: deviceIdentifier, externalVersionID: externalVersionID
            )
            let response = try await client.execute(request: request).get()
            account.cookie.mergeCookies(response.cookies, origin: currentURL)
            if [301, 302, 303, 307, 308].contains(response.status.code) {
                guard redirect < 4,
                      let location = response.headers.first(name: "location"),
                      let destination = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                      Self.isTrustedRedirect(destination)
                else { try ensureFailed(Strings.failedToRetrieveRedirect) }
                currentURL = destination
                continue
            }
            let data = response.body.map { Data($0.readableBytesView) } ?? Data()
            if case .redownload = self, response.status.code == 500, data.isEmpty {
                throw FetchError.emptyRedownloadResponse
            }
            try ensure(response.status == .ok, Strings.requestFailed(status: response.status.code))
            return try AuthenticationProtocol.plist(from: data)
        }
        try ensureFailed(Strings.noResponseReceived)
    }

    static func isTrustedRedirect(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.fragment == nil, components.port == nil || components.port == 443,
              let host = components.host?.lowercased()
        else { return false }
        return host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com") ||
            host == "downloaddispatch.itunes.apple.com"
    }

    func makeRequest(
        account: Account, app: Software, url: URL, guid: String, externalVersionID: String
    ) throws -> HTTPClient.Request {
        var payload: [String: Any] = [
            "creditDisplay": "", "guid": guid, "salableAdamId": app.id, "serialNumber": "0",
        ]
        if !externalVersionID.isEmpty { payload[externalVersionIDKey] = externalVersionID }
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var headers = [
            ("Content-Type", "application/x-apple-plist"), ("User-Agent", Configuration.userAgent),
            ("iCloud-DSID", account.directoryServicesIdentifier), ("X-Dsid", account.directoryServicesIdentifier),
        ]
        headers.append(contentsOf: account.cookie.buildCookieHeader(url))
        return try .init(url: url, method: .POST, headers: .init(headers), body: .data(data))
    }

    static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

private final class DownloadSession {
    var account: Account
    init(account: Account) { self.account = account }
}
