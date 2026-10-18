import AsyncHTTPClient
import Foundation
import NIOCore

public enum Bag {
    public struct BagOutput {
        public var authEndpoint: URL
        public var redownloadEndpoint: URL?
        public var updateEndpoint: URL?
        var values: [String: Any]

        public init(authEndpoint: URL, redownloadEndpoint: URL? = nil, updateEndpoint: URL? = nil) {
            self.authEndpoint = authEndpoint
            self.redownloadEndpoint = redownloadEndpoint
            self.updateEndpoint = updateEndpoint
            values = [:]
        }
    }

    public static func fetchBag() async throws -> BagOutput {
        let client = Configuration.makeHTTPClient(redirectConfiguration: .disallow)
        defer { _ = client.shutdown() }
        var components = URLComponents(string: "https://init.itunes.apple.com/bag.xml")!
        components.queryItems = [URLQueryItem(name: "guid", value: Configuration.deviceIdentifier)]
        let request = try HTTPClient.Request(url: components.url!.absoluteString, method: .GET, headers: .init([
            ("User-Agent", Configuration.userAgent),
            ("Accept", "application/xml"),
        ]))
        let response = try await client.execute(request: request, deadline: .now() + .seconds(Configuration.timeoutRead)).get()
        guard response.status == .ok, let body = response.body
        else {
            throw AuthenticationProtocol.ProtocolError("Could not retrieve the Apple Store configuration.")
        }
        return try parse(Data(body.readableBytesView))
    }

    static func parse(_ data: Data) throws -> BagOutput {
        let root = try AuthenticationProtocol.plist(from: data)
        var values = root["urlBag"] as? [String: Any] ?? [:]
        for (key, value) in root where key != "urlBag" { values[key] = value }
        // Authentication validates this URL and SAP configuration separately;
        // downloads must still work if the bag omits authentication metadata.
        let auth = (values["authenticateAccount"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://buy.itunes.apple.com" + AuthenticationProtocol.path + "/")!
        var result = BagOutput(
            authEndpoint: auth,
            redownloadEndpoint: (values["redownloadProduct"] as? String).flatMap(URL.init(string:)),
            updateEndpoint: (values["updateProduct"] as? String).flatMap(URL.init(string:))
        )
        result.values = values
        return result
    }
}
