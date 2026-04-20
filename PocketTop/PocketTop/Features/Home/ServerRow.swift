import SwiftUI
import Charts

/// One glance tile in the Home list. Self-polls `/snapshot` every ~5s while
/// visible and feeds three mini-sparklines (CPU / Mem / Net total bps) plus
/// a red/amber/green status dot.
///
/// ### Sendability & Server
///
/// `Server` is a SwiftData `@Model` and under the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting it is not `Sendable`.
/// Views run on `@MainActor` by default, so reading `server.host` etc. in
/// the body and spawning the `.task` here is safe — but we do **not** let
/// the polling `Task` capture `Server` itself. We capture primitives into
/// local `let`s before the loop so Swift concurrency checking is happy.
///
/// `MetricsService.init(server:apiKey:)` reads `server`'s properties; per
/// Phase 8 we call it on MainActor (inside `.task { }`, which inherits the
/// view's isolation), then use the returned actor freely across `await`s.
///
/// ### Rolling buffer size
///
/// 300 samples at 1s resolution = 5 minutes — matches the agent's server-
/// side ring exactly. The first `/history` response after the row appears
/// delivers the full ring in one shot so the sparkline is pre-populated
/// (no more "starts empty and slowly fills"); subsequent 5s-cadence polls
/// append just the new tail since `lastTs`.
struct ServerRow: View {
    let server: Server

    // MARK: Live state

    @State private var latest: HistorySample?
    @State private var memTotal: Int64 = 0
    @State private var cpuHistory: [Double] = []
    @State private var memHistory: [Double] = []
    @State private var netHistory: [Double] = []
    @State private var lastErrorAt: Date?
    @State private var keyMissing: Bool = false

    private static let historyCap = 300

    var body: some View {
        HStack(spacing: 14) {
            StatusDot(color: statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(server.host):\(server.httpsPort)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if keyMissing {
                    Text("Not reachable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            // Three mini sparklines stacked vertically on the right. Swift
            // Charts' `LineMark` is sufficient here; nothing fancier earns
            // its complexity on a glance tile this small.
            VStack(spacing: 2) {
                Sparkline(values: cpuHistory, tint: .blue, label: "CPU")
                Sparkline(values: memHistory, tint: .purple, label: "Mem")
                Sparkline(values: netHistory, tint: .teal, label: "Net")
            }
            .frame(width: 96, height: 48)
        }
        .padding(.vertical, 6)
        .opacity(keyMissing ? 0.55 : 1)
        .task {
            await run()
        }
    }

    // MARK: - Polling lifecycle

    private func run() async {
        // Resolve the Bearer API key from the Keychain. Missing => grey out
        // the row and skip polling entirely (matches Phase 8 behaviour).
        guard let apiKey = KeychainService.load(
            key: .apiKey,
            account: server.id.uuidString
        ) else {
            keyMissing = true
            return
        }
        keyMissing = false

        // One-off poll every 5s with `brief=1`: Home tiles only consume
        // `mem_total` + the latest sample's CPU / mem / net rates, so we
        // ask the agent to omit the bulky collections (procs_top,
        // disk_fs, gpus) — drops the per-tile payload from ~75 KB to
        // ~3 KB.
        let service = MetricsService(server: server, apiKey: apiKey)
        var lastTs: Int64 = 0
        while !Task.isCancelled {
            do {
                let resp = try await service.history(since: lastTs, brief: true)
                apply(resp)
                if resp.ts_end > lastTs { lastTs = resp.ts_end }
                lastErrorAt = nil
            } catch {
                if lastErrorAt == nil { lastErrorAt = Date() }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func apply(_ resp: HistoryResponse) {
        memTotal = resp.current.mem_total
        guard !resp.samples.isEmpty else { return }
        latest = resp.samples.last

        // Consume every sample, not just the latest. The server filters
        // by `since`, so the first response delivers the whole 5-min ring
        // (sparkline pre-populated on open) and later responses deliver
        // only new samples — both produce the same append loop here.
        for sample in resp.samples {
            append(&cpuHistory, sample.cpu_pct)
            let memPct = memTotal > 0
                ? (Double(sample.mem_used) / Double(memTotal)) * 100.0
                : 0
            append(&memHistory, memPct)
            append(&netHistory, Double(sample.net_rx_bps + sample.net_tx_bps))
        }
    }

    private func append(_ buffer: inout [Double], _ value: Double) {
        buffer.append(value)
        if buffer.count > Self.historyCap {
            buffer.removeFirst(buffer.count - Self.historyCap)
        }
    }

    // MARK: - Status colour

    /// Derivation mirrors the Phase 8 rubric:
    /// - green: cpu.pct < 70 and memory used/total < 85 and no sustained error
    /// - amber: cpu.pct 70..<90 OR mem used/total > 85
    /// - red: cpu.pct >= 90 OR sustained fetch error (>15s)
    private var statusColor: Color {
        if let since = lastErrorAt, Date().timeIntervalSince(since) > 15 {
            return .red
        }
        guard let sample = latest else { return .gray }
        let cpu = sample.cpu_pct
        let memPct = memTotal > 0
            ? (Double(sample.mem_used) / Double(memTotal)) * 100.0
            : 0
        if cpu >= 90 { return .red }
        if cpu >= 70 || memPct > 85 { return .yellow }
        return .green
    }
}

// MARK: - Sparkline

/// A tiny horizontal sparkline backed by Swift Charts' `LineMark`. Y-axis is
/// autoscaled by Swift Charts on the live buffer — we intentionally don't
/// pin 0..100 on the percent series because the visual *delta* is what
/// matters at this zoom level; locking the scale would flatten a
/// 20%-to-25% twitch into nothing.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)

            if values.isEmpty {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.15))
            } else {
                Chart {
                    ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
                        LineMark(
                            x: .value("i", idx),
                            y: .value(label, v)
                        )
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartPlotStyle { plot in
                    plot.background(Color.clear)
                }
            }
        }
    }
}

private struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .overlay(
                Circle()
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            )
    }
}
