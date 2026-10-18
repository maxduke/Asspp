import Foundation

/// Protocol rules shared by the transport and fixture tests. No signing or networking here.
enum AuthenticationProtocol {
    static let path = "/WebObjects/MZFinance.woa/wa/authenticate"

    static func validateEndpoint(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme == "https", let host = components.host?.lowercased(),
              host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com"),
              components.user == nil, components.password == nil,
              components.fragment == nil, components.port == nil || components.port == 443,
              components.percentEncodedPath == path || components.percentEncodedPath == path + "/"
        else {
            throw ProtocolError("Apple returned an unsupported authentication endpoint.")
        }
    }

    static func initialEndpoint(_ url: URL, guid: String) throws -> URL {
        try validateEndpoint(url)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw ProtocolError("Apple returned an invalid authentication endpoint.")
        }
        components.path = path + "/"
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "guid" }
        items.append(URLQueryItem(name: "guid", value: guid))
        components.queryItems = items
        guard let endpoint = components.url else {
            throw ProtocolError("Apple returned an invalid authentication endpoint.")
        }
        return endpoint
    }

    static func redirect(from endpoint: URL, location: String) throws -> URL {
        let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty, let destination = URL(string: location, relativeTo: endpoint)?.absoluteURL else {
            throw ProtocolError("Apple returned an invalid authentication redirect.")
        }
        try validateEndpoint(destination)
        return destination
    }

    static func normalizedCode(_ code: String) throws -> String {
        if code.isEmpty { return "" }
        let normalized = code.filter { !$0.isWhitespace }
        guard normalized.utf8.count == 6, normalized.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            throw ProtocolError("The verification code must contain exactly six digits.")
        }
        return normalized
    }

    /// Routing hint only; never rewrite the Apple ID in the signed payload.
    static func phoneNumberStorefront(_ appleID: String) -> String? {
        var number = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        var international = false
        if number.hasPrefix("+") {
            international = true
            number.removeFirst()
        } else if number.hasPrefix("00") {
            international = true
            number.removeFirst(2)
        }
        guard !number.isEmpty, number.utf8.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
        if number.count == 13, number.hasPrefix("861") { return "143465" }
        if number.count == 12, number.hasPrefix("91") {
            number.removeFirst(2)
        } else if international {
            return nil
        }
        if number.count == 11, number.hasPrefix("1") { return "143465" }
        if !international, number.count == 11, number.hasPrefix("0") { number.removeFirst() }
        if number.count == 10, let first = number.utf8.first, (54 ... 57).contains(first) { return "143467" }
        return nil
    }

    static func body(email: String, password: String, code: String, guid: String, attempt: Int) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "appleId": email,
            "attempt": String(attempt),
            "guid": guid,
            "password": password + code,
            "rmp": "0",
            "why": "signIn",
        ], format: .xml, options: 0)
    }

    static func plist(from data: Data) throws -> [String: Any] {
        var payload = data
        if var xml = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            // The Store can wrap a plist, a dict, or bare key/value pairs in
            // Document/Protocol elements. Binary plists pass through unchanged.
            if xml.hasPrefix("<?xml"), let declaration = xml.range(of: "?>") {
                xml = String(xml[declaration.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let opening = xml.range(of: "^<Document(?:\\s[^>]*)?>", options: .regularExpression),
               let closing = xml.range(of: "</Document>", options: .backwards),
               closing.upperBound == xml.endIndex, opening.upperBound <= closing.lowerBound {
                xml = String(xml[opening.upperBound ..< closing.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if xml.hasPrefix("<Protocol>"), xml.hasSuffix("</Protocol>") {
                xml = String(xml.dropFirst("<Protocol>".count).dropLast("</Protocol>".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let start = xml.range(of: "<plist"), let end = xml.range(of: "</plist>", options: .backwards),
               start.lowerBound < end.upperBound {
                payload = Data(xml[start.lowerBound ..< end.upperBound].utf8)
            } else if xml.hasPrefix("<dict>"), xml.hasSuffix("</dict>") {
                payload = Data("<plist version=\"1.0\">\(xml)</plist>".utf8)
            } else if xml.hasPrefix("<key>") {
                payload = Data("<plist version=\"1.0\"><dict>\(xml)</dict></plist>".utf8)
            }
        }
        guard let dictionary = (try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil)) as? [String: Any] else {
            throw ProtocolError("Apple returned an invalid property list response.")
        }
        return dictionary
    }

    struct ProtocolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
