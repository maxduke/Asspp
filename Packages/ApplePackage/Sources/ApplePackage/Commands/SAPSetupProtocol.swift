import AsyncHTTPClient
import Foundation
import NIOHTTP1

/// The two Apple HTTP exchanges used by ipatool's SAP signer. Neither request
/// contains the login body, account cookies, password or verification code.
enum SAPSetupProtocol {
    static let maximumResponseSize = 1 << 20

    struct Request {
        let url: String
        let method: HTTPMethod
        let headers: HTTPHeaders
        let body: Data?
    }

    struct Response {
        let status: HTTPResponseStatus
        let body: Data
    }

    typealias Sender = (Request) async throws -> Response

    static func certificate(bag: [String: Any], send: Sender) async throws -> Data {
        try Task.checkCancellation()
        guard let url = bag["sign-sap-setup-cert"] as? String else {
            throw invalidResponse()
        }
        let request = Request(url: url, method: .GET, headers: [
            "User-Agent": Configuration.userAgent,
        ], body: nil)
        let response = try await send(request)
        try Task.checkCancellation()
        return try bytes(from: response, key: "sign-sap-setup-cert")
    }

    static func exchange(_ buffer: Data, bag: [String: Any], send: Sender) async throws -> Data {
        try Task.checkCancellation()
        guard !buffer.isEmpty, buffer.count <= maximumResponseSize,
              let url = bag["sign-sap-setup"] as? String else {
            throw invalidResponse()
        }
        let body = try PropertyListSerialization.data(
            fromPropertyList: ["sign-sap-setup-buffer": buffer], format: .xml, options: 0
        )
        let request = Request(url: url, method: .POST, headers: [
            "User-Agent": Configuration.userAgent,
            "Content-Type": "application/x-plist",
        ], body: body)
        let response = try await send(request)
        try Task.checkCancellation()
        return try bytes(from: response, key: "sign-sap-setup-buffer")
    }

    static func send(_ request: Request, using client: HTTPClient) async throws -> Response {
        var outgoing = HTTPClientRequest(url: request.url)
        outgoing.method = request.method
        outgoing.headers = request.headers
        if let body = request.body { outgoing.body = .bytes(body) }
        let response = try await client.execute(outgoing, timeout: .seconds(20))
        // Redirects are disabled by the client. Never follow a setup endpoint
        // outside the validated bag, and bound bytes while receiving the body.
        guard response.status == .ok else {
            return Response(status: response.status, body: Data())
        }
        let body = try await response.body.collect(upTo: maximumResponseSize)
        return Response(status: response.status, body: Data(body.readableBytesView))
    }

    private static func bytes(from response: Response, key: String) throws -> Data {
        guard response.status == .ok else {
            throw NSError(domain: "ApplePackage.SAP.HTTP", code: Int(response.status.code))
        }
        guard response.body.count <= maximumResponseSize,
              let values = try? AuthenticationProtocol.plist(from: response.body),
              let data = values[key] as? Data, !data.isEmpty else {
            throw invalidResponse()
        }
        return data
    }

    private static func invalidResponse() -> NSError {
        NSError(domain: "ApplePackage.SAP", code: 3)
    }
}
