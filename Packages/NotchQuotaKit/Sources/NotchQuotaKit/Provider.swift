import Foundation

/// Shared by the macOS notch app, the iOS app and its widget extension.
public enum Provider: String, CaseIterable, Codable, Sendable {
    case codex, claude, antigravity

    public var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        }
    }
}
