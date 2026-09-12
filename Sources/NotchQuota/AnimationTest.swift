import AppKit
import QuartzCore

/// Explicit developer mode only: deterministic UI scenarios, no account/network access.
/// Timing and geometry assertions are NOT measurements of presented frames.
extension AppDelegate {
    func runAnimationTest() {
        Task { @MainActor in
            let origin = ProcessInfo.processInfo.systemUptime
            var failures = 0
            func event(_ name: String, passed: Bool? = nil) {
                var row: [String: Any] = ["event": name, "elapsed_s": ProcessInfo.processInfo.systemUptime - origin]
                if let passed { row["passed"] = passed; if !passed { failures += 1 } }
                if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self)); fflush(stdout)
                }
            }
            func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            event("start")
            event("motion_enabled", passed: motionDuration > 0)
            await wait(3)
            rest(); provider = .codex; updateView(); scheduleRotation()
            let requests = lastAttempt
            if !CommandLine.arguments.contains("--interactions-only") {
                event("natural_rotation_begin")
                // Let the real production timer fire, including its normal tolerance.
                for expected in [Provider.claude, .antigravity, .codex] {
                    let deadline = ProcessInfo.processInfo.systemUptime + 65
                    while provider != expected && ProcessInfo.processInfo.systemUptime < deadline { await wait(0.25) }
                    event("natural_rotation_\(expected.rawValue)", passed: provider == expected && !quotaView.expanded && !idle.active)
                }
                event("cached_rotation_no_requests", passed: lastAttempt == requests)
            }
            rotationTimer?.invalidate(); rotationTimer = nil
            event("interaction_begin")
            for index in 0..<12 {
                activity(); hoverWork?.cancel(); hoverWork = nil
                toggleExpanded(); await wait(0.08)
                event("expand_intermediate_\(index)", passed: panel.frame.height > topHeight)
                // Simulate arrival of a quota result while the panel is moving.
                states[target] = DisplayState(snapshot: Snapshot(windows: [.init(id: "fixture", label: "每周", remaining: Double(50 + index))]))
                updateView(animated: true)
                await wait(0.3)
                next(); await wait(0.45)
                toggleExpanded(); await wait(0.3)
                event("compact_\(index)", passed: abs(panel.frame.height - topHeight) < 1 && abs(panel.frame.maxY - (screen?.frame.maxY ?? 0)) < 1)
            }
            event("rapid_reversal_begin")
            for _ in 0..<16 { toggleExpanded(); await wait(0.06) }
            rest(); await wait(0.5)
            event("rapid_reversal_settles", passed: !quotaView.expanded && abs(panel.frame.height - topHeight) < 1)
            activity(); hoverWork?.cancel(); hoverWork = nil
            let before = provider
            rotateAutomatically(); event("interaction_blocks_rotation", passed: provider == before)
            rest(); refreshSuspended = true; scheduleRotation(); rotateAutomatically()
            event("sleep_blocks_rotation", passed: rotationTimer == nil && provider == before)
            refreshSuspended = false; scheduleRotation()
            event("wake_rearms_timer", passed: rotationTimer != nil)
            suppressMotion = true; next(); rest(); await wait(0.45)
            event("reduced_motion_no_transition", passed: quotaView.layer?.animation(forKey: "providerSwitch") == nil)
            smokeInstalled = [.claude]; discoverInstalled(); rotateAutomatically()
            event("one_provider_no_timer", passed: provider == .claude && rotationTimer == nil)
            smokeInstalled = []; discoverInstalled()
            event("no_provider_no_window", passed: !panel.isVisible && rotationTimer == nil)
            event("complete", passed: failures == 0)
            exit(failures == 0 ? 0 : 1)
        }
    }
}
