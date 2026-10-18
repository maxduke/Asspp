//
//  Logger.swift
//  ApplePackage
//
//  Created on 2026/2/20.
//

import Foundation
import Logging

public enum APLogger {
    public static var verbose: Bool = false

    private static var _logger: Logger = .init(label: "com.applepackage")

    public static var logger: Logger {
        get { _logger }
        set { _logger = newValue }
    }

    static func info(_ message: String) {
        _logger.info("\(message)")
    }

    static func debug(_ message: String) {
        guard verbose else { return }
        _logger.debug("\(message)")
    }

    static func error(_ message: String) {
        _logger.error("\(message)")
    }

    private static func isSensitiveHeader(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.contains("token") || name.contains("password") || name.contains("cookie") ||
            name == "authorization" || name == "x-apple-actionsignature"
    }

    static func logRequest(method: String, url: String, headers: [(String, String)] = []) {
        guard verbose else { return }
        var msg = ">>> \(method) \(url)"
        for (name, value) in headers {
            let safeValue = isSensitiveHeader(name) ? "<redacted>" : value
            msg += "\n    \(name): \(safeValue)"
        }
        debug(msg)
    }

    static func logResponse(status: UInt, headers: [(String, String)] = [], bodySize: Int? = nil) {
        guard verbose else { return }
        var msg = "<<< \(status)"
        if let bodySize = bodySize {
            msg += " (\(bodySize) bytes)"
        }
        for (name, value) in headers {
            let safeValue = isSensitiveHeader(name) ? "<redacted>" : value
            msg += "\n    \(name): \(safeValue)"
        }
        debug(msg)
    }
}
