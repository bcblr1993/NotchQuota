import AppKit
import ServiceManagement

enum LoginItemState: Equatable {
    case disabled, enabled, requiresApproval, unavailable
    var title: String { self == .requiresApproval ? "开机自动启动（待系统允许）" : "开机自动启动" }
    var checkmark: NSControl.StateValue {
        switch self { case .enabled: return .on; case .requiresApproval: return .mixed; default: return .off }
    }
    var shouldEnableOnToggle: Bool { self != .enabled && self != .requiresApproval }
    var label: String {
        switch self { case .disabled: return "disabled"; case .enabled: return "enabled"; case .requiresApproval: return "requiresApproval"; case .unavailable: return "unavailable" }
    }
}

@MainActor
enum LaunchAtLogin {
    static var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .disabled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    static func setEnabled(_ enabled: Bool) throws {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        let allowed = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        guard Bundle.main.bundleURL.pathExtension == "app", allowed.contains(folder) else {
            throw QuotaError.message("请先将 NotchQuota 放入 Applications 文件夹，再设置自动启动。")
        }
        if enabled {
            if state != .enabled && state != .requiresApproval { try SMAppService.mainApp.register() }
        } else if state == .enabled || state == .requiresApproval { try SMAppService.mainApp.unregister() }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
