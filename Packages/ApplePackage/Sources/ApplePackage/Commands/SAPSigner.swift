import Foundation
#if canImport(AppleSAP)
import AppleSAP
#endif

enum SAPSigner {
    static func validatedBag(_ bag: Bag.BagOutput) throws -> [String: Any] {
        try AuthenticationProtocol.validateEndpoint(bag.authEndpoint)
        let values = bag.values
        let version = (values["sign-sap-version"] as? String)
            ?? (values["sign-sap-version"] as? NSNumber)?.stringValue
        guard version == "200" else {
            throw AuthenticationProtocol.ProtocolError("Apple returned an unsupported SAP signing version.")
        }
        // Native StoreServices owns the handshake. Constrain its bag to the two
        // expected Apple endpoints; no remote signer ever receives the payload.
        let endpoints = [
            "sign-sap-setup": ("fpinit.itunes.apple.com", "/v1/signSapSetup/legacy"),
            "sign-sap-setup-cert": ("s.mzstatic.com", "/sap/setupCert.plist"),
        ]
        for (key, expected) in endpoints {
            guard let string = values[key] as? String, let url = URLComponents(string: string),
                  url.scheme == "https", url.host?.lowercased() == expected.0,
                  url.percentEncodedPath == expected.1, url.user == nil, url.password == nil,
                  url.fragment == nil, url.query == nil, url.port == nil || url.port == 443 else {
                throw AuthenticationProtocol.ProtocolError("Apple returned an unsupported SAP signing endpoint.")
            }
        }
        return [
            "sign-sap-setup": values["sign-sap-setup"]!,
            "sign-sap-setup-cert": values["sign-sap-setup-cert"]!,
            "sign-sap-version": "200",
        ]
    }

    static func sign(_ body: Data, bag: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        #if canImport(AppleSAP)
        let signature: Data = try await withCheckedThrowingContinuation { continuation in
            APSAPSignData(body, bag) { signature, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let signature, !signature.isEmpty {
                    continuation.resume(returning: signature)
                } else {
                    continuation.resume(throwing: AuthenticationProtocol.ProtocolError("Apple SAP returned an empty signature."))
                }
            }
        }
        try Task.checkCancellation()
        return signature
        #else
        throw AuthenticationProtocol.ProtocolError("Apple SAP signing requires a physical iOS device or macOS.")
        #endif
    }
}
