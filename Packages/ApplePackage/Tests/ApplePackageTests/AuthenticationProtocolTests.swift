import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ApplePackage

final class AuthenticationProtocolTests: XCTestCase {
    private let endpoint = URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate")!

    private func bag(_ additions: [String: Any] = [:]) throws -> Bag.BagOutput {
        var values: [String: Any] = [
            "authenticateAccount": endpoint.absoluteString,
            "sign-sap-setup": "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy",
            "sign-sap-setup-cert": "https://s.mzstatic.com/sap/setupCert.plist",
            "sign-sap-version": "200",
        ]
        values.merge(additions) { _, new in new }
        return try Bag.parse(PropertyListSerialization.data(fromPropertyList: ["urlBag": values], format: .xml, options: 0))
    }

    private func response(_ values: [String: Any], status: HTTPResponseStatus = .ok,
                          headers: HTTPHeaders = [:]) throws -> HTTPClient.Response {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        return HTTPClient.Response(host: "buy.itunes.apple.com", status: status, version: .http1_1,
                                   headers: headers, body: ByteBuffer(bytes: data))
    }

    private func success() throws -> HTTPClient.Response {
        try response([
            "accountInfo": ["appleId": "fixture@example.test", "address": ["firstName": "Test", "lastName": "Account"]],
            "passwordToken": "fixture-token", "dsPersonId": "123",
        ], headers: ["X-Set-Apple-Store-Front": "143441-1,29", "pod": "25"])
    }

    func testNativeSAPSigning() async throws {
        guard ProcessInfo.processInfo.environment["APPLEPACKAGE_TEST_NATIVE_SAP"] == "1" else {
            throw XCTSkip("Set APPLEPACKAGE_TEST_NATIVE_SAP=1 on a physical Apple platform to run the native signing smoke test.")
        }
        let signature = try await SAPSigner.sign(Data("ApplePackage SAP signing smoke test".utf8), bag: SAPSigner.validatedBag(bag()))
        XCTAssertFalse(signature.isEmpty)
    }

    func testPhoneNumberRoutingDoesNotChangeAppleID() throws {
        for number in ["13800138000", "+86 138-0013-8000", "008613800138000", "8613800138000"] {
            XCTAssertEqual(AuthenticationProtocol.phoneNumberStorefront(number), "143465")
            let body = try AuthenticationProtocol.body(email: number, password: "secret", code: "", guid: "001122334455", attempt: 1)
            XCTAssertEqual(try AuthenticationProtocol.plist(from: body)["appleId"] as? String, number)
        }
        for number in ["9876543210", "919876543210", "+91 98765-43210", "09876543210", "9198765432"] {
            XCTAssertEqual(AuthenticationProtocol.phoneNumberStorefront(number), "143467")
        }
        for number in ["person@example.test", "+1 9876543210", "+13800138000", "123", "", "１２３４５６７８９０"] {
            XCTAssertNil(AuthenticationProtocol.phoneNumberStorefront(number))
        }
    }

    func testRejectsUntrustedAuthenticationEndpoints() {
        for url in [
            "http://buy.itunes.apple.com" + AuthenticationProtocol.path,
            "https://buy.itunes.apple.com.evil.test" + AuthenticationProtocol.path,
            "https://evil.test" + AuthenticationProtocol.path,
            "https://user:password@buy.itunes.apple.com" + AuthenticationProtocol.path,
            endpoint.absoluteString + "#fragment", endpoint.absoluteString + "%2f",
            "https://buy.itunes.apple.com:8443" + AuthenticationProtocol.path,
            "https://buy.itunes.apple.com/other", "https://auth.itunes.apple.com/auth/v1/native/fast/",
        ] {
            XCTAssertThrowsError(try AuthenticationProtocol.validateEndpoint(URL(string: url)!))
        }
    }

