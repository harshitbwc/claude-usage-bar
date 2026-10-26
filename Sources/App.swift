import SwiftUI
import ServiceManagement

// Claude's signature coral, used to fill the bars.
enum Claude {
    static let coral = Color(red: 0.851, green: 0.467, blue: 0.341)        // #D97757
    static let coralNS = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    static let danger = Color(red: 0.80, green: 0.25, blue: 0.20)
    static let dangerNS = NSColor(srgbRed: 0.80, green: 0.25, blue: 0.20, alpha: 1)
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var snapshot = UsageSnapshot()
    @Published var error: String? = nil
    @Published var lastUpdated: Date? = nil
    @Published var loading = false
    @Published var launchAtLogin = false

    // /api/oauth/usage is shared with Claude Code's own /usage and is rate-limited
    // per-account, so poll gently.
    static let pollInterval: TimeInterval = 300    // 5 minutes
    static let staleThreshold: TimeInterval = 90   // refresh-on-open only if older than this

    private var timer: Timer?
    private var started = false
    private var inFlight = false
    private var backoffUntil: Date?
    private var consecutive429 = 0

    func start() {
        guard !started else { return }   // idempotent — never stack timers
        started = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Log.write("app start — polling every \(Int(Self.pollInterval))s")
        refresh(trigger: "start")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(trigger: "timer") }
        }
    }

    // Called when the popover opens — only fetches if data is stale.
    func refreshIfStale() {
        if let last = lastUpdated, Date().timeIntervalSince(last) < Self.staleThreshold { return }
        refresh(trigger: "open")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            Log.write("launch-at-login \(enabled ? "enabled" : "disabled")")
        } catch {
            Log.write("launch-at-login toggle failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refresh(trigger: String = "manual") {
        if let until = backoffUntil, Date() < until {
            Log.write("refresh (\(trigger)) skipped — backoff for \(Int(until.timeIntervalSinceNow))s more")
            return
        }
        guard !inFlight else {
            Log.write("refresh (\(trigger)) skipped — request already in flight")
            return
        }
        inFlight = true
        loading = true
        Task { @MainActor in
            defer { inFlight = false; loading = false }
            do {
                snapshot = try await UsageClient.fetchUsage()
                error = nil
                lastUpdated = Date()
                backoffUntil = nil
                consecutive429 = 0
            } catch let UsageError.rateLimited(retryAfter) {
                consecutive429 += 1
                // Exponential floor (60s, 120s, 240s … capped 15m); never below 60s
                // even if the server says Retry-After: 0.
                let floor = min(60.0 * pow(2.0, Double(consecutive429 - 1)), 900)
                let backoff = max(retryAfter ?? 0, floor)
                backoffUntil = Date().addingTimeInterval(backoff)
                error = "Rate limited — retrying in \(Int(backoff))s"
                Log.write("429 (\(trigger)) — backing off \(Int(backoff))s")
            } catch {
                self.error = (error as? UsageError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    var fiveHourPercent: Double { snapshot.fiveHour?.utilization ?? 0 }

    // The colored bar drawn directly in the menu bar (left → right fill).
    // Only show the ⚠ state if we have no data at all — a transient rate-limit
    // should keep displaying the last-good number.
    var menuBarImage: NSImage {
        let noData = snapshot.fiveHour == nil
        // Last-good number is kept on transient errors, but flag it so an old value
        // doesn't pass for a live one.
        let stale = !noData && error != nil
        return MenuBar.barImage(percent: fiveHourPercent, error: error != nil && noData, stale: stale)
    }
}

enum MenuBar {
    static func barImage(percent: Double, error: Bool, stale: Bool = false) -> NSImage {
        let w: CGFloat = 80, h: CGFloat = 13
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()

        let inset: CGFloat = 1
        let rect = NSRect(x: inset, y: inset, width: w - inset * 2, height: h - inset * 2)
        let radius = rect.height / 2

        // Track
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.secondaryLabelColor.withAlphaComponent(0.22).setFill()
        track.fill()

        // Fill
        let p = min(max(percent / 100, 0), 1)
        let fillW = rect.width * p
        if fillW > 0.5 {
            let fillRect = NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, fillW), height: rect.height)
            let clip = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            (error || stale ? NSColor.systemGray : (percent >= 90 ? Claude.dangerNS : Claude.coralNS)).setFill()
            clip.fill()
        }

        // Percentage label centered on the bar.
        let label = error ? "⚠" : "\(Int(percent.rounded()))%" + (stale ? " ⚠" : "")
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(
            in: NSRect(x: 0, y: (h - size.height) / 2, width: w, height: size.height),
            withAttributes: attrs)

        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Image(nsImage: model.menuBarImage)
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

struct PopoverView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(Claude.coral)
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            bar("5-hour limit", model.snapshot.fiveHour, emphasized: true)
            bar("Weekly (all)", model.snapshot.sevenDay)
            if model.snapshot.sevenDaySonnet != nil { bar("Weekly · Sonnet", model.snapshot.sevenDaySonnet) }
            if model.snapshot.sevenDayOpus != nil { bar("Weekly · Opus", model.snapshot.sevenDayOpus) }

            Divider()

            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )) {
                Text("Launch at login").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            HStack {
                Text(updatedText).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { model.refresh(trigger: "manual") }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { model.refreshIfStale() }
    }

    @ViewBuilder
    private func bar(_ title: String, _ window: LimitWindow?, emphasized: Bool = false) -> some View {
        let pct = window?.utilization ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(emphasized ? .subheadline.bold() : .subheadline)
                Spacer()
                Text("\(Int(pct.rounded()))%")
                    .font(emphasized ? .subheadline.bold() : .subheadline)
                    .monospacedDigit()
                    .foregroundStyle(pct >= 90 ? Claude.danger : Claude.coral)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(pct >= 90 ? Claude.danger : Claude.coral)
                        .frame(width: max(4, geo.size.width * min(pct / 100, 1)))
                }
            }
            .frame(height: emphasized ? 12 : 8)
            if let reset = window?.resetsAt {
                Text(resetText(reset)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func resetText(_ reset: Date) -> String {
        let remaining = reset.timeIntervalSinceNow
        if remaining <= 0 { return "resetting…" }
        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        if h >= 24 { return "resets in \(h / 24)d \(h % 24)h" }
        return "resets in \(h)h \(m)m"
    }

    private var updatedText: String {
        guard let u = model.lastUpdated else { return "—" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "updated \(f.string(from: u))"
    }
}
