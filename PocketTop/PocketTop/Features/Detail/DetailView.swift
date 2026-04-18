import SwiftUI

/// Stacked-scroll live dashboard for one server. Polls `/history` at 1 Hz
/// and displays four sections:
///
/// 1. Overview — rings for CPU / GPU / RAM / Disk I/O / Net + disk fill.
/// 2. Usage graphs — CPU (overall / per-core toggle), each GPU, RAM,
///    Disk I/O (read + write), Network (rx + tx).
/// 3. Power & Thermal — CPU watts + temp, per-GPU watts + temp.
/// 4. Processes — horizontally-scrollable table with tap-to-kill.
///
/// The client buffers samples returned by `/history` so the charts render
/// straight off `@State`. The server already caps the ring at 5 min, so
/// the client trim is just insurance against long sessions.
struct DetailView: View {
    let server: Server

    @Environment(\.scenePhase) private var scenePhase

    // MARK: Live state

    /// Ring of samples, oldest-first. Replaced on first poll, appended on
    /// subsequent polls.
    @State private var samples: [HistorySample] = []
    /// Most recent `current` block from the server. Used for processes,
    /// filesystem usage, GPU names, uptime.
    @State private var current: CurrentInfo?
    @State private var lastError: String?
    @State private var apiKey: String?
    @State private var keyMissing = false

    @State private var runToken = 0

    // MARK: Section state

    @State private var showPerCore = false
    @State private var sortColumn: ProcessTable.SortColumn = .cpu
    @State private var sortDescending = true
    @State private var killTarget: ProcessInfo?
    @State private var toast: ToastMessage?
    /// Detail view starts in "top 10" mode so each poll ships ~2 KB of
    /// process data instead of ~75 KB. Tapping "Show all N processes"
    /// flips this; the polling stream restarts with `procs=nil` (full
    /// list) via `runToken`.
    @State private var showingAllProcesses = false

    /// Trim the client buffer to this many entries (matches server ring).
    private static let maxSamples = 300

    /// Collapsed-view process count. `showingAllProcesses == false` asks
    /// the agent for only this many (via `?procs=N`), which keeps the
    /// steady-state payload small — tapping "Show all" expands to the
    /// full list.
    private static let collapsedProcessCount = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if keyMissing {
                    banner(
                        text: "No saved API key for this machine.",
                        systemImage: "key.slash"
                    )
                } else if let err = lastError {
                    banner(
                        text: "Couldn't reach machine (retrying…) — \(err)",
                        systemImage: "exclamationmark.triangle"
                    )
                }