    func testNormalizesTrailingSlashPreservingQueryAndReplacingGUID() throws {
        let original = URL(string: endpoint.absoluteString + "?client=test&guid=old")!
        let result = try AuthenticationProtocol.initialEndpoint(original, guid: "001122334455")
        XCTAssertEqual(result.path, AuthenticationProtocol.path)
        XCTAssertTrue(result.absoluteString.contains("authenticate/?"))
        XCTAssertEqual(URLComponents(url: result, resolvingAgainstBaseURL: true)?.queryItems,
                       [URLQueryItem(name: "client", value: "test"), URLQueryItem(name: "guid", value: "001122334455")])
    }

    func testRedirectValidationIncludesRelativeDestinations() throws {
        XCTAssertEqual(try AuthenticationProtocol.redirect(from: endpoint, location: "?pod=25").host, endpoint.host)
        XCTAssertEqual(try AuthenticationProtocol.redirect(from: endpoint, location: "https://p25-buy.itunes.apple.com" + AuthenticationProtocol.path).host,
                       "p25-buy.itunes.apple.com")
        XCTAssertThrowsError(try AuthenticationProtocol.redirect(from: endpoint, location: "//evil.test/path"))
        XCTAssertThrowsError(try AuthenticationProtocol.redirect(from: endpoint, location: ""))
    }

    func testNormalizesSixDigitCodeAndEscapesPasswordInXML() throws {
        XCTAssertEqual(try AuthenticationProtocol.normalizedCode(" 123 456\n"), "123456")
        XCTAssertEqual(try AuthenticationProtocol.normalizedCode(""), "")
        for invalid in ["12345", "1234567", "abcdef", "１２３４５６", "  "] {
            XCTAssertThrowsError(try AuthenticationProtocol.normalizedCode(invalid))
        }
        let body = try AuthenticationProtocol.body(email: "a&b@example.test", password: "<&secret>", code: "123456", guid: "001122334455", attempt: 1)
        let dictionary = try AuthenticationProtocol.plist(from: body)
        XCTAssertEqual(dictionary["password"] as? String, "<&secret>123456")
        XCTAssertEqual(dictionary["attempt"] as? String, "1")
    }

