import Foundation

// MARK: - History wire format
//
// Matches the Go agent's `GET /history` response exactly. The agent emits
// snake_case keys; we mirror that via explicit `CodingKeys` on every type
// (one approach applied consistently — we do NOT rely on the decoder's
// `keyDecodingStrategy` so decoding is independent of configuration).
//
// All types are `Sendable` so they cross actor boundaries safely. They are
// `nonisolated` because the project's default actor isolation is
// `MainActor` (via `SWIFT_DEFAULT_ACTOR_ISOLATION`) — without that,
// `Decodable` conformance would be pinned to MainActor and actors couldn't
// decode them.

/// Top-level response from `GET /history[?since=<ts>]`.
nonisolated struct HistoryResponse: Codable, Sendable {
    /// Unix-seconds timestamp of the newest sample in the server's ring.
    /// Use this verbatim as `since=<ts>` on the next poll for incremental
    /// delivery.
    let ts_end: Int64
    /// Sample cadence in seconds. Hard-coded to 1 at V1.
    let interval_s: Int
    /// Oldest-first. When `since` is set, only samples with `ts > since`.
    let samples: [HistorySample]
    /// Latest-tick scalars that don't belong in a time series (processes,
    /// filesystem usage, GPU names, uptime, …).
    let current: CurrentInfo
}

/// One per-second sample. Everything a graph needs; no bulky per-process
/// or per-filesystem data (those live in `CurrentInfo`).
nonisolated struct HistorySample: Codable, Sendable, Identifiable {
    let ts: Int64
    let cpu_pct: Double
    let cpu_per_core: [Double]
    let cpu_power_w: Double
    let cpu_temp_c: Double
    let mem_used: Int64
    let disk_read_bps: Int64
    let disk_write_bps: Int64
    let net_rx_bps: Int64
    let net_tx_bps: Int64
    /// Per-GPU slice, index-aligned with `CurrentInfo.gpus[i]`.
    let gpu: [GPUSample]

    var id: Int64 { ts }
}

nonisolated struct GPUSample: Codable, Sendable {
    let util_pct: Int
    let power_w: Double
    let temp_c: Double
    let mem_used: Int64
}

/// Non-time-series fields. Reports the latest tick's state but is not
/// part of the history ring itself.
nonisolated struct CurrentInfo: Codable, Sendable {
    let host: HostInfo
    let mem_total: Int64
    let disk_fs: [Filesystem]
    let procs_top: [ProcessInfo]
    /// Un-sliced process count on the host. Populated even when the
    /// server truncated `procs_top` via `?procs=N` — the client uses
    /// this for the "Show all (N)" label without a second request.
    let procs_total: Int
    let gpus: [GPUMeta]
    let net_iface: String
}

nonisolated struct HostInfo: Codable, Sendable {
    let uptime_s: Int64
    let load: [Double]
}

nonisolated struct Filesystem: Codable, Sendable, Identifiable {
    let mount: String
    let used: Int64
    let total: Int64
    var id: String { mount }
}

nonisolated struct GPUMeta: Codable, Sendable, Identifiable {
    let name: String
    let mem_total: Int64
    var id: String { name }
}

nonisolated struct ProcessInfo: Codable, Sendable, Identifiable {
    let pid: Int32
    let user: String
    let cpu_pct: Double
    let mem_rss: Int64
    let name: String
    let cmd: String

    var id: Int32 { pid }
}

// MARK: - Kill signal

/// Signal to deliver via `POST /processes/{pid}/kill`. Raw values are the
/// uppercase strings the agent expects in the request body.
enum KillSignal: String, Sendable {
    case term = "TERM"
    case kill = "KILL"
}
