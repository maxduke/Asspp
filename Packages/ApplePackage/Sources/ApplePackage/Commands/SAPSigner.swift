import AsyncHTTPClient
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
        // Constrain setup to the two expected Apple endpoints. The login body
        // is signed locally and never enters either setup request.
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
        try await sign(body, bag: bag, guid: Configuration.deviceIdentifier)
    }

    /// ipatool uses the bytes represented by the login GUID as SAP hardware
    /// identity. Keep them stable through setup, signing, redirects and retries.
    static func hardwareID(forGUID guid: String) throws -> Data {
        let characters = Array(guid.utf8)
        guard !characters.isEmpty, characters.count <= 40, characters.count.isMultiple(of: 2) else {
            throw AuthenticationProtocol.ProtocolError("The Apple Store device identifier must contain 1 to 20 hexadecimal bytes.")
        }
        func nibble(_ character: UInt8) -> UInt8? {
            switch character {
            case 48 ... 57: character - 48
            case 65 ... 70: character - 65 + 10
            case 97 ... 102: character - 97 + 10
            default: nil
            }
        }
        var bytes = Data()
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else {
                throw AuthenticationProtocol.ProtocolError("The Apple Store device identifier contains invalid hexadecimal bytes.")
            }
            bytes.append((high << 4) | low)
        }
        return bytes
    }

    static func sign(_ body: Data, bag: [String: Any], guid: String) async throws -> Data {
        try Task.checkCancellation()
        #if canImport(AppleSAP)
        #if os(iOS) && !targetEnvironment(simulator)
        let hardwareID = try hardwareID(forGUID: guid)
        let client = Configuration.makeHTTPClient(redirectConfiguration: .disallow)
        defer { _ = client.shutdown() }
        let certificate: Data
        do {
            certificate = try await SAPSetupProtocol.certificate(bag: bag) { request in
                try await SAPSetupProtocol.send(request, using: client)
            }
        } catch {
            try Task.checkCancellation()
            throw diagnosticError(operationError(stage: "iOS.certificate", cause: error))
        }
        let exchange: APSAPSetupExchange = { request, completion in
            Task {
                do {
                    let reply = try await SAPSetupProtocol.exchange(request, bag: bag) { outgoing in
                        try await SAPSetupProtocol.send(outgoing, using: client)
                    }
                    completion(reply, nil)
                } catch {
                    completion(nil, error as NSError)
                }
            }
        }
        return try await nativeSign(body, hardwareID: hardwareID, certificate: certificate, exchange: exchange)
        #else
        return try await nativeSign(body, hardwareID: nil, certificate: nil, exchange: nil)
        #endif
        #else
        throw AuthenticationProtocol.ProtocolError("Apple SAP signing requires a physical iOS device or macOS.")
        #endif
    }

    #if canImport(AppleSAP)
    private static func nativeSign(_ body: Data, hardwareID: Data?, certificate: Data?, exchange: APSAPSetupExchange?) async throws -> Data {
        try Task.checkCancellation()
        let signature: Data = try await withCheckedThrowingContinuation { continuation in
            APSAPSignData(body, hardwareID, certificate, exchange) { signature, error in
                if let error {
                    continuation.resume(throwing: diagnosticError(error as NSError))
                } else if let signature, !signature.isEmpty {
                    continuation.resume(returning: signature)
                } else {
                    continuation.resume(throwing: AuthenticationProtocol.ProtocolError("Apple SAP returned an empty signature."))
                }
            }
        }
        try Task.checkCancellation()
        return signature
    }
    #endif

    static func operationError(stage: String, cause: Error) -> NSError {
        NSError(domain: "ApplePackage.SAP", code: 2, userInfo: [
            "ApplePackageSAPStage": stage, NSUnderlyingErrorKey: cause as NSError,
        ])
    }

    /// Only fixed diagnostic metadata crosses the UI/logging boundary. Native
    /// descriptions, URLs and userInfo can contain the signed login payload.
    static func diagnosticError(_ error: NSError) -> AuthenticationProtocol.ProtocolError {
        let stages: Set<String> = [
            "native.sign", "native.capacity", "native.timeout",
            "iOS.load", "iOS.create-session", "iOS.validate-bag", "iOS.sign",
            "iOS.certificate", "iOS.context-init", "iOS.exchange-request",
            "iOS.engine-load", "iOS.engine-init",
            "iOS.setup-request", "iOS.exchange-response",
            "macOS.load", "macOS.create-session", "macOS.open-session", "macOS.sign",
        ]
        let reportedStage = error.userInfo["ApplePackageSAPStage"] as? String ?? "native.sign"
        let stage = stages.contains(reportedStage) ? reportedStage : "native.sign"
        let domains: Set<String> = [
            "ApplePackage.SAP", "ApplePackage.SAP.HTTP", "SSErrorDomain", "SSVErrorDomain", "AMSErrorDomain", "ASDErrorDomain",
            "ApplePackage.SAP.Native", "ApplePackage.SAP.Core", "ApplePackage.SAP.Symbols",
            NSURLErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain,
            "kCFErrorDomainCFNetwork", "kCFErrorDomainOSStatus", "AKAuthenticationError",
        ]
        var codes: [String] = []
        var current: NSError? = error
        var visited: Set<ObjectIdentifier> = []
        while let cause = current, codes.count < 4, visited.insert(ObjectIdentifier(cause)).inserted {
            let domain = domains.contains(cause.domain) ? cause.domain : "System"
            codes.append("\(domain)/\(cause.code)")
            current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return AuthenticationProtocol.ProtocolError(
            "Apple SAP signing failed [\(stage); \(codes.joined(separator: " -> ")); OS \(systemVersion)]."
        )
    }
}
