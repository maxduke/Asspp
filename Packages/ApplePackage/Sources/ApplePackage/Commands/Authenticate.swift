import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

public enum Authenticator {
    public static func authenticate(
        email: String,
        password: String,
        code: String = "",
        cookies: [Cookie] = []
    ) async throws -> Account {
        // Validate user input before touching either the Store or native signer.
        let code = try AuthenticationProtocol.normalizedCode(code)
        let guid = Configuration.deviceIdentifier
        let bag = try await Bag.fetchBag()
        let client = Configuration.makeHTTPClient(redirectConfiguration: .disallow)
        defer { _ = client.shutdown() }
        return try await authenticate(
            email: email, password: password, code: code, cookies: cookies,
            guid: guid, bag: bag,
            sign: { body, signingBag in
                try await SAPSigner.sign(body, bag: signingBag, guid: guid)
            },
            send: { request in
                try await client.execute(request: request, deadline: .now() + .seconds(Configuration.timeoutRead)).get()
            }
        )
    }

    // Injection is internal and used only by fixture tests. Production always
    // signs locally and never sends an unsigned fallback request.
    static func authenticate(
        email: String, password: String, code: String, cookies initialCookies: [Cookie],
        guid: String, bag: Bag.BagOutput,
        sign: (Data, [String: Any]) async throws -> Data,
        send: (HTTPClient.Request) async throws -> HTTPClient.Response,
        sleep: (Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) async throws -> Account {
        let code = try AuthenticationProtocol.normalizedCode(code)
        let signingBag = try SAPSigner.validatedBag(bag)
        var endpoint = try AuthenticationProtocol.initialEndpoint(bag.authEndpoint, guid: guid)
        var cookies = initialCookies
        var redirects = 0
        var attempt = 1
        var storeFront = ""
        var pod: String?

        while attempt <= 2 {
            // Serialize once per login attempt. Every send signs these same
            // bytes, including after a transport retry or Store pod redirect.
            let body = try AuthenticationProtocol.body(email: email, password: password, code: code, guid: guid, attempt: attempt)
            while true {
                try Task.checkCancellation()
                var headers: [(String, String)] = [
                    ("User-Agent", Configuration.userAgent),
                    ("Content-Type", "application/x-www-form-urlencoded"),
                    ("Connection", "close"),
                ]
                if let storefront = AuthenticationProtocol.phoneNumberStorefront(email) {
                    headers.append(("X-Apple-Store-Front", storefront))
                }
                let request = try HTTPClient.Request(url: endpoint.absoluteString, method: .POST,
                                                     headers: .init(headers), body: .data(body))
                let response = try await sendWithRetry(
                    request, cookies: &cookies,
                    sign: { try await sign(body, signingBag) }, send: send, sleep: sleep
                )
                // Never log request bodies, signatures, cookies, or response headers.
                APLogger.debug("auth: received HTTP \(response.status.code)")
                if let value = response.headers.first(name: "x-set-apple-store-front"), !value.isEmpty {
                    storeFront = value.components(separatedBy: "-")[0]
                }
                if let value = response.headers.first(name: "pod"), !value.isEmpty { pod = value }

                let status = response.status.code
                if (300 ..< 400).contains(status) {
                    guard [301, 302, 307, 308].contains(status), redirects < 4,
                          let location = response.headers.first(name: "location") else {
                        throw AuthenticationProtocol.ProtocolError("Apple returned an invalid or repeated authentication redirect.")
                    }
                    endpoint = try AuthenticationProtocol.redirect(from: endpoint, location: location)
                    redirects += 1
                    continue
                }

                guard let buffer = response.body,
                      let dictionary = try? AuthenticationProtocol.plist(from: Data(buffer.readableBytesView)) else {
                    throw AuthenticationProtocol.ProtocolError("Apple returned no usable authentication response (HTTP \(status)). Try again later.")
                }
                let failureType = dictionary["failureType"] as? String ?? ""
                let message = dictionary["customerMessage"] as? String ?? ""
                if failureType == "-5000", attempt == 1 {
                    attempt += 1
                    break
                }
                if failureType.isEmpty, message == "MZFinance.BadLogin.Configurator_message" {
                    throw AuthenticationProtocol.ProtocolError(code.isEmpty ? Strings.authRequiresVerificationCode : Strings.invalid2FACode)
                }
                if failureType == "5005" {
                    throw AuthenticationProtocol.ProtocolError(Strings.invalid2FACode)
                }
                if !failureType.isEmpty {
                    throw AuthenticationProtocol.ProtocolError(message.isEmpty ? Strings.authFailed : message)
                }
                if message == "Your account is disabled." {
                    throw AuthenticationProtocol.ProtocolError(message)
                }
                guard status == 200,
                      let token = dictionary["passwordToken"] as? String, !token.isEmpty,
                      let dsid = dictionary["dsPersonId"] as? String, !dsid.isEmpty,
                      let account = dictionary["accountInfo"] as? [String: Any] else {
                    throw AuthenticationProtocol.ProtocolError("Apple returned no usable account credentials. Try again later.")
                }
                let address = account["address"] as? [String: Any] ?? [:]
                guard !storeFront.isEmpty else {
                    throw AuthenticationProtocol.ProtocolError(Strings.unknownStoreIdentifier)
                }
                guard Configuration.countryCode(for: storeFront) != nil else {
                    throw AuthenticationProtocol.ProtocolError(Strings.unsupportedStoreIdentifier(storeFront))
                }
                return Account(
                    email: email, password: password,
                    appleId: account["appleId"] as? String ?? email,
                    store: storeFront, firstName: address["firstName"] as? String ?? "",
                    lastName: address["lastName"] as? String ?? "", passwordToken: token,
                    directoryServicesIdentifier: dsid, cookie: cookies, pod: pod
                )
            }
        }
        throw AuthenticationProtocol.ProtocolError(Strings.authFailedUnknown)
    }

    public static func rotatePasswordToken(for account: inout Account) async throws {
        account = try await authenticate(email: account.email, password: account.password, cookies: account.cookie)
    }

    private static func sendWithRetry(
        _ originalRequest: HTTPClient.Request,
        cookies: inout [Cookie],
        sign: () async throws -> Data,
        send: (HTTPClient.Request) async throws -> HTTPClient.Response,
        sleep: (Double) async throws -> Void
    ) async throws -> HTTPClient.Response {
        var request = originalRequest
        for attempt in 0 ..< 3 {
            try Task.checkCancellation()
            request.headers.remove(name: "Cookie")
            for (name, value) in cookies.buildCookieHeader(request.url) {
                request.headers.add(name: name, value: value)
            }
            // SAP signatures may carry session state. Sign each actual send,
            // while keeping the serialized payload and attempt unchanged.
            // Signing failures are outside the transport retry handler.
            let signature = try await sign()
            guard !signature.isEmpty else {
                throw AuthenticationProtocol.ProtocolError("Apple SAP returned an empty signature.")
            }
            try Task.checkCancellation()
            request.headers.replaceOrAdd(name: "X-Apple-ActionSignature", value: signature.base64EncodedString())
            let response: HTTPClient.Response
            do {
                response = try await send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled || (error as? HTTPClientError) == .cancelled {
                    throw CancellationError()
                }
                guard attempt < 2, isRetryableTransportError(error) else {
                    // Transport errors may embed a credential-bearing request.
                    throw AuthenticationProtocol.ProtocolError("The Apple authentication request failed. Check your connection and try again.")
                }
                // Retry the same POST bytes after a timeout or dropped
                // connection, just as for a transient empty Store response.
                try await sleep(Double(10 << attempt))
                continue
            }
            // Retry responses can establish the session needed by the next
            // request. Keep their cookies before deciding whether to retry.
            cookies.mergeCookies(response.cookies, origin: request.url)
            let status = response.status.code
            // Never retry Apple's structured credential/verification failures.
            if let buffer = response.body,
               let dictionary = try? AuthenticationProtocol.plist(from: Data(buffer.readableBytesView)),
               !(dictionary["failureType"] as? String ?? "").isEmpty ||
               !(dictionary["customerMessage"] as? String ?? "").isEmpty || dictionary["accountInfo"] != nil {
                return response
            }
            guard attempt < 2, [204, 403, 404, 429].contains(status) || (500 ..< 600).contains(status) else { return response }
            var delay = Double(10 << attempt)
            if let retryAfter = response.headers.first(name: "retry-after") {
                if let seconds = Double(retryAfter), seconds >= 0 {
                    guard seconds.isFinite else {
                        throw AuthenticationProtocol.ProtocolError("Apple requested a longer wait before signing in. Try again later.")
                    }
                    delay = max(1, seconds)
                } else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    if let date = formatter.date(from: retryAfter) { delay = max(1, date.timeIntervalSinceNow) }
                }
            }
            guard delay <= 30 else {
                throw AuthenticationProtocol.ProtocolError("Apple requested a longer wait before signing in. Try again later.")
            }
            try await sleep(delay)
        }
        throw AuthenticationProtocol.ProtocolError(Strings.authFailedUnknown)
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        if let error = error as? HTTPClientError {
            return [.connectTimeout, .readTimeout, .remoteConnectionClosed, .deadlineExceeded,
                    .uncleanShutdown].contains(error)
        }
        if let error = error as? ChannelError {
            switch error {
            case .connectTimeout, .eof: return true
            default: return false
            }
        }
        if let error = error as? IOError {
            return [POSIXErrorCode.ECONNRESET.rawValue, POSIXErrorCode.EPIPE.rawValue,
                    POSIXErrorCode.ETIMEDOUT.rawValue].contains(error.errnoCode)
        }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost].contains(error.code)
        }
        return false
    }
}
