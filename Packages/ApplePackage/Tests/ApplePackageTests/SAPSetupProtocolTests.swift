import Foundation
import XCTest
@testable import ApplePackage

final class SAPSetupProtocolTests: XCTestCase {
    private let bag: [String: Any] = [
        "sign-sap-setup-cert": "https://s.mzstatic.com/sap/setupCert.plist",
        "sign-sap-setup": "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy",
    ]

    private func response(_ values: [String: Any], binary: Bool = false) throws -> SAPSetupProtocol.Response {
        .init(status: .ok, body: try PropertyListSerialization.data(
            fromPropertyList: values, format: binary ? .binary : .xml, options: 0
        ))
    }

    func testCertificateRequestAndBinaryPlistMatchUpstreamContract() async throws {
        let expected = Data([1, 2, 3, 4])
        let certificate = try await SAPSetupProtocol.certificate(bag: bag) { request in
            XCTAssertEqual(request.url, self.bag["sign-sap-setup-cert"] as? String)
            XCTAssertEqual(request.method, .GET)
            XCTAssertNil(request.body)
            XCTAssertNil(request.headers.first(name: "Cookie"))
            XCTAssertNil(request.headers.first(name: "Authorization"))
            XCTAssertEqual(request.headers.first(name: "User-Agent"), Configuration.userAgent)
            return try self.response(["sign-sap-setup-cert": expected], binary: true)
        }
        XCTAssertEqual(certificate, expected)
    }

    func testSetupPostsOnlyNativeExchangeBufferAsPlistData() async throws {
        let nativeRequest = Data([0, 1, 255, 128, 0])
        let nativeReply = Data([6, 7, 8])
        let reply = try await SAPSetupProtocol.exchange(nativeRequest, bag: bag) { request in
            XCTAssertEqual(request.url, self.bag["sign-sap-setup"] as? String)
            XCTAssertEqual(request.method, .POST)
            XCTAssertEqual(request.headers.first(name: "Content-Type"), "application/x-plist")
            XCTAssertNil(request.headers.first(name: "Cookie"))
            XCTAssertNil(request.headers.first(name: "Authorization"))
            XCTAssertNil(request.headers.first(name: "X-Apple-ActionSignature"))
            let values = try AuthenticationProtocol.plist(from: XCTUnwrap(request.body))
            XCTAssertEqual(values.count, 1)
            XCTAssertEqual(values["sign-sap-setup-buffer"] as? Data, nativeRequest)
            return try self.response(["sign-sap-setup-buffer": nativeReply])
        }
        XCTAssertEqual(reply, nativeReply)
    }

    func testHTTPFailuresRetainStatusWithoutResponseDetails() async throws {
        for status in [301, 403, 503] {
            do {
                _ = try await SAPSetupProtocol.certificate(bag: bag) { _ in
                    .init(status: .init(statusCode: status), body: Data("fixture-secret".utf8))
                }
                XCTFail("HTTP failure must stop SAP setup")
            } catch {
                let failure = SAPSigner.operationError(stage: "iOS.certificate", cause: error)
                let message = SAPSigner.diagnosticError(failure).localizedDescription
                XCTAssertTrue(message.contains("iOS.certificate; ApplePackage.SAP/2 -> ApplePackage.SAP.HTTP/\(status)"))
                XCTAssertFalse(message.contains("fixture-secret"))
            }
        }
    }

    func testMissingEmptyAndWrongTypedCertificateAreRejected() async throws {
        for values: [String: Any] in [[:], ["sign-sap-setup-cert": Data()], ["sign-sap-setup-cert": "AQID"]] {
            do {
                _ = try await SAPSetupProtocol.certificate(bag: bag) { _ in try self.response(values) }
                XCTFail("A nonempty data certificate is required")
            } catch {
                XCTAssertEqual((error as NSError).domain, "ApplePackage.SAP")
                XCTAssertEqual((error as NSError).code, 3)
            }
        }
    }

    func testMalformedAndOversizedResponsesAreRejected() async throws {
        for body in [Data("<html>unavailable</html>".utf8), Data(repeating: 1, count: SAPSetupProtocol.maximumResponseSize + 1)] {
            do {
                _ = try await SAPSetupProtocol.certificate(bag: bag) { _ in .init(status: .ok, body: body) }
                XCTFail("Invalid setup response must not reach the native engine")
            } catch {
                XCTAssertEqual((error as NSError).code, 3)
            }
        }
    }

    func testInvalidNativeBufferDoesNotSendHTTPRequest() async throws {
        for buffer in [Data(), Data(repeating: 1, count: SAPSetupProtocol.maximumResponseSize + 1)] {
            do {
                _ = try await SAPSetupProtocol.exchange(buffer, bag: bag) { _ in
                    XCTFail("Invalid native buffer must not be sent")
                    return try self.response([:])
                }
                XCTFail("Invalid native buffer must fail")
            } catch {
                XCTAssertEqual((error as NSError).code, 3)
            }
        }
    }

    func testMissingAndEmptyServerExchangeBuffersAreRejected() async throws {
        for values: [String: Any] in [[:], ["sign-sap-setup-buffer": Data()], ["sign-sap-setup-buffer": "not-data"]] {
            do {
                _ = try await SAPSetupProtocol.exchange(Data([1]), bag: bag) { _ in try self.response(values) }
                XCTFail("A nonempty exchange reply is required")
            } catch {
                XCTAssertEqual((error as NSError).code, 3)
            }
        }
    }

    func testCancellationAfterCertificateFetchStopsSetup() async throws {
        let task = Task {
            try await SAPSetupProtocol.certificate(bag: bag) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return try self.response(["sign-sap-setup-cert": Data([1])])
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled setup must not initialize a native signing context")
        } catch is CancellationError {
        }
    }
}
