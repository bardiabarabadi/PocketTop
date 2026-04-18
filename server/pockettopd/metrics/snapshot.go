// Package metrics collects host metrics from /proc, /sys, and external
// tools (nvidia-smi) and assembles a History response for the /history
// endpoint.
//
// A Sampler goroutine refreshes rate-based metrics (CPU, disk, net,
// per-process CPU) every ~500ms and also feeds a 300-entry ring buffer at
// 1 Hz. HTTP handlers read cached state via the public accessors and
// never block on /proc parsing.
package metrics

// Common wire types shared between HistoryPoint, Current, and
// per-endpoint payloads.

// HostInfo carries uptime and load averages — cheap to read synchronously.
type HostInfo struct {
	UptimeS int64     `json:"uptime_s"`
	Load    []float64 `json:"load"` // 1/5/15 min
}

// CPUInfo is the latest CPU snapshot sliced out of the sampler. Power /
// temperature are 0 when the host lacks RAPL or a supported hwmon driver.
type CPUInfo struct {
	Pct     float64   `json:"pct"`
	PerCore []float64 `json:"per_core"`
	PowerW  float64   `json:"power_w"`
	TempC   float64   `json:"temp_c"`
}

type MemInfo struct {
	Total     uint64 `json:"total"`
	Used      uint64 `json:"used"`
	Available uint64 `json:"available"`
}

type DiskInfo struct {
	ReadBps  uint64 `json:"read_bps"`
	WriteBps uint64 `json:"write_bps"`
	FS       []FS   `json:"fs"`
}

type FS struct {
	Mount string `json:"mount"`
	Used  uint64 `json:"used"`
	Total uint64 `json:"total"`
}

type NetInfo struct {
	RxBps uint64 `json:"rx_bps"`
	TxBps uint64 `json:"tx_bps"`
	Iface string `json:"iface"`
}

// GPU is the per-tick view of one GPU. `PowerW` and `TempC` are 0 when
// the installed nvidia-smi doesn't expose them (very old drivers).
type GPU struct {
	Name     string  `json:"name"`
	UtilPct  int     `json:"util_pct"`
	MemUsed  uint64  `json:"mem_used"`
	MemTotal uint64  `json:"mem_total"`
	PowerW   float64 `json:"power_w"`
	TempC    float64 `json:"temp_c"`
}

type Process struct {
	PID    int     `json:"pid"`
	User   string  `json:"user"`
	CPUPct float64 `json:"cpu_pct"`
	MemRSS uint64  `json:"mem_rss"`
	Name   string  `json:"name"`
	Cmd    string  `json:"cmd"`
}

// TopN is the number of processes returned in procs_top.
const TopN = 20
