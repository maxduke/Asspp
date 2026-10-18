import Foundation
import XCTest
@testable import ApplePackage

final class SAPDiagnosticTests: XCTestCase {
    func testPreservesFailureStageAndUnderlyingSystemCodes() {
        let network = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [
            NSLocalizedDescriptionKey: "fixture-password and request body",
            NSURLErrorFailingURLErrorKey: URL(string: "https://example.test/fixture-password")!,
        ])
        let store = NSError(domain: "SSErrorDomain", code: 16, userInfo: [NSUnderlyingErrorKey: network])
        let failure = NSError(domain: "ApplePackage.SAP", code: 2, userInfo: [
            "ApplePackageSAPStage": "iOS.sign", NSUnderlyingErrorKey: store,
        ])
        let message = SAPSigner.diagnosticError(failure).localizedDescription
        XCTAssertTrue(message.contains("iOS.sign"))
        XCTAssertTrue(message.contains("SSErrorDomain/16 -> NSURLErrorDomain/-1200"))
        XCTAssertFalse(message.contains("fixture-password"))
        XCTAssertFalse(message.contains("example.test"))
        XCTAssertFalse(message.contains("request body"))
    }

    func testUnknownMetadataCannotReachTheLoginError() {
        let failure = NSError(domain: "fixture-password", code: 7, userInfo: [
            "ApplePackageSAPStage": "fixture-password",
            NSLocalizedDescriptionKey: "fixture-password",
        ])
        let message = SAPSigner.diagnosticError(failure).localizedDescription
        XCTAssertTrue(message.contains("native.sign; System/7"))
        XCTAssertFalse(message.contains("fixture-password"))
    }

    func testErrorChainIsBounded() {
        var failure = NSError(domain: "SSErrorDomain", code: 0)
        for code in 1 ... 10 {
            failure = NSError(domain: "SSErrorDomain", code: code, userInfo: [NSUnderlyingErrorKey: failure])
        }
        let message = SAPSigner.diagnosticError(failure).localizedDescription
        XCTAssertTrue(message.contains("SSErrorDomain/10 -> SSErrorDomain/9 -> SSErrorDomain/8 -> SSErrorDomain/7"))
        XCTAssertFalse(message.contains("SSErrorDomain/6"))
    }

    func testTimeoutAndCapacityRemainDistinguishable() {
        for stage in ["native.timeout", "native.capacity"] {
            let failure = NSError(domain: "ApplePackage.SAP", code: 2, userInfo: ["ApplePackageSAPStage": stage])
            XCTAssertTrue(SAPSigner.diagnosticError(failure).localizedDescription.contains(stage))
        }
    }
}
