import Foundation

/// Default search engine. Stored in UserDefaults because `BrowserTab.resolve`
/// is static and used from the command bar before any state is in scope.
enum SearchEngine: String, CaseIterable, Identifiable {
    case duckduckgo, google, brave, kagi, startpage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .google: return "Google"
        case .brave: return "Brave"
        case .kagi: return "Kagi"
        case .startpage: return "Startpage"
        }
    }

    var base: String {
        switch self {
        case .duckduckgo: return "https://duckduckgo.com/"
        case .google: return "https://www.google.com/search"
        case .brave: return "https://search.brave.com/search"
        case .kagi: return "https://kagi.com/search"
        case .startpage: return "https://www.startpage.com/sp/search"
        }
    }

    var homepage: URL {
        switch self {
        case .duckduckgo: return URL(string: "https://duckduckgo.com")!
        case .google: return URL(string: "https://www.google.com")!
        case .brave: return URL(string: "https://search.brave.com")!
        case .kagi: return URL(string: "https://kagi.com")!
        case .startpage: return URL(string: "https://www.startpage.com")!
        }
    }

    func url(for query: String) -> URL {
        var comps = URLComponents(string: base)!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        return comps.url ?? homepage
    }

    private static let key = "ark.searchEngine"

    static var current: SearchEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let engine = SearchEngine(rawValue: raw) else { return .duckduckgo }
            return engine
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
