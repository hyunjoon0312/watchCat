import Foundation

enum WebRecordUnit: String, CaseIterable {
    case domain
    case url
    case title

    static let userDefaultsKey = "watchCat.webRecordUnit"
    static let `default`: WebRecordUnit = .domain

    static func current() -> WebRecordUnit {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return WebRecordUnit(rawValue: raw) ?? .default
    }
}

enum WebRecordOptions {
    static let stripQueryKey = "watchCat.webStripQuery"
    static let recordIncognitoDomainKey = "watchCat.webRecordIncognitoDomain"

    /// SPEC §F3.3.2 — query stripping defaults to ON for privacy.
    static var stripQuery: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: stripQueryKey) as? Bool ?? true
    }

    /// SPEC §F3.5.1 — defaults to false; off-by-default privacy stance.
    static var recordIncognitoDomain: Bool {
        UserDefaults.standard.bool(forKey: recordIncognitoDomainKey)
    }
}

enum URLUtilities {
    static let incognitoBucket = "(시크릿 모드)"

    /// Lowercased registered host with a leading `www.` removed. Returns `nil` for
    /// anything that isn't a parseable http(s) URL — internal Chrome URLs like
    /// `chrome://newtab` or `about:blank` should not be treated as web traffic.
    static func domain(from raw: String) -> String? {
        guard let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else {
            return nil
        }
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }

    /// Returns the URL with its query string removed, preserving scheme/host/path/fragment.
    /// If the input can't be parsed, returns the original string unchanged.
    static func stripQuery(from raw: String) -> String {
        guard var comps = URLComponents(string: raw) else { return raw }
        comps.query = nil
        comps.queryItems = nil
        return comps.string ?? raw
    }

    /// Bucket key for aggregation given the active record unit and incognito state.
    /// Honors `WebRecordOptions.recordIncognitoDomain` to either expose the domain
    /// or collapse the row into a single "(시크릿 모드)" bucket.
    static func bucketKey(url: String, title: String, isIncognito: Bool,
                          unit: WebRecordUnit = .current(),
                          stripQuery: Bool = WebRecordOptions.stripQuery,
                          recordIncognitoDomain: Bool = WebRecordOptions.recordIncognitoDomain) -> String? {
        if isIncognito && !recordIncognitoDomain {
            return incognitoBucket
        }
        switch unit {
        case .domain:
            return domain(from: url)
        case .url:
            let normalized = stripQuery ? URLUtilities.stripQuery(from: url) : url
            return normalized.isEmpty ? nil : normalized
        case .title:
            return title.isEmpty ? nil : title
        }
    }
}
