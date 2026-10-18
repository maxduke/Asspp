import Foundation
import XCTest
@testable import ApplePackage

final class SAPHardwareIdentityTests: XCTestCase {
    func testLoginGUIDDecodesAsBytesRatherThanASCII() throws {
        XCTAssertEqual(try SAPSigner.hardwareID(forGUID: "001122334455"), Data([0, 17, 34, 51, 68, 85]))
        XCTAssertEqual(try SAPSigner.hardwareID(forGUID: "aaBBccDDeeFF"), Data([170, 187, 204, 221, 238, 255]))
        XCTAssertEqual(try SAPSigner.hardwareID(forGUID: "AB"), Data([171]))
        XCTAssertEqual(try SAPSigner.hardwareID(forGUID: String(repeating: "FF", count: 20)).count, 20)
        for invalid in ["", "0", "00112233445Z", "00:11:22:33:44:55", " 001122334455", "００１１２２３３４４５５", String(repeating: "AA", count: 21)] {
            XCTAssertThrowsError(try SAPSigner.hardwareID(forGUID: invalid))
        }
    }
}