                overviewSection
                usageSection
                powerThermalSection
                processSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: runToken) {
            await run()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                runToken &+= 1
            }
        }
        .confirmationDialog(
            killTarget.map { "Kill \($0.name) (PID \($0.pid))?" } ?? "",
            isPresented: Binding(
                get: { killTarget != nil },
                set: { if !$0 { killTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: killTarget
        ) { proc in
            Button("Terminate (SIGTERM)") {
                Task { await sendKill(proc: proc, signal: .term) }
            }
            Button("Force kill (SIGKILL)", role: .destructive) {
                Task { await sendKill(proc: proc, signal: .kill) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                ToastView(message: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast?.id)
    }

    // MARK: - Overview

    private var overviewSection: some View {
        SectionCard(title: "Overview", systemImage: "gauge.with.dots.needle.50percent") {
            VStack(alignment: .leading, spacing: 18) {
                // Rings grid — adaptive columns wrap to multiple rows on
                // narrow screens (e.g. 5+ rings on iPhone SE widths). Each
                // column is at least 64pt, at most 90pt; RingGauge scales
                // inside via aspectRatio.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 64, maximum: 90), spacing: 12)],
                    alignment: .center,
                    spacing: 16
                ) {
                    RingGauge(
                        label: "CPU",
                        fraction: (latest?.cpu_pct ?? 0) / 100,
                        value: formatPercent(latest?.cpu_pct ?? 0),
                        tint: .blue
                    )
                    ForEach(Array((current?.gpus ?? []).enumerated()), id: \.offset) { idx, meta in
                        RingGauge(
                            label: shortGPULabel(meta: meta, index: idx),
                            fraction: Double(latest?.gpu[safe: idx]?.util_pct ?? 0) / 100,
                            value: formatPercent(Double(latest?.gpu[safe: idx]?.util_pct ?? 0)),
                            tint: .green
                        )
                    }
                    RingGauge(
                        label: "RAM",
                        fraction: memFraction,
                        value: formatPercent(memFraction * 100),
                        tint: .purple
                    )
                    RingGauge(
                        label: "Disk I/O",
                        fraction: diskFraction,
                        value: formatBytesPerSecond(Int64((latest?.disk_read_bps ?? 0) + (latest?.disk_write_bps ?? 0))),
                        tint: .orange
                    )
                    RingGauge(
                        label: "Net",
                        fraction: netFraction,
                        value: formatBytesPerSecond(Int64((latest?.net_rx_bps ?? 0) + (latest?.net_tx_bps ?? 0))),
                        tint: .teal
                    )
                }

                // Storage: per-mount fill. Single-value (no graph) per the
                // Overview spec.
                if let fs = current?.disk_fs, !fs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Storage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(fs) { f in
                            diskFillRow(f)
                        }
                    }
                }

                if let host = current?.host {
                    HStack(spacing: 16) {
                        Text("Uptime \(formatUptime(seconds: host.uptime_s))")
                        if host.load.count >= 3 {
                            Text(String(format: "Load %.2f / %.2f / %.2f",
                                         host.load[0], host.load[1], host.load[2]))
                                .monospacedDigit()
                        }
                        if let iface = current?.net_iface, !iface.isEmpty {
                            Text("iface \(iface)").monospaced()
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func diskFillRow(_ fs: Filesystem) -> some View {
        let pct: Double = fs.total > 0 ? Double(fs.used) / Double(fs.total) : 0
        return HStack(spacing: 8) {
            Text(fs.mount)
                .font(.caption.monospaced())
                .frame(minWidth: 50, idealWidth: 80, maxWidth: 90, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: pct)
                .progressViewStyle(.linear)
                .frame(minWidth: 40)
            Text("\(formatBytes(fs.used)) / \(formatBytes(fs.total))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(formatPercent(pct * 100))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40, alignment: .trailing)
        }
    }

    // MARK: - Usage graphs

    private var usageSection: some View {
        SectionCard(
            title: "Usage",
            systemImage: "chart.xyaxis.line",
            accessory: {
                Picker("Mode", selection: $showPerCore) {
                    Text("Overall").tag(false)
                    Text("Cores").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        ) {
            VStack(alignment: .leading, spacing: 22) {
                labeledChart("CPU", trailing: formatPercent(latest?.cpu_pct ?? 0)) {
                    if showPerCore {
                        PerCoreChart(samples: samples)
                    } else {
                        TimelineChart(
                            samples: samples,
                            value: { $0.cpu_pct },
                            tint: .blue,
                            yDomain: 0 ... 100,
                            yLabel: { "\(Int($0))%" }
                        )
                    }
                }

                ForEach(Array((current?.gpus ?? []).enumerated()), id: \.offset) { idx, meta in
                    let util = Double(latest?.gpu[safe: idx]?.util_pct ?? 0)
                    labeledChart(meta.name, trailing: formatPercent(util)) {
                        TimelineChart(
                            samples: samples,
                            value: { Double($0.gpu[safe: idx]?.util_pct ?? 0) },
                            tint: .green,
                            yDomain: 0 ... 100,
                            yLabel: { "\(Int($0))%" }
                        )
                    }
                }

                labeledChart("RAM", trailing: formatPercent(memFraction * 100)) {
                    TimelineChart(
                        samples: samples,
                        value: { memoryPct(sample: $0) },
                        tint: .purple,
                        yDomain: 0 ... 100,
                        yLabel: { "\(Int($0))%" }
                    )
                }

                labeledChart(
                    "Disk I/O",
                    trailing: formatBytesPerSecond(Int64((latest?.disk_read_bps ?? 0) + (latest?.disk_write_bps ?? 0)))
                ) {
                    DualTimelineChart(
                        samples: samples,
                        seriesA: ("Read", .blue, { Double($0.disk_read_bps) }),
                        seriesB: ("Write", .orange, { Double($0.disk_write_bps) })
                    )
                }

                labeledChart(
                    "Network",
                    trailing: formatBytesPerSecond(Int64((latest?.net_rx_bps ?? 0) + (latest?.net_tx_bps ?? 0)))
                ) {
                    DualTimelineChart(
                        samples: samples,
                        seriesA: ("↓ Rx", .green, { Double($0.net_rx_bps) }),
                        seriesB: ("↑ Tx", .purple, { Double($0.net_tx_bps) })
                    )
                }
            }
        }
    }

    // MARK: - Power & thermal

    private var powerThermalSection: some View {
        SectionCard(title: "Power & Thermal", systemImage: "thermometer.medium") {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    labeledChart(
                        "CPU Watts",
                        trailing: formatWatts(latest?.cpu_power_w ?? 0)
                    ) {
                        TimelineChart(
                            samples: samples,
                            value: { $0.cpu_power_w },
                            tint: .orange,
                            yLabel: { String(format: "%.0fW", $0) }
                        )
                    }
                    labeledChart(
                        "CPU Temp",
                        trailing: formatCelsius(latest?.cpu_temp_c ?? 0)
                    ) {
                        TimelineChart(
                            samples: samples,
                            value: { $0.cpu_temp_c },
                            tint: .red,
                            yLabel: { String(format: "%.0f°", $0) }
                        )
                    }
                }

                ForEach(Array((current?.gpus ?? []).enumerated()), id: \.offset) { idx, meta in
                    HStack(alignment: .top, spacing: 14) {
                        labeledChart(
                            "\(gpuShort(meta.name)) Watts",
                            trailing: formatWatts(latest?.gpu[safe: idx]?.power_w ?? 0)
                        ) {
                            TimelineChart(
                                samples: samples,
                                value: { $0.gpu[safe: idx]?.power_w ?? 0 },
                                tint: .orange,
                                yLabel: { String(format: "%.0fW", $0) }
                            )
                        }
                        labeledChart(
                            "\(gpuShort(meta.name)) Temp",
                            trailing: formatCelsius(latest?.gpu[safe: idx]?.temp_c ?? 0)
                        ) {
                            TimelineChart(
                                samples: samples,
                                value: { $0.gpu[safe: idx]?.temp_c ?? 0 },
                                tint: .red,
                                yLabel: { String(format: "%.0f°", $0) }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Processes

    private var processSection: some View {
        SectionCard(title: "Processes", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .center, spacing: 10) {
                ProcessTable(
                    processes: sortedProcesses,
                    sortColumn: $sortColumn,
                    sortDescending: $sortDescending,
                    onTap: { proc in killTarget = proc }
                )
                processExpandControl
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var processExpandControl: some View {
        if let total = current?.procs_total,
           total > Self.collapsedProcessCount {
            Button {
                showingAllProcesses.toggle()
                // Restart the history stream with the new procs-limit.
                runToken &+= 1
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showingAllProcesses ? "chevron.up" : "chevron.down")
                        .font(.caption)
                    Text(showingAllProcesses
                         ? "Show top \(Self.collapsedProcessCount)"
                         : "Show all \(total) processes")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.bordered)
        }
    }

    private var sortedProcesses: [ProcessInfo] {
        let all = current?.procs_top ?? []
        let sorted: [ProcessInfo]
        switch sortColumn {
        case .pid:
            sorted = all.sorted { $0.pid < $1.pid }
        case .user:
            sorted = all.sorted { $0.user.localizedCaseInsensitiveCompare($1.user) == .orderedAscending }
        case .cpu:
            sorted = all.sorted { $0.cpu_pct < $1.cpu_pct }
        case .rss:
            sorted = all.sorted { $0.mem_rss < $1.mem_rss }
        case .name:
            sorted = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .cmd:
            sorted = all.sorted { $0.cmd.localizedCaseInsensitiveCompare($1.cmd) == .orderedAscending }
        }
        return sortDescending ? sorted.reversed() : sorted
    }

    // MARK: - Computed helpers

    private var latest: HistorySample? { samples.last }

    private var memFraction: Double {
        guard let total = current?.mem_total, total > 0,
              let used = latest?.mem_used else { return 0 }
        return Double(used) / Double(total)
    }

    private func memoryPct(sample: HistorySample) -> Double {
        guard let total = current?.mem_total, total > 0 else { return 0 }
        return Double(sample.mem_used) / Double(total) * 100
    }

    /// Soft-cap disk I/O normalisation for the ring: 100 MB/s reads as 100 %.
    /// Good enough for a glance gauge; the actual graph below is authoritative.
    private var diskFraction: Double {
        let bps = Double((latest?.disk_read_bps ?? 0) + (latest?.disk_write_bps ?? 0))
        return min(1, bps / (100 * 1024 * 1024))
    }

    /// Soft-cap net normalisation: 125 MB/s ≈ 1 Gbps.
    private var netFraction: Double {
        let bps = Double((latest?.net_rx_bps ?? 0) + (latest?.net_tx_bps ?? 0))
        return min(1, bps / (125 * 1024 * 1024))
    }

    private func shortGPULabel(meta: GPUMeta, index: Int) -> String {
        let gpus = current?.gpus ?? []
        if gpus.count == 1 { return "GPU" }
        return "GPU \(index)"
    }

    /// Trim long GPU names for chart titles. "NVIDIA GeForce RTX 3070" →
    /// "RTX 3070".
    private func gpuShort(_ name: String) -> String {
        if let r = name.range(of: "GeForce ") {
            return String(name[r.upperBound...])
        }
        return name
    }

    // MARK: - Chart + banner chrome

    private func labeledChart<C: View>(
        _ title: String,
        trailing: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func banner(text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text).font(.footnote)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.4), lineWidth: 0.5))
        .foregroundStyle(.primary)
    }

    // MARK: - Polling

    private func run() async {
        if apiKey == nil {
            guard let loaded = KeychainService.load(
                key: .apiKey,
                account: server.id.uuidString
            ) else {
                keyMissing = true
                return
            }
            apiKey = loaded
        }
        guard let apiKey else { return }
        keyMissing = false

        let service = MetricsService(server: server, apiKey: apiKey)
        // Top-10 in the collapsed state; full list when the user has
        // expanded. Restart of this `.task` (via `runToken`) is what
        // swaps the limit mid-session — the stream itself is immutable
        // once started.
        let procsLimit: Int? = showingAllProcesses ? nil : Self.collapsedProcessCount
        let stream = service.historyStream(interval: .seconds(1), procsLimit: procsLimit)

        for await result in stream {
            if Task.isCancelled { break }
            switch result {
            case .success(let resp):
                apply(resp)
                lastError = nil
            case .failure(let error):
                lastError = shortDescription(of: error)
            }
        }
    }

    private func apply(_ resp: HistoryResponse) {
        current = resp.current

        // Append only samples we don't already have. First response after
        // a restart delivers the whole ring; subsequent responses deliver
        // just the new tail (server filters by `since`). We still guard
        // with a ts check in case the server didn't apply the filter.
        let lastTs = samples.last?.ts ?? 0
        let incoming = resp.samples.filter { $0.ts > lastTs }

        if samples.isEmpty {
            samples = resp.samples
        } else {
            samples.append(contentsOf: incoming)
        }

        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    // MARK: - Kill action

    private func sendKill(proc: ProcessInfo, signal: KillSignal) async {
        guard let apiKey else { return }
        let service = MetricsService(server: server, apiKey: apiKey)
        let signalName = signal == .term ? "SIGTERM" : "SIGKILL"
        let message: ToastMessage
        do {
            try await service.kill(pid: proc.pid, signal: signal)
            message = ToastMessage(
                id: UUID(),
                text: "Sent \(signalName) to PID \(proc.pid) (\(proc.name))",
                kind: .success
            )
        } catch {
            message = ToastMessage(
                id: UUID(),
                text: "Kill failed: \(shortDescription(of: error))",
                kind: .failure
            )
        }
        toast = message

        try? await Task.sleep(for: .seconds(2))
        if toast?.id == message.id { toast = nil }
    }

    // MARK: - Helpers

    private func shortDescription(of error: Error) -> String {
        if let metricsError = error as? MetricsError {
            switch metricsError {
            case .http(let status, _): return "HTTP \(status)"
            case .transport(let e): return e.localizedDescription
            case .decode: return "decode error"
            case .invalidResponse: return "invalid response"
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Safe array index

/// Bounds-safe subscript so chart closures don't crash if a stale sample
/// has fewer GPU entries than the current `gpus` array (e.g. during a
/// GPU hot-plug — edge case, but cheap insurance).
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Uptime

/// Formats a duration in seconds as "3d 4h 22m".
func formatUptime(seconds: Int64) -> String {
    let total = max(0, seconds)
    let days = total / 86_400
    let hours = (total % 86_400) / 3600
    let minutes = (total % 3600) / 60
    var parts: [String] = []
    if days > 0 { parts.append("\(days)d") }
    if hours > 0 || days > 0 { parts.append("\(hours)h") }
    parts.append("\(minutes)m")
    return parts.joined(separator: " ")
}

// MARK: - Toast

struct ToastMessage: Equatable {
    let id: UUID
    let text: String
    let kind: Kind
    enum Kind { case success, failure }
}

private struct ToastView: View {
    let message: ToastMessage
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.kind == .success
                  ? "checkmark.circle.fill"
                  : "xmark.octagon.fill")
            Text(message.text).font(.footnote).lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(
            Capsule().stroke(
                message.kind == .success ? Color.green.opacity(0.5) : Color.red.opacity(0.5),
                lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .shadow(radius: 6, y: 2)
    }
}
