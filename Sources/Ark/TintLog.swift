import Foundation

/// Temporary tracing for the sidebar page-tint pipeline, behind
/// `ARK_TINT_DEBUG=1`. Same pattern as the drag tracing that finally located
/// the drop-target bug: with screenshots unavailable, stderr is the only view in.
enum TintLog {
    static let on = ProcessInfo.processInfo.environment["ARK_TINT_DEBUG"] == "1"
    static func say(_ message: String) {
        guard on else { return }
        FileHandle.standardError.write("[tint] \(message)\n".data(using: .utf8)!)
    }
}
