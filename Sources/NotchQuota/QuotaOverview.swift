import AppKit
import SwiftUI

/// A collapsed row shows one real quota group, never a synthesized minimum across models.
struct QuotaSummary {
    let group: String?
    let fiveHour: QuotaWindow?
    let weekly: QuotaWindow?
    init(_ windows: [QuotaWindow]) {
        let base = windows.filter { $0.label == "5 小时" || $0.label == "每周" }
        if !base.isEmpty {
            group = nil
            fiveHour = base.first { $0.label == "5 小时" }
            weekly = base.first { $0.label == "每周" }
        } else {
            let first = windows.first { $0.label.hasSuffix(" · 5 小时") || $0.label.hasSuffix(" · 每周") }
            let prefix = first.map { $0.label.components(separatedBy: " · ").dropLast().joined(separator: " · ") }
            group = prefix
            fiveHour = windows.first { $0.label == (prefix ?? "") + " · 5 小时" }
            weekly = windows.first { $0.label == (prefix ?? "") + " · 每周" }
        }
    }
    static func resetText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "未提供重置时间" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "等待刷新" }
        if seconds < 86400 {
            let minutes = max(1, Int(ceil(seconds / 60)))
            return minutes >= 60 ? "\(minutes / 60)时\(minutes % 60)分后" : "\(minutes)分钟后"
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d EEE HH:mm"
        return formatter.string(from: date)
    }
}

struct OverviewAccount: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let image: NSImage
    let state: DisplayState
}
@MainActor final class OverviewModel: ObservableObject {
    @Published var accounts: [OverviewAccount] = []
    @Published var now = Date()
    @Published var position = 1
    @Published var total = 1
    @Published var sidebarMode = false
    @Published var pinned = false
    var pin: () -> Void = {}
    var next: () -> Void = {}
    var refresh: () -> Void = {}
    var settings: () -> Void = {}
}

struct QuotaOverview: View {
    @ObservedObject var model: OverviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            if let account = model.accounts.first {
                HStack(spacing: 8) {
                    Button(action: model.sidebarMode ? model.pin : model.next) {
                        Image(nsImage: account.image).resizable().scaledToFit().frame(width: 20, height: 20)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.total < 2 && !model.sidebarMode)
                        .help(model.sidebarMode ? "固定或取消固定详情" : (model.total > 1 ? "点击切换下一个账号" : "当前只有一个账号"))
                        .accessibilityLabel(model.sidebarMode ? "固定或取消固定详情" : "切换账号")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if !account.subtitle.isEmpty {
                            Text(account.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(account.subtitle)
                        }
                    }
                    Spacer(minLength: 4)
                    if model.sidebarMode {
                        Button(action: model.pin) { Image(systemName: model.pinned ? "pin.fill" : "pin") }.help(model.pinned ? "取消固定" : "固定详情")
                    }
                    Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.help("刷新额度")
                    Button(action: model.settings) { Image(systemName: "gearshape") }.help("设置")
                }.buttonStyle(.borderless).font(.system(size: 12)).frame(minHeight: 32).padding(.horizontal, 12).padding(.vertical, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(account.state.snapshot?.windows ?? []) { window in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(window.label).font(.system(size: 11, weight: .medium)).lineLimit(1).help(window.label)
                                    Spacer()
                                    Text(window.remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color(nsColor: QuotaTint.color(window.remaining)))
                                }
                                HStack {
                                    GeometryReader { geometry in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.primary.opacity(0.10))
                                            Capsule().fill(Color(nsColor: QuotaTint.color(window.remaining)))
                                                .frame(width: geometry.size.width * CGFloat(min(100, max(0, window.remaining ?? 0))) / 100)
                                        }
                                    }.frame(height: 3)
                                    Text(QuotaSummary.resetText(window.reset, now: model.now))
                                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                                }
                            }.frame(height: 50)
                        }
                        if let error = account.state.error {
                            Text((account.state.snapshot == nil ? "" : "上次数据 · ") + error)
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
                        } else if account.state.stale {
                            Text("上次数据 · 等待更新").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                        } else if account.state.snapshot == nil {
                            Text(account.state.loading ? "正在读取…" : "等待读取额度").font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                    }.padding(.horizontal, 12).id(account.id).transition(.opacity)
                }
                Divider()
                HStack {
                    Text(model.sidebarMode ? (model.pinned ? "已固定 · 点击图钉取消" : "点击侧栏图标固定详情") : (model.total > 1 ? "点击头像切换 · \(model.position)/\(model.total)" : "当前账号"))
                    Spacer()
                    if let date = account.state.snapshot?.fetchedAt {
                        Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                Text("暂无显示的账号").foregroundStyle(.secondary).padding(24)
            }
        }
        .animation(reduceMotion || model.sidebarMode ? nil : .easeInOut(duration: 0.2), value: model.accounts.first?.id)
        .frame(width: OverviewLayout.width)
        .background {
            if model.sidebarMode {
                LinearGradient(colors: [Color(red: 0.085, green: 0.095, blue: 0.13), Color(red: 0.045, green: 0.05, blue: 0.065)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else { Color(nsColor: .windowBackgroundColor) }
        }
        .overlay {
            if model.sidebarMode {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5).allowsHitTesting(false)
            }
        }
    }
}
