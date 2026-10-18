import Foundation
import ZIPFoundation

public enum PackagePlatformValidator {
    public static func ensurePackage(at url: URL, supports entityType: EntityType) throws {
        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive {
            // An embedded Watch/tvOS extension must not qualify the outer app.
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 3, components[0] == "Payload",
                  components[1].hasSuffix(".app"), components[2] == "Info.plist"
            else { continue }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            guard let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                try ensureFailed("Invalid app Info.plist in downloaded package")
            }
            try validate(info, supports: entityType)
            return
        }
        try ensureFailed("Downloaded package has no top-level app Info.plist")
    }

    static func validate(_ info: [String: Any], supports entityType: EntityType) throws {
        let expectedPlatform = entityType == .appleTV ? "AppleTVOS" : "iPhoneOS"
        // Old iOS releases predate this key. Only absence qualifies, not an
        // explicitly empty, malformed, or conflicting platform declaration.
        if info["CFBundleSupportedPlatforms"] == nil, entityType != .appleTV { return }
        guard let platforms = info["CFBundleSupportedPlatforms"] as? [String], platforms.contains(expectedPlatform) else {
            try ensureFailed("Downloaded package does not declare \(expectedPlatform) support")
        }
    }
}
