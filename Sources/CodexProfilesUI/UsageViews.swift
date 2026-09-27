import SwiftUI
import CodexProfilesCore

struct UsageCard: View {
    var state: UsageLoadState
    var now: Date = .now
    var onRefresh: () -> Void = {}

    var body: some View {
        Group {
            if let usage = state.usage {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("Remaining quota")
                            .font(.system(size: 11, weight: .semibold))
                        if state.isLoading {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer(minLength: 8)
                        if let plan = usage.planType {
                            Text(plan.localizedCapitalized)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }

                    if usage.severity == .exhausted {
                        Label("Limit reached — switch accounts to keep working", systemImage: "pause.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                    } else if usage.severity == .critical || usage.severity == .warning {
                        Label("Running low — another saved account is ready", systemImage: "exclamationmark.circle.fill")
                            .font(PanelDS.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if usage.windows.isEmpty {
                        Text(usage.compactLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                                UsageMeter(window: window, now: now)
                            }
                        }
                    }

                    if let error = state.error {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "wifi.exclamationmark")
                            Text("Showing last known usage. \(error)")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Retry", action: onRefresh)
                                .buttonStyle(.borderless)
                                .disabled(state.isLoading)
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    Text(liveText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                        .help(usage.fetchedAt.formatted(date: .abbreviated, time: .standard))

                    if usage.creditsBalance != nil || (usage.resetCredits ?? 0) > 0 {
                        HStack(spacing: 10) {
                            if let balance = usage.creditsBalance {
                                Label("\(balance) credits", systemImage: "creditcard")
                            }
                            if let credits = usage.resetCredits, credits > 0 {
                                Label(
                                    credits == 1 ? "1 reset credit" : "\(credits) reset credits",
                                    systemImage: "arrow.counterclockwise.circle"
                                )
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
            } else if state.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading usage…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if let error = state.error {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry", action: onRefresh)
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.medium))
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var liveText: String {
        guard let fetchedAt = state.usage?.fetchedAt else { return "" }
        let age = now.timeIntervalSince(fetchedAt)
        if age < 8 { return "Live" }
        if age < 60 { return "Updated \(max(1, Int(age)))s ago" }
        return "Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))"
    }
}

struct UsageMeter: View {
    var window: UsageWindow
    var now: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(expandedWindowLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                if let resetAt = window.resetAt, resetAt <= now {
                    Text("Reset due · refresh")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if let caption = window.resetCaption {
                    Text(caption)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(window.resetsIn.map { "Resets in \($0)" } ?? "")
                }
            }
            QuotaBar(progress: window.remainingPercent / 100, tint: tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var expandedWindowLabel: String {
        guard let seconds = window.windowSeconds else { return "Limit" }
        if abs(seconds - 18_000) <= 1_800 { return "5-hour" }
        if abs(seconds - 604_800) <= 86_400 { return "Weekly" }
        return window.label
    }

    private var label: String {
        if window.remainingPercent <= 0 { return "Limit reached" }
        return "\(window.remainingDisplay)% left"
    }

    private var accessibilitySummary: String {
        let reset = window.resetsIn.map { ", resets in \($0)" } ?? ""
        return "\(expandedWindowLabel) limit, \(label)\(reset)"
    }

    private var tint: Color {
        if window.remainingPercent <= 10 { return .red }
        if window.remainingPercent <= 25 { return .orange }
        return .green
    }
}

struct QuotaBar: View {
    var progress: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.72), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: barWidth(in: geo.size.width))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func barWidth(in availableWidth: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, progress))
        guard clamped > 0 else { return 0 }
        return max(3, availableWidth * CGFloat(clamped))
    }
}

struct UsageCompactLabel: View {
    var state: UsageLoadState?

    var body: some View {
        if let usage = state?.usage, !usage.windows.isEmpty {
            HStack(spacing: 6) {
                if state?.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(state?.error ?? "")
                }
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                        HStack(spacing: 5) {
                            Text("\(window.remainingDisplay)%")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(state?.error == nil ? color(for: window) : .secondary)
                                .frame(minWidth: 34, alignment: .trailing)
                            Text(window.label)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 20, alignment: .leading)
                        }
                    }
                }
                .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(usage.compactLine + (state?.error == nil ? " remaining" : ", last known usage"))
            .help(state?.error.map { "Last known usage. " + $0 } ?? "Remaining quota · updated \(usage.fetchedAt.formatted())")
        } else if state?.isLoading == true {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Loading usage")
        } else if let error = state?.error {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help(error)
                .accessibilityLabel(error)
        }
    }

    private func color(for window: UsageWindow) -> Color {
        if window.remainingPercent <= 10 { return .red }
        if window.remainingPercent <= 25 { return .orange }
        return .secondary
    }
}
