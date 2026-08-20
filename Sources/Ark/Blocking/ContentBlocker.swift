import Foundation
import WebKit

/// Compiles a small ad/tracker rule set into a WKContentRuleList once, at
/// launch, and hands the compiled list to whichever tabs want it.
final class ContentBlocker {
    static let shared = ContentBlocker()

    private(set) var ruleList: WKContentRuleList?
    private(set) var ruleCount: Int = 0

    /// Third-party domains blocked outright.
    static let blockedDomains = [
        "doubleclick.net", "googleadservices.com", "googlesyndication.com",
        "googletagmanager.com", "googletagservices.com", "google-analytics.com",
        "adservice.google.com", "pagead2.googlesyndication.com",
        "facebook.net", "connect.facebook.net", "graph.facebook.com",
        "scorecardresearch.com", "quantserve.com", "quantcount.com",
        "adnxs.com", "adsrvr.org", "criteo.com", "criteo.net",
        "taboola.com", "outbrain.com", "zergnet.com",
        "amazon-adsystem.com", "adform.net", "rubiconproject.com",
        "pubmatic.com", "openx.net", "casalemedia.com", "sharethrough.com",
        "smartadserver.com", "teads.tv", "yieldmo.com", "indexww.com",
        "3lift.com", "bidswitch.net", "districtm.io", "gumgum.com",
        "mgid.com", "revcontent.com", "propellerads.com",
        "hotjar.com", "fullstory.com", "mouseflow.com", "luckyorange.com",
        "crazyegg.com", "inspectlet.com", "clarity.ms",
        "segment.io", "segment.com", "mixpanel.com", "amplitude.com",
        "heap.io", "heapanalytics.com", "kissmetrics.com", "chartbeat.com",
        "newrelic.com", "nr-data.net", "bugsnag.com",
        "branch.io", "appsflyer.com", "adjust.com", "kochava.com",
        "moatads.com", "doubleverify.com", "adsafeprotected.com",
        "bluekai.com", "demdex.net", "everesttech.net", "omtrdc.net",
        "krxd.net", "exelator.com", "eyeota.net", "tapad.com",
        "sitescout.com", "turn.com", "mathtag.com", "simpli.fi",
        "onetrust.com", "cookielaw.org", "trustarc.com",
        "zdbb.net", "zqtk.net", "servedbyadbutler.com"
    ]

    /// Cosmetic rules — collapse the empty frames left behind.
    static let hiddenSelectors = [
        "[id^='google_ads_']", "[id^='div-gpt-ad']", "ins.adsbygoogle",
        "iframe[src*='doubleclick.net']", "iframe[id^='google_ads_iframe']",
        ".ad-slot", ".ad-container", ".ad-wrapper", ".adsbox",
        ".taboola", "#taboola-below-article", ".OUTBRAIN",
        "[data-ad-slot]", "[aria-label='advertisement']"
    ]

    private init() {}

    func compile() async {
        let json = Self.rulesJSON()
        ruleCount = Self.blockedDomains.count + 1
        do {
            ruleList = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "ark-blocklist-v1", encodedContentRuleList: json)
        } catch {
            NSLog("Ark: rule list failed to compile — \(error.localizedDescription)")
        }
    }

    static func rulesJSON() -> String {
        var rules: [[String: Any]] = blockedDomains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?\(escaped)",
                    "load-type": ["third-party"]
                ],
                "action": ["type": "block"]
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")]
        ])
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(data: data, encoding: .utf8)!
    }
}
