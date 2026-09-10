import AppKit
import Sparkle

/// Sparkle owns scheduling, archive validation, installation and relaunch.
/// No separate polling loop or permanent helper process is introduced here.
@MainActor
final class AppUpdates: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    private(set) var availableVersion: String?
    var onChange: ((String?) -> Void)?
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }
    var automaticallyChecks: Bool { controller?.updater.automaticallyChecksForUpdates ?? false }
    var menuTitle: String { availableVersion.map { "更新至 \($0)…" } ?? "检查更新…" }

    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        controller.startUpdater()
    }
    func check() { controller?.checkForUpdates(nil) }
    func toggleAutomaticChecks() {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates.toggle()
    }
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // The notch badge is the noninterrupting reminder, even just after launch.
        false
    }
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            availableVersion = update.displayVersionString
            onChange?(availableVersion)
        }
    }
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            availableVersion = nil
            onChange?(nil)
        }
    }
}