    func testBagParsesWrappedPlistAndDownloadEndpoints() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["urlBag": [
            "redownloadProduct": "https://downloaddispatch.itunes.apple.com/r/redownload",
            "updateProduct": "https://downloaddispatch.itunes.apple.com/up/updateProduct",
            "sign-sap-version": "999",
        ]], format: .xml, options: 0)
        let result = try Bag.parse(Data("<Document><Protocol>".utf8) + data + Data("</Protocol></Document>".utf8))
        XCTAssertEqual(result.redownloadEndpoint?.host, "downloaddispatch.itunes.apple.com")
        XCTAssertEqual(result.updateEndpoint?.path, "/up/updateProduct")
        XCTAssertThrowsError(try SAPSigner.validatedBag(result))
    }

    func testStorePlistEnvelopesAndBinaryResponses() throws {
        let values: [String: Any] = ["passwordToken": "fixture-token", "accountInfo": ["appleId": "fixture@example.test"]]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        let xml = String(decoding: data, as: UTF8.self)
        let start = try XCTUnwrap(xml.range(of: "<dict>"))
        let end = try XCTUnwrap(xml.range(of: "</dict>", options: .backwards))
        let dictionary = String(xml[start.lowerBound ..< end.upperBound])
        let fields = String(dictionary.dropFirst("<dict>".count).dropLast("</dict>".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payloads = [
            data,
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0),
            Data("<Document xmlns=\"http://www.apple.com/itms/\"><Protocol>\(xml)</Protocol></Document>".utf8),
            Data("<Document>\(dictionary)</Document>".utf8),
            Data("<?xml version=\"1.0\"?><Document>\(fields)</Document>".utf8),
            Data(fields.utf8),
        ]
        for payload in payloads {
            XCTAssertEqual(try AuthenticationProtocol.plist(from: payload) as NSDictionary, values as NSDictionary)
        }
        for invalid in ["<html>Unavailable</html>", "<Document></Document>", "<Document attr=\"</Document>\"", "<dict><key>missingValue</key></dict>"] {
            XCTAssertThrowsError(try AuthenticationProtocol.plist(from: Data(invalid.utf8)))
        }
    }

    func testWrappedVerificationChallengeIsNotRetried() async throws {
        var sends = 0
        do {
            _ = try await Authenticator.authenticate(
                email: "fixture@example.test", password: "secret", code: "", cookies: [],
                guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                    sends += 1
                    let body = "<Document><key>customerMessage</key><string>MZFinance.BadLogin.Configurator_message</string></Document>"
                    return HTTPClient.Response(host: "buy.itunes.apple.com", status: .forbidden, version: .http1_1,
                                               headers: [:], body: ByteBuffer(string: body))
                }, sleep: { _ in XCTFail("A verification challenge must not retry") }
            )
            XCTFail("Expected verification prompt")
        } catch {
            XCTAssertEqual(error.localizedDescription, Strings.authRequiresVerificationCode)
            XCTAssertEqual(sends, 1)
        }
    }

    func testRejectsUntrustedSAPEndpoints() throws {
        for overrides: [String: Any] in [
            ["sign-sap-version": "300"],
            ["sign-sap-setup": "https://evil.test/sign"],
            ["sign-sap-setup-cert": "http://s.mzstatic.com/sap/setupCert.plist"],
            ["sign-sap-setup": "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy?proxy=evil"],
        ] {
            XCTAssertThrowsError(try SAPSigner.validatedBag(bag(overrides)))
        }
    }

    func testSignedRedirectKeepsBodyAttemptAndAccountPassword() async throws {
        var signedBodies: [Data] = []
        var requests = 0
        let account = try await Authenticator.authenticate(
            email: "fixture@example.test", password: "secret", code: "123 456", cookies: [],
            guid: "001122334455", bag: bag(), sign: { bytes, _ in
                signedBodies.append(bytes)
                return Data([UInt8(signedBodies.count)])
            }, send: { request in
                requests += 1
                XCTAssertEqual(request.method, .POST)
                XCTAssertEqual(request.headers.first(name: "X-Apple-ActionSignature"), Data([UInt8(requests)]).base64EncodedString())
                let expectedBody = signedBodies[0]
                XCTAssertEqual(request.body?.contentLength, Int64(expectedBody.count))
                let loop = MultiThreadedEventLoopGroup.singleton.next()
                try await request.body?.stream(.init { chunk in
                    if case let .byteBuffer(buffer) = chunk {
                        XCTAssertEqual(Data(buffer.readableBytesView), expectedBody)
                    } else {
                        XCTFail("Unexpected file body")
                    }
                    return loop.makeSucceededVoidFuture()
                }).get()
                if requests == 1 {
                    return HTTPClient.Response(host: "buy.itunes.apple.com", status: .found, version: .http1_1, headers: [
                        "Location": "https://p25-buy.itunes.apple.com" + AuthenticationProtocol.path + "/",
                        "Set-Cookie": "session=fixture; Domain=.itunes.apple.com; Path=/; Secure",
                    ], body: nil)
                }
                XCTAssertEqual(request.url.host, "p25-buy.itunes.apple.com")
                XCTAssertEqual(request.headers.first(name: "Cookie"), "session=fixture")
                return try self.success()
            }
        )
        XCTAssertEqual(signedBodies.count, 2)
        XCTAssertEqual(signedBodies.first, signedBodies.last)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(try AuthenticationProtocol.plist(from: signedBodies[0])["password"] as? String, "secret123456")
        XCTAssertEqual(account.password, "secret")
        XCTAssertEqual(account.pod, "25")
    }

    func testInvalidCredentialsRetrySignsNewAttemptExactlyOnce() async throws {
        var attempts: [String] = []
        var requests = 0
        _ = try await Authenticator.authenticate(email: "fixture@example.test", password: "secret", code: "", cookies: [],
                                                guid: "001122334455", bag: bag(), sign: { body, _ in
            attempts.append(try AuthenticationProtocol.plist(from: body)["attempt"] as! String)
            return Data([1])
        }, send: { _ in
            requests += 1
            return try requests == 1 ? self.response(["failureType": "-5000"]) : self.success()
        })
        XCTAssertEqual(attempts, ["1", "2"])
        XCTAssertEqual(requests, 2)
    }

    func testAbsentFailureTypeStillPromptsForVerification() async throws {
        do {
            _ = try await Authenticator.authenticate(email: "fixture@example.test", password: "secret", code: "", cookies: [],
                                                    guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                try self.response(["customerMessage": "MZFinance.BadLogin.Configurator_message"])
            })
            XCTFail("Expected verification prompt")
        } catch {
            XCTAssertEqual(error.localizedDescription, Strings.authRequiresVerificationCode)
        }
    }

    func testLoginRejectsMissingOrUnsupportedStorefront() async throws {
        for storefront in ["", "999999-1,29"] {
            do {
                _ = try await Authenticator.authenticate(
                    email: "fixture@example.test", password: "secret", code: "", cookies: [],
                    guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                        var response = try self.success()
                        response.headers.remove(name: "X-Set-Apple-Store-Front")
                        if !storefront.isEmpty {
                            response.headers.add(name: "X-Set-Apple-Store-Front", value: storefront)
                        }
                        return response
                    }
                )
                XCTFail("An unusable account must not be saved")
            } catch {
                XCTAssertEqual(error.localizedDescription, storefront.isEmpty ? Strings.unknownStoreIdentifier : Strings.unsupportedStoreIdentifier("999999"))
            }
        }
    }

    func testSignerFailureNeverSendsCredentials() async throws {
        do {
            _ = try await Authenticator.authenticate(email: "fixture@example.test", password: "secret", code: "", cookies: [],
                                                    guid: "001122334455", bag: bag(), sign: { _, _ in
                throw AuthenticationProtocol.ProtocolError("signer unavailable")
            }, send: { _ in
                XCTFail("An unsigned login must never be sent")
                return try self.success()
            })
            XCTFail("Expected signer failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "signer unavailable")
        }
    }

    func testExcessiveRetryAfterDoesNotRetryEarly() async throws {
        var sends = 0
        do {
            _ = try await Authenticator.authenticate(email: "fixture@example.test", password: "secret", code: "", cookies: [],
                                                    guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                sends += 1
                return HTTPClient.Response(host: "buy.itunes.apple.com", status: .tooManyRequests, version: .http1_1,
                                           headers: ["Retry-After": "120"], body: nil)
            })
            XCTFail("Expected requested wait to end this login")
        } catch {
            XCTAssertEqual(sends, 1)
            XCTAssertTrue(error.localizedDescription.contains("longer wait"))
        }
    }

    func testExternalRedirectStopsBeforeSendingSecondRequest() async throws {
        var sends = 0
        do {
            _ = try await Authenticator.authenticate(email: "fixture@example.test", password: "secret", code: "", cookies: [],
                                                    guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                sends += 1
                return HTTPClient.Response(host: "buy.itunes.apple.com", status: .temporaryRedirect, version: .http1_1, headers: ["Location": "https://evil.test/login"], body: nil)
            })
            XCTFail("Expected unsafe redirect rejection")
        } catch {
            XCTAssertEqual(sends, 1)
        }
    }

    func testSeeOtherRedirectDoesNotReplayCredentials() async throws {
        var sends = 0
        do {
            _ = try await Authenticator.authenticate(
                email: "fixture@example.test", password: "secret", code: "", cookies: [],
                guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                    sends += 1
                    return HTTPClient.Response(host: "buy.itunes.apple.com", status: .seeOther, version: .http1_1,
                                               headers: ["Location": self.endpoint.absoluteString], body: nil)
                }
            )
            XCTFail("A 303 requests a GET and cannot replay the signed POST")
        } catch {
            XCTAssertEqual(sends, 1)
        }
    }

    func testTransientTransportFailuresReplayTheSameSignedRequest() async throws {
        let errors: [Error] = [
            HTTPClientError.connectTimeout, HTTPClientError.readTimeout,
            HTTPClientError.remoteConnectionClosed, HTTPClientError.deadlineExceeded,
            HTTPClientError.uncleanShutdown, ChannelError.eof,
            ChannelError.connectTimeout(.seconds(10)),
            IOError(errnoCode: POSIXErrorCode.ECONNRESET.rawValue, reason: "fixture reset"),
            IOError(errnoCode: POSIXErrorCode.EPIPE.rawValue, reason: "fixture pipe"),
        ]
        for error in errors {
            var signedBodies: [Data] = []
            var sentBodies: [Data] = []
            var delays: [Double] = []
            _ = try await Authenticator.authenticate(
                email: "fixture@example.test", password: "secret", code: "", cookies: [],
                guid: "001122334455", bag: bag(), sign: { bytes, _ in
                    signedBodies.append(bytes)
                    return Data([UInt8(signedBodies.count)])
                }, send: { request in
                    XCTAssertEqual(request.headers.first(name: "X-Apple-ActionSignature"), Data([UInt8(sentBodies.count + 1)]).base64EncodedString())
                    sentBodies.append(try await self.bodyData(request))
                    if sentBodies.count == 1 { throw error }
                    return try self.success()
                }, sleep: { delays.append($0) }
            )
            XCTAssertEqual(signedBodies.count, 2)
            XCTAssertEqual(signedBodies.first, signedBodies.last)
            XCTAssertEqual(sentBodies, [signedBodies[0], signedBodies[0]])
            XCTAssertEqual(delays, [10])
        }
    }

    func testMixedTransportAndHTTPFailuresShareRetryLimit() async throws {
        var sends = 0
        var delays: [Double] = []
        _ = try await Authenticator.authenticate(
            email: "fixture@example.test", password: "secret", code: "", cookies: [],
            guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                sends += 1
                if sends == 1 { throw HTTPClientError.remoteConnectionClosed }
                if sends == 2 {
                    return HTTPClient.Response(host: "buy.itunes.apple.com", status: .serviceUnavailable,
                                               version: .http1_1, headers: ["Retry-After": "2"], body: nil)
                }
                return try self.success()
            }, sleep: { delays.append($0) }
        )
        XCTAssertEqual(sends, 3)
        XCTAssertEqual(delays, [10, 2])
    }

    func testTransportRetriesAreBoundedAndDoNotExposeRequestDetails() async throws {
        var sends = 0
        var delays: [Double] = []
        do {
            _ = try await Authenticator.authenticate(
                email: "fixture@example.test", password: "secret", code: "", cookies: [],
                guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                    sends += 1
                    throw IOError(errnoCode: POSIXErrorCode.ECONNRESET.rawValue, reason: "secret")
                }, sleep: { delays.append($0) }
            )
            XCTFail("Expected retry exhaustion")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("secret"))
            XCTAssertEqual(sends, 3)
            XCTAssertEqual(delays, [10, 20])
        }
    }

    func testCancellationAndPermanentTransportErrorsDoNotRetry() async throws {
        let errors: [Error] = [CancellationError(), HTTPClientError.cancelled, HTTPClientError.invalidURL]
        for error in errors {
            var sends = 0
            do {
                _ = try await Authenticator.authenticate(
                    email: "fixture@example.test", password: "secret", code: "", cookies: [],
                    guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                        sends += 1
                        throw error
                    }, sleep: { _ in XCTFail("Must not delay or retry") }
                )
                XCTFail("Expected transport error")
            } catch let result {
                XCTAssertEqual(sends, 1)
                XCTAssertEqual(result is CancellationError, error is CancellationError || (error as? HTTPClientError) == .cancelled)
            }
        }
    }

    func testStructuredCredentialFailureIsNotRetriedEvenOnHTTP503() async throws {
        var sends = 0
        do {
            _ = try await Authenticator.authenticate(
                email: "fixture@example.test", password: "secret", code: "", cookies: [],
                guid: "001122334455", bag: bag(), sign: { _, _ in Data([1]) }, send: { _ in
                    sends += 1
                    return try self.response(["failureType": "5005"], status: .serviceUnavailable)
                }, sleep: { _ in XCTFail("Credential failures must not retry") }
            )
            XCTFail("Expected invalid verification code")
        } catch {
            XCTAssertEqual(error.localizedDescription, Strings.invalid2FACode)
            XCTAssertEqual(sends, 1)
        }
    }

    func testRetryKeepsSessionCookiesThroughPodRedirect() async throws {
        var sends = 0
        var signatures = 0
        let account = try await Authenticator.authenticate(
            email: "fixture@example.test", password: "secret", code: "", cookies: [],
            guid: "001122334455", bag: bag(), sign: { _, _ in
                signatures += 1
                return Data([1])
            }, send: { request in
                sends += 1
                switch sends {
                case 1:
                    // Empty error fields are not a populated credential error.
                    return try self.response(["failureType": "", "customerMessage": ""], status: .serviceUnavailable,
                                             headers: ["Set-Cookie": "session=retry; Domain=.itunes.apple.com; Path=/; Secure"])
                case 2:
                    XCTAssertEqual(request.headers.first(name: "Cookie"), "session=retry")
                    return HTTPClient.Response(host: "buy.itunes.apple.com", status: .found, version: .http1_1,
                                               headers: ["Location": "https://p25-buy.itunes.apple.com" + AuthenticationProtocol.path + "/",
                                                         "Set-Cookie": "hostOnly=original; Path=/; Secure"], body: nil)
                default:
                    XCTAssertEqual(sends, 3)
                    XCTAssertEqual(request.url.host, "p25-buy.itunes.apple.com")
                    XCTAssertEqual(request.headers.first(name: "Cookie"), "session=retry")
                    return try self.success()
                }
            }, sleep: { XCTAssertEqual($0, 10) }
        )
        XCTAssertEqual(signatures, 3)
        XCTAssertEqual(sends, 3)
        XCTAssertEqual(account.cookie.first { $0.name == "hostOnly" }?.domain, "buy.itunes.apple.com")
    }

    func testCookieMergeRetainsDomainAndPathScopes() throws {
        var cookies = [
            Cookie(name: "session", value: "pod", path: "/", domain: "p25-buy.itunes.apple.com", httpOnly: true, secure: true),
            Cookie(name: "session", value: "auth", path: AuthenticationProtocol.path, domain: ".itunes.apple.com", httpOnly: true, secure: true),
        ]
        let headers: HTTPHeaders = ["Set-Cookie": "session=dispatch; Path=/; Secure"]
        let response = HTTPClient.Response(host: "downloaddispatch.itunes.apple.com", status: .ok,
                                           version: .http1_1, headers: headers, body: nil)
        cookies.mergeCookies(response.cookies, origin: URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload")!)
        XCTAssertEqual(cookies.count, 3)
        XCTAssertEqual(cookies.buildCookieHeader(URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload")!).first?.1, "session=dispatch")
        XCTAssertEqual(cookies.buildCookieHeader(URL(string: "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!).first?.1, "session=pod")
        cookies.mergeCookies(response.cookies, origin: URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload")!)
        XCTAssertEqual(cookies.count, 3)
    }

    func testRetrySignerFailureStopsBeforeAnotherSend() async throws {
        var signatures = 0
        var sends = 0
        do {
            _ = try await Authenticator.authenticate(
                email: "fixture@example.test", password: "secret", code: "", cookies: [],
                guid: "001122334455", bag: bag(), sign: { _, _ in
                    signatures += 1
                    if signatures > 1 { throw HTTPClientError.readTimeout }
                    return Data([1])
                }, send: { _ in
                    sends += 1
                    return HTTPClient.Response(host: "buy.itunes.apple.com", status: .serviceUnavailable,
                                               version: .http1_1, headers: [:], body: nil)
                }, sleep: { XCTAssertEqual($0, 10) }
            )
            XCTFail("Expected signer failure")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .readTimeout)
            XCTAssertEqual(signatures, 2)
            XCTAssertEqual(sends, 1)
        }
    }

    private func bodyData(_ request: HTTPClient.Request) async throws -> Data {
        var data = Data()
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try await request.body?.stream(.init { chunk in
            if case let .byteBuffer(buffer) = chunk {
                data.append(contentsOf: buffer.readableBytesView)
            } else {
                XCTFail("Unexpected file body")
            }
            return loop.makeSucceededVoidFuture()
        }).get()
        return data
    }
}
