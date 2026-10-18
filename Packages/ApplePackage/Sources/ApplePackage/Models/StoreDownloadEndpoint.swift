// Based on ApplePackage 1.2.7; endpoint recovery follows majd/ipatool.

import Foundation

/// The dispatch endpoints use a different version key from volumeStore.
/// Bag URLs are checked before any account credentials are sent to them.
enum StoreDownloadEndpoint: Equatable {
    case volumeStore
    case redownload(URL)
    case update(URL)

    static let retryableFailureType = "5002"

    var externalVersionIDKey: String {
        switch self {
        case .volumeStore: return "externalVersionId"
        case .redownload, .update: return "appExtVrsId"
        }
    }

    static func dispatch(_ url: URL, update: Bool = false) throws -> Self {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == "downloaddispatch.itunes.apple.com",
              components.port == nil,
              components.user == nil, components.password == nil,
              components.percentEncodedPath == (update ? "/up/updateProduct" : "/r/redownload"),
              components.query == nil, components.fragment == nil
        else {
            try ensureFailed("Invalid download endpoint in Apple's bag")
        }
        return update ? .update(url) : .redownload(url)
    }

    func url(pod: String?, deviceIdentifier: String?) throws -> URL {
        var components: URLComponents
        switch self {
        case .volumeStore:
            components = URLComponents()
            components.scheme = "https"
            // The generic buy host routes to the correct pod for fresh accounts.
            components.host = Configuration.purchaseAPIHost(pod: pod)
            components.path = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
        case let .redownload(url), let .update(url):
            guard let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                try ensureFailed("Invalid download URL")
            }
            components = parsed
        }
        if let deviceIdentifier {
            components.queryItems = [URLQueryItem(name: "guid", value: deviceIdentifier)]
        }
        return try components.url.get()
    }
}
