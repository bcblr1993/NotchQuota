import AppKit

extension AppDelegate {
    func runSidebarTest() {
        Task { @MainActor in
            var failures = 0
            func check(_ value: Bool, _ label: String) {
                print("SIDEBAR \(label): \(value ? "PASS" : "FAIL")"); fflush(stdout); if !value { failures += 1 }
            }
            func wait(_ time: Double = 0.35) async { try? await Task.sleep(nanoseconds: UInt64(time * 1e9)) }
            @MainActor func capture(_ name: String, view: NSView) {
                guard let path = ProcessInfo.processInfo.environment["NOTCHQUOTA_SMOKE_DIR"],
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
            }
            setDisplayMode(.sidebar); await wait()
            guard let bar = sidebar else { check(false, "controller created"); exit(1) }
            check(bar.panel.isVisible && !panel.isVisible && quotaStatusItem == nil, "third mode owns only sidebar")
            check(bar.cells.count == visibleTargets.count && rotationTimer == nil, "selected accounts stay fixed without rotation timer")
            let requests = lastAttempt
            let first = visibleTargets[0].id, second = visibleTargets[1].id
            bar.hover(first); bar.leave(first); await wait()
            check(!bar.detail.isVisible && bar.hoverWork == nil, "brief pointer pass does not open detail")
            bar.hover(first); await wait()
            check(bar.detail.isVisible && overviewModel.accounts.first?.id == first, "delayed hover opens correct detail")
            bar.leave(first); bar.cancelClose(); await wait(0.6)
            check(bar.detail.isVisible, "moving into detail cancels close")
            bar.select(second, pin: true); await wait()
            bar.leave(second); bar.hover(first); await wait(0.6)
            check(bar.pinned && bar.selectedID == second, "pinned detail survives exit and hover on other accounts")
            bar.togglePin(); await wait(0.7)
            check(!bar.detail.isVisible && bar.clock == nil, "unpin and leave closes and stops clock")
            for i in 0..<24 { bar.hover(visibleTargets[i % visibleTargets.count].id); await wait(0.035) }
            bar.hover(first); await wait(0.6)
            check(bar.selectedID == first && bar.hoverWork == nil, "rapid switching settles on final target")
            check(lastAttempt == requests, "hover and pin never query credentials or network")
            for candidate in visibleTargets {
                bar.select(candidate.id, pin: false); await wait(0.4)
                let expected = NSRect(x: bar.right ? 0 : 8, y: 0, width: OverviewLayout.width, height: bar.detailSurface.bounds.height)
                check(bar.detailHost?.frame == expected, "detail hosting frame matches window after changing quota count")
            }
            let savedAntigravity = states[.antigravity]
            states[.antigravity]?.error = "网络请求失败，请检查系统代理"
            bar.select(QuotaTarget.antigravity.id, pin: false); updateSidebar(); await wait(0.4)
            check(bar.detailHost?.frame.height == bar.detailSurface.bounds.height && bar.detailHost?.frame.minY == 0,
                  "error notice resizes detail without cropping header")
            capture("sidebar-error-detail", view: bar.detailSurface)
            for index in 0..<20 {
                bar.select(visibleTargets[index % visibleTargets.count].id, pin: false); await wait(0.025)
            }
            bar.select(first, pin: false); await wait(0.4)
            check(bar.detailHost?.frame.height == bar.detailSurface.bounds.height && bar.detailHost?.frame.minY == 0,
                  "rapid varying-height switches settle without clipping")
            check(bar.cells.allSatisfy { $0.toolTip == nil }, "account tooltips cannot cover quota details")
            bar.dismiss(animated: true); await wait(0.05); bar.select(first, pin: false); await wait(0.4)
            // Wait for the render server to retire our transition; unrelated AppKit layer
            // animations are not evidence of a stale close operation.
            for _ in 0..<30 where bar.detailSurface.layer?.animation(forKey: "visibility") != nil { await wait(0.02) }
            check(bar.detail.isVisible && bar.detail.alphaValue == 1 && bar.closeWork == nil && bar.detailSurface.layer?.animation(forKey: "visibility") == nil,
                  "reopening during fade does not inherit old hide animation")
            states[.antigravity] = savedAntigravity

            capture("sidebar-strip", view: bar.surface); capture("sidebar-detail", view: bar.detailSurface)
            bar.dismiss(animated: false); await wait()
            check(bar.clock == nil && bar.closeWork == nil && bar.hoverWork == nil, "idle owns no sidebar timers or scheduled work")
            suppressMotion = true; updateSidebar(); bar.select(first, pin: false)
            check(bar.cells.allSatisfy { $0.artwork.animationKeys()?.isEmpty != false } && bar.detailSurface.layer?.animationKeys()?.isEmpty != false, "reduced motion disables animations")
            suppressMotion = false
            hideTemporarily(for: 900); await wait()
            check(!bar.panel.isVisible && !bar.detail.isVisible && recoveryItem != nil, "temporary hide keeps independent recovery")
            restoreTemporaryVisibility(); await wait()
            check(bar.panel.isVisible && !bar.detail.isVisible, "restore shows sidebar without opening details")
            refreshSuspended = true; updateSidebar(); scheduleRotation()
            check(!bar.panel.isVisible && bar.clock == nil && rotationTimer == nil, "sleep stops sidebar work")
            refreshSuspended = false; updateSidebar()
            check(bar.panel.isVisible, "wake restores sidebar")
            smokeInstalled = [.claude]; discoverInstalled(); updateSidebar()
            check(bar.cells.count == 1 && bar.panel.frame.height == 74, "one account shrinks strip")
            bar.select(visibleTargets[0].id, pin: true)
            smokeInstalled = []; discoverInstalled(); updateSidebar()
            check(!bar.panel.isVisible && !bar.detail.isVisible, "removing all accounts closes both windows")
            smokeInstalled = Provider.allCases; discoverInstalled(); updateSidebar()
            for screen in NSScreen.screens {
                bar.place(at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY), screen: screen)
                bar.exitBar(); bar.setCollapsed(true); await wait(0.4)
                check(screen.visibleFrame.contains(bar.panel.frame), "collapsed sidebar stays on explicitly selected physical display")
                bar.setCollapsed(false); await wait(0.4)
                bar.screenChanged(); updateSidebar()
                check(screen.visibleFrame.contains(bar.panel.frame), "expand and display refresh retain physical display binding")
                bar.select(first, pin: false); await wait(0.4)
                check(screen.visibleFrame.contains(bar.detail.frame), "account details remain on sidebar display")
                bar.dismiss(animated: false)
            }
            if let screen = NSScreen.main {
                bar.place(at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY), screen: screen)
                check(!bar.docked && abs(bar.panel.frame.midX - screen.visibleFrame.midX) < 1, "drag placement supports free floating position")
                bar.exitBar(); bar.scheduleIdleCollapse(after: 0.1); await wait(0.6)
                check(bar.collapsed && bar.panel.frame.width == 40 && bar.clock == nil && bar.idleWork == nil, "idle floating strip becomes quiet cute capsule")
                capture("sidebar-capsule", view: bar.surface)
                bar.enterBar(); await wait(0.5)
                check(!bar.collapsed && bar.panel.frame.width == 52, "pointer entry expands capsule")
                bar.select(first, pin: true); bar.exitBar(); bar.scheduleIdleCollapse(after: 0.1); await wait(0.5)
                check(!bar.collapsed && bar.pinned, "pinned detail prevents automatic folding")
                bar.dismiss(animated: false)
                bar.place(at: NSPoint(x: screen.visibleFrame.maxX - 10, y: screen.visibleFrame.midY), screen: screen)
                bar.exitBar(); bar.scheduleIdleCollapse(after: 0.1); await wait(0.6)
                check(bar.docked && bar.collapsed && bar.panel.frame.width == 18 && abs(bar.panel.frame.maxX - screen.visibleFrame.maxX) < 1, "edge docking leaves only slim handle")
                capture("sidebar-edge-handle", view: bar.surface)
                bar.setCollapsed(false); await wait(0.4)
                for i in 0..<10 { bar.setCollapsed(i % 2 == 0); await wait(0.04) }
                bar.setCollapsed(false); await wait(0.6)
                check(!bar.collapsed && bar.panel.frame.width == 52, "rapid fold reversal settles expanded")
                hideTemporarily(for: 900)
                check(bar.idleWork == nil && !bar.panel.isVisible, "temporary hide cancels folding work")
                restoreTemporaryVisibility()
            }
            setDisplayMode(.menuBar); await wait()
            check(!bar.panel.isVisible && !bar.detail.isVisible && quotaStatusItem != nil, "switching to menu mode removes sidebar")
            setDisplayMode(.island); await wait()
            check(panel.isVisible && !bar.panel.isVisible && quotaStatusItem == nil, "switching to island restores original UI")
            if CommandLine.arguments.contains("--benchmark") {
                instances = (1...4).map { AntigravityInstance(appPath: "/Fixtures/Extra\($0).app", credentialPath: "/Fixtures/extra\($0).json", name: "Antigravity \($0)") }
                enabledInstances = Set(instances.map(\.id))
                for instance in instances {
                    let candidate = QuotaTarget(provider: .antigravity, instance: instance)
                    states[candidate] = states[.antigravity]
                    accountNames[candidate.id] = "account@example.com"
                }
                discoverInstalled(); setDisplayMode(.sidebar); await wait(1)
                print("BENCH idle_start \(Date().timeIntervalSince1970)"); fflush(stdout)
                await wait(20)
                print("BENCH switching_start \(Date().timeIntervalSince1970)"); fflush(stdout)
                var durations: [Double] = []
                for i in 0..<120 {
                    let started = ProcessInfo.processInfo.systemUptime
                    bar.select(visibleTargets[i % visibleTargets.count].id, pin: false)
                    durations.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    await wait(0.18)
                }
                bar.dismiss(animated: false); bar.scheduleIdleCollapse(); await wait(1)
                print("BENCH idle_after_switching \(Date().timeIntervalSince1970)"); fflush(stdout)
                await wait(20)
                durations.sort()
                print("BENCH selection_main_thread_ms p50=\(durations[durations.count / 2]) p95=\(durations[Int(Double(durations.count) * 0.95)]) max=\(durations.last!)")
                check(bar.clock == nil && bar.hoverWork == nil && bar.closeWork == nil, "benchmark returns to zero sidebar work")
            }
            print("SIDEBAR COMPLETE: \(failures == 0 ? "PASS" : "FAIL")"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }
}
