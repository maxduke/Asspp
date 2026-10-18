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

    func testExplicitSetupFailuresRetainTheirStage() {
        for stage in ["iOS.certificate", "iOS.context-init", "iOS.engine-load", "iOS.engine-init", "iOS.exchange-request", "iOS.setup-request", "iOS.exchange-response"] {
            let failure = SAPSigner.operationError(stage: stage, cause: NSError(domain: "SSErrorDomain", code: 122))
            let message = SAPSigner.diagnosticError(failure).localizedDescription
            XCTAssertTrue(message.contains("\(stage); ApplePackage.SAP/2 -> SSErrorDomain/122"))
        }
    }

    func testDirectEngineFailuresPreserveOnlyAllowedNumericCodes() {
        for (stage, domain, code) in [
            ("iOS.engine-load", "ApplePackage.SAP.Symbols", 31),
            ("iOS.engine-init", "ApplePackage.SAP.Native", -42001),
            ("iOS.engine-init", "ApplePackage.SAP.Core", 4),
        ] {
            let failure = SAPSigner.operationError(stage: stage, cause: NSError(domain: domain, code: code, userInfo: [
                NSLocalizedDescriptionKey: "fixture-secret",
            ]))
            let message = SAPSigner.diagnosticError(failure).localizedDescription
            XCTAssertTrue(message.contains("\(stage); ApplePackage.SAP/2 -> \(domain)/\(code)"))
            XCTAssertFalse(message.contains("fixture-secret"))
        }
    }
    func testInterpreterFailuresExposeOnlyPhaseAndNumericStatus() {
        for stage in ["iOS.runtime.assets", "iOS.runtime.load", "iOS.runtime.initialize",
                      "iOS.runtime.certificate", "iOS.runtime.exchange-request", "iOS.runtime.setup",
                      "iOS.runtime.exchange-response", "iOS.runtime.ready", "iOS.runtime.sign",
                      "iOS.runtime.timeout", "iOS.runtime.input", "iOS.runtime.failure", "iOS.runtime.wait"] {
            let failure = SAPSigner.operationError(stage: stage, cause: NSError(
                domain: "ApplePackage.SAP.Runtime", code: -42001,
                userInfo: [NSLocalizedDescriptionKey: "fixture-secret", "body": "fixture-secret"]
            ))
            let message = SAPSigner.diagnosticError(failure).localizedDescription
            XCTAssertTrue(message.contains("\(stage); ApplePackage.SAP/2 -> ApplePackage.SAP.Runtime/-42001"))
            XCTAssertFalse(message.contains("fixture-secret"))
        }
    }

}
