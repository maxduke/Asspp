import AppleSAPCore
import Foundation
import XCTest
@testable import ApplePackage

private final class SAPCoreFixture {
    static let lock = NSLock()
    static var current: SAPCoreFixture!

    var initializeStatus = 0
    var suppliesContext = true
    var exchangeStatus = 0
    var signStatus = 0
    var states = [1, 0]
    var firstOutput = Data([1, 2, 3])
    var finalOutput = Data()
    var signature = Data([9, 8, 7])
    var outputLengthOverride: UInt?
    var omitsOutputPointer = false
    var writes32BitOutputs = false
    var initialized = 0
    var hardware: [Data] = []
    var hardwarePadding: [Data] = []
    var exchanged: [Data] = []
    var signed: [Data] = []
    var disposed = 0
    var tornDown = 0

    func recordHardware(_ value: UnsafePointer<APSAPHardwareInfo>?) {
        guard let value else { return XCTFail("Missing native hardware block") }
        withUnsafeBytes(of: value.pointee.bytes) { buffer in
            hardware.append(Data(buffer.prefix(Int(value.pointee.length))))
            hardwarePadding.append(Data(buffer.dropFirst(Int(value.pointee.length))))
        }
    }

    func output(_ data: Data, pointer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?, length: UnsafeMutablePointer<UInt>?) {
        let count = outputLengthOverride ?? UInt(data.count)
        if writes32BitOutputs, let length {
            UnsafeMutableRawPointer(length).storeBytes(of: UInt32(count), as: UInt32.self)
        } else {
            length?.pointee = count
        }
        guard !omitsOutputPointer, !data.isEmpty else { return }
        let allocated = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
        data.withUnsafeBytes { bytes in allocated.copyMemory(from: bytes.baseAddress!, byteCount: data.count) }
        pointer?.pointee = allocated
    }

    var functions: APSAPCoreFunctions {
        var functions = APSAPCoreFunctions()
        functions.initialize = { context, hardware in
            let fixture = SAPCoreFixture.current!
            fixture.initialized += 1
            fixture.recordHardware(hardware)
            if fixture.suppliesContext { context?.pointee = Unmanaged.passUnretained(fixture).toOpaque() }
            return fixture.initializeStatus
        }
        functions.exchange = { version, hardware, context, input, length, output, outputLength, state in
            let fixture = SAPCoreFixture.current!
            XCTAssertEqual(version, 200)
            XCTAssertEqual(context, Unmanaged.passUnretained(fixture).toOpaque())
            fixture.recordHardware(hardware)
            let index = fixture.exchanged.count
            fixture.exchanged.append(Data(bytes: input!, count: Int(length)))
            let value = fixture.states[min(index, fixture.states.count - 1)]
            if fixture.writes32BitOutputs, let state {
                UnsafeMutableRawPointer(state).storeBytes(of: Int32(value), as: Int32.self)
            } else {
                state?.pointee = value
            }
            fixture.output(index == 0 ? fixture.firstOutput : fixture.finalOutput, pointer: output, length: outputLength)
            return fixture.exchangeStatus
        }
        functions.sign = { context, input, length, output, outputLength in
            let fixture = SAPCoreFixture.current!
            XCTAssertEqual(context, Unmanaged.passUnretained(fixture).toOpaque())
            fixture.signed.append(Data(bytes: input!, count: Int(length)))
            fixture.output(fixture.signature, pointer: output, length: outputLength)
            return fixture.signStatus
        }
        functions.teardown = { context in
            let fixture = SAPCoreFixture.current!
            XCTAssertEqual(context, Unmanaged.passUnretained(fixture).toOpaque())
            fixture.tornDown += 1
            return 0
        }
        functions.dispose = { pointer in
            SAPCoreFixture.current.disposed += 1
            pointer?.deallocate()
            return 0
        }
        return functions
    }
}

final class SAPCoreTests: XCTestCase {
    private var fixture: SAPCoreFixture!
    private let identity = Data([0, 17, 34, 51, 68, 85])

    override func setUp() {
        SAPCoreFixture.lock.lock()
        fixture = SAPCoreFixture()
        SAPCoreFixture.current = fixture
    }

    override func tearDown() {
        SAPCoreFixture.current = nil
        fixture = nil
        SAPCoreFixture.lock.unlock()
    }

    private func create() throws -> OpaquePointer {
        var functions = fixture.functions
        var result = APSAPCoreResult()
        let context = identity.withUnsafeBytes { bytes in
            APSAPCoreCreate(&functions, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &result)
        }
        XCTAssertEqual(result.error, APSAPCoreErrorNone)
        return try XCTUnwrap(context)
    }

