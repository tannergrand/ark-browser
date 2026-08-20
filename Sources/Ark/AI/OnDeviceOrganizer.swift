import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tab grouping on Apple Intelligence's on-device model, via FoundationModels.
///
/// Strictly better than the Claude path for this particular job: it runs
/// locally, so **no tab titles or hostnames leave the Mac**, it costs nothing,
/// and it works offline. The tradeoff is a small context window and a smaller
/// model, so the tab set is capped and titles are truncated.
///
/// Requires macOS 26, Apple Silicon, and Apple Intelligence switched on — hence
/// the runtime availability check rather than assuming it works.
enum OnDeviceOrganizer {
    enum Availability: Equatable {
        case available
        case unavailable(String)
        case unsupportedOS

        var isAvailable: Bool { self == .available }

        var explanation: String {
            switch self {
            case .available:
                return "Apple Intelligence is ready — grouping runs on this Mac."
            case .unsupportedOS:
                return "Needs macOS 26 or later."
            case .unavailable(let reason):
                return "Apple Intelligence unavailable: \(reason)"
            }
        }
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(Self.describe(reason))
        @unknown default:
            return .unavailable("unknown state")
        }
        #else
        return .unsupportedOS
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        // Case names have shifted across seeds, so describe rather than switch
        // on them — a wrong case name is a build break for no benefit.
        let raw = String(describing: reason)
        switch raw {
        case let r where r.localizedCaseInsensitiveContains("notEnabled"):
            return "turn it on in System Settings ▸ Apple Intelligence & Siri"
        case let r where r.localizedCaseInsensitiveContains("notEligible"):
            return "this Mac isn't supported"
        case let r where r.localizedCaseInsensitiveContains("notReady"):
            return "the model is still downloading"
        default:
            return raw
        }
    }

    /// Structured output via `@Generable` would be nicer, but those macros need
    /// the FoundationModelsMacros compiler plugin, which ships with Xcode and
    /// not CommandLineTools. Asking for JSON and running it through
    /// `TabOrganizer.parse` reaches the same place — and that validator already
    /// rejects malformed or out-of-range output, which is the real risk.
    #endif

    struct OnDeviceError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    static func propose(tabs: [(id: UUID, title: String, host: String)]) async throws
        -> TabOrganizer.Proposal {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw OnDeviceError(detail: Availability.unsupportedOS.explanation)
        }
        guard case .available = availability else {
            throw OnDeviceError(detail: availability.explanation)
        }
        guard tabs.count >= 2 else {
            throw OnDeviceError(detail: "Need at least two tabs to group.")
        }

        // Cap the set: the on-device context window is much smaller than the API's.
        let capped = Array(tabs.prefix(TabOrganizer.onDeviceTabCap))
        let session = LanguageModelSession(instructions: TabOrganizer.instructions)
        let prompt = "Open tabs:\n" + TabOrganizer.listing(for: capped)
        let ids = capped.map(\.id)

        // A smaller model sometimes wraps or chats around the JSON. One retry
        // with a blunter instruction is cheaper than failing the whole action.
        for attempt in 0..<2 {
            let ask = attempt == 0
                ? prompt
                : prompt + "\n\nReply with ONLY the JSON object. No explanation."
            let reply = try await session.respond(to: ask)
            let proposal = TabOrganizer.parse(reply.content, tabs: ids)
            if !proposal.groups.isEmpty { return proposal }
        }
        throw OnDeviceError(detail: "Apple Intelligence didn't return a usable grouping.")
        #else
        throw OnDeviceError(detail: "FoundationModels isn't available in this build.")
        #endif
    }
}