    private func exchange(_ context: OpaquePointer, bytes: Data = Data([4, 5])) -> APSAPCoreResult {
        var output = APSAPCoreOutput()
        defer { APSAPCoreReleaseOutput(context, &output) }
        return bytes.withUnsafeBytes { buffer in
            APSAPCoreExchange(context, buffer.baseAddress, buffer.count, &output)
        }
    }

    func testUsesSameBinaryGUIDAndZeroPaddedHardwareForEveryNativeCall() throws {
        var context: OpaquePointer? = try create()
        defer { APSAPCoreDestroy(&context) }
        XCTAssertEqual(MemoryLayout<APSAPHardwareInfo>.size, 24)
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorNone)
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorNone)
        XCTAssertEqual(fixture.hardware, [identity, identity, identity])
        for padding in fixture.hardwarePadding { XCTAssertTrue(padding.allSatisfy { $0 == 0 }) }
    }

    func testCompletedSetupWithNoFinalOutputSignsExactPayloadAndCleansUpOnce() throws {
        var context: OpaquePointer? = try create()
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorNone)
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorNone)
        let body = Data([0, 255, 38, 10, 128])
        var signature = APSAPCoreOutput()
        let result = body.withUnsafeBytes { APSAPCoreSign(context, $0.baseAddress, $0.count, &signature) }
        XCTAssertEqual(result.error, APSAPCoreErrorNone)
        XCTAssertEqual(fixture.signed, [body])
        XCTAssertEqual(Data(bytes: signature.bytes!, count: Int(signature.length)), fixture.signature)
        APSAPCoreReleaseOutput(context, &signature)
        APSAPCoreReleaseOutput(context, &signature)
        APSAPCoreDestroy(&context)
        APSAPCoreDestroy(&context)
        XCTAssertNil(context)
        XCTAssertEqual(fixture.disposed, 2)
        XCTAssertEqual(fixture.tornDown, 1)
    }

    func testMissingNativeContextIsRejectedEvenWhenInitializeReturnsSuccess() {
        fixture.suppliesContext = false
        var functions = fixture.functions
        var result = APSAPCoreResult()
        let context = identity.withUnsafeBytes {
            APSAPCoreCreate(&functions, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &result)
        }
        XCTAssertNil(context)
        XCTAssertEqual(result.error, APSAPCoreErrorMissingContext)
        XCTAssertTrue(fixture.exchanged.isEmpty)
        XCTAssertEqual(fixture.tornDown, 0)
    }

    func testOutputSlotsAlsoAcceptOlder32BitWrites() throws {
        fixture.writes32BitOutputs = true
        var context: OpaquePointer? = try create()
        defer { APSAPCoreDestroy(&context) }
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorNone)
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorNone)
        var output = APSAPCoreOutput()
        defer { APSAPCoreReleaseOutput(context, &output) }
        let result = identity.withUnsafeBytes { APSAPCoreSign(context, $0.baseAddress, $0.count, &output) }
        XCTAssertEqual(result.error, APSAPCoreErrorNone)
        XCTAssertEqual(output.length, UInt(fixture.signature.count))
    }

    func testZeroExtended32BitNativeFailureRetainsSignedErrorCode() {
        fixture.initializeStatus = Int(UInt32(bitPattern: -42001))
        var functions = fixture.functions
        var result = APSAPCoreResult()
        let context = identity.withUnsafeBytes {
            APSAPCoreCreate(&functions, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &result)
        }
        XCTAssertNil(context)
        XCTAssertEqual(result.error, APSAPCoreErrorNative)
        XCTAssertEqual(result.nativeStatus, -42001)
    }

    func testInitializationErrorPreservesNativeCodeAndDisposesPartialContext() {
        fixture.initializeStatus = -42001
        var functions = fixture.functions
        var result = APSAPCoreResult()
        let context = identity.withUnsafeBytes {
            APSAPCoreCreate(&functions, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &result)
        }
        XCTAssertNil(context)
        XCTAssertEqual(result.error, APSAPCoreErrorNative)
        XCTAssertEqual(result.nativeStatus, -42001)
        XCTAssertEqual(fixture.tornDown, 1)
    }

    func testAbsentEntryPointDoesNotInitialize() {
        var functions = fixture.functions
        functions.dispose = nil
        var result = APSAPCoreResult()
        let context = identity.withUnsafeBytes {
            APSAPCoreCreate(&functions, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &result)
        }
        XCTAssertNil(context)
        XCTAssertEqual(result.error, APSAPCoreErrorUnavailable)
        XCTAssertEqual(fixture.initialized, 0)
    }

    func testInvalidHardwareLengthDoesNotCallNativeInitializer() {
        for count in [0, 21] {
            var functions = fixture.functions
            var result = APSAPCoreResult()
            let context = Data(repeating: 1, count: count).withUnsafeBytes {
                APSAPCoreCreate(&functions, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &result)
            }
            XCTAssertNil(context)
            XCTAssertEqual(result.error, APSAPCoreErrorInvalidArgument)
        }
        XCTAssertEqual(fixture.initialized, 0)
    }

    func testSigningCannotBypassHandshakeOrReuseFailedSession() throws {
        var context: OpaquePointer? = try create()
        defer { APSAPCoreDestroy(&context) }
        var output = APSAPCoreOutput()
        let early = identity.withUnsafeBytes { APSAPCoreSign(context, $0.baseAddress, $0.count, &output) }
        XCTAssertEqual(early.error, APSAPCoreErrorInvalidState)
        fixture.states = [0]
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorInvalidState)
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorInvalidState)
        let failed = identity.withUnsafeBytes { APSAPCoreSign(context, $0.baseAddress, $0.count, &output) }
        XCTAssertEqual(failed.error, APSAPCoreErrorInvalidState)
        XCTAssertTrue(fixture.signed.isEmpty)
        XCTAssertEqual(fixture.exchanged.count, 1)
        XCTAssertEqual(fixture.disposed, 1)
    }

    func testIncompleteFinalExchangeIsRejected() throws {
        var context: OpaquePointer? = try create()
        defer { APSAPCoreDestroy(&context) }
        fixture.states = [1, 1]
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorNone)
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorInvalidState)
    }

    func testExchangeFailureReleasesNativeOutputAndPreservesStatus() throws {
        var context: OpaquePointer? = try create()
        defer { APSAPCoreDestroy(&context) }
        fixture.exchangeStatus = -42002
        let result = exchange(context!)
        XCTAssertEqual(result.error, APSAPCoreErrorNative)
        XCTAssertEqual(result.nativeStatus, -42002)
        XCTAssertEqual(fixture.disposed, 1)
    }

    func testOversizedNativeOutputIsNotRead() throws {
        var context: OpaquePointer? = try create()
        defer { APSAPCoreDestroy(&context) }
        fixture.outputLengthOverride = 1 << 30
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorInvalidOutput)
        XCTAssertEqual(fixture.disposed, 1)
    }

    func testMissingNativeOutputPointerIsRejected() throws {
        var context: OpaquePointer? = try create()
        defer { APSAPCoreDestroy(&context) }
        fixture.omitsOutputPointer = true
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorInvalidOutput)
    }

    func testSignFailureReleasesNativeOutputAndPreservesStatus() throws {
        var context: OpaquePointer? = try create()
        defer { APSAPCoreDestroy(&context) }
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorNone)
        XCTAssertEqual(exchange(context!).error, APSAPCoreErrorNone)
        fixture.signStatus = -42003
        var output = APSAPCoreOutput()
        let result = identity.withUnsafeBytes { APSAPCoreSign(context, $0.baseAddress, $0.count, &output) }
        XCTAssertEqual(result.error, APSAPCoreErrorNative)
        XCTAssertEqual(result.nativeStatus, -42003)
        XCTAssertNil(output.bytes)
        XCTAssertEqual(fixture.disposed, 2)
    }

    func testLoginGUIDDecodesAsBytesRatherThanASCII() throws {
        XCTAssertEqual(try SAPSigner.hardwareID(forGUID: "001122334455"), identity)
        XCTAssertEqual(try SAPSigner.hardwareID(forGUID: "aaBBccDDeeFF"), Data([170, 187, 204, 221, 238, 255]))
        XCTAssertEqual(try SAPSigner.hardwareID(forGUID: "AB"), Data([171]))
        XCTAssertEqual(try SAPSigner.hardwareID(forGUID: String(repeating: "FF", count: 20)).count, 20)
        for invalid in ["", "0", "00112233445Z", "00:11:22:33:44:55", " 001122334455", "００１１２２３３４４５５", String(repeating: "AA", count: 21)] {
            XCTAssertThrowsError(try SAPSigner.hardwareID(forGUID: invalid))
        }
    }
}
