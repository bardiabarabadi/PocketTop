package metrics

import (
	"sync"
	"time"
)

// HistorySeconds is the retention window for the ring buffer. One entry
// per second × 300 seconds = 5 minutes, matching the iOS graph range.
const HistorySeconds = 300

// HistoryPoint is one second's worth of graphed metrics. Everything a
// chart needs; none of the bulky per-process / per-filesystem data (those
// live in Current and are refreshed each request from live state).
type HistoryPoint struct {
	Ts           int64      `json:"ts"` // Unix seconds
	CPUPct       float64    `json:"cpu_pct"`
	CPUPerCore   []float64  `json:"cpu_per_core"`
	CPUPowerW    float64    `json:"cpu_power_w"`
	CPUTempC     float64    `json:"cpu_temp_c"`
	MemUsed      uint64     `json:"mem_used"`
	DiskReadBps  uint64     `json:"disk_read_bps"`
	DiskWriteBps uint64     `json:"disk_write_bps"`
	NetRxBps     uint64     `json:"net_rx_bps"`
	NetTxBps     uint64     `json:"net_tx_bps"`
	GPU          []GPUPoint `json:"gpu"`
}

// GPUPoint is the per-tick slice of one GPU's state. Index-aligned with
// the Current.GPUs meta array so the client can match name/mem_total from
// Current to each HistoryPoint.GPU[i].
type GPUPoint struct {
	UtilPct int     `json:"util_pct"`
	PowerW  float64 `json:"power_w"`
	TempC   float64 `json:"temp_c"`
	MemUsed uint64  `json:"mem_used"`
}

// GPUMeta is the current-only view of a GPU (the fields that don't change
// across ticks — name, total memory). Sits in Current, not HistoryPoint.
type GPUMeta struct {
	Name     string `json:"name"`
	MemTotal uint64 `json:"mem_total"`
}

// Current is the "latest tick + not-a-time-series" block returned alongside
// samples on every /history response.
type Current struct {
	Host     HostInfo  `json:"host"`
	MemTotal uint64    `json:"mem_total"`
	DiskFS   []FS      `json:"disk_fs"`
	ProcsTop []Process `json:"procs_top"`
	// ProcsTotal is the un-sliced process count. Always populated, even
	// when the handler truncates ProcsTop via ?procs=N or brief=1, so
	// the client can render "Show all (N)" without a second round trip.
	ProcsTotal int       `json:"procs_total"`
	GPUs       []GPUMeta `json:"gpus"`
	NetIface   string    `json:"net_iface"`
}

// HistoryResponse is the shape of GET /history?since=ts. `Samples` is
// filtered to the post-`since` window when the query param is set; full
// ring otherwise.
type HistoryResponse struct {
	TsEnd     int64          `json:"ts_end"`
	IntervalS int            `json:"interval_s"`
	Samples   []HistoryPoint `json:"samples"`
	Current   Current        `json:"current"`
}

// HistoryRing is a fixed-capacity ring buffer of HistoryPoints, indexed by
// `Ts` (monotonic Unix seconds). Thread-safe.
type HistoryRing struct {
	mu    sync.RWMutex
	buf   []HistoryPoint
	head  int // write index (next slot to fill)
	count int // current number of valid entries (≤ cap)
}

func NewHistoryRing(capacity int) *HistoryRing {
	return &HistoryRing{buf: make([]HistoryPoint, capacity)}
}

func (r *HistoryRing) Push(p HistoryPoint) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.buf[r.head] = p
	r.head = (r.head + 1) % len(r.buf)
	if r.count < len(r.buf) {
		r.count++
	}
}

// Since returns points with `Ts > since`, oldest first. When `since <= 0`
// the full ring is returned (still oldest-first).
func (r *HistoryRing) Since(since int64) []HistoryPoint {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.count == 0 {
		return nil
	}
	// Oldest entry is at (head - count) mod cap.
	start := (r.head - r.count + len(r.buf)) % len(r.buf)
	out := make([]HistoryPoint, 0, r.count)
	for i := 0; i < r.count; i++ {
		p := r.buf[(start+i)%len(r.buf)]
		if p.Ts > since {
			out = append(out, p)
		}
	}
	return out
}

// LatestTs returns the ts of the newest entry, or 0 when empty.
func (r *HistoryRing) LatestTs() int64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.count == 0 {
		return 0
	}
	idx := (r.head - 1 + len(r.buf)) % len(r.buf)
	return r.buf[idx].Ts
}

// BuildHistoryPoint snapshots the sampler's cached rates + reads mem/gpu
// synchronously to assemble one HistoryPoint for "now". Called from the
// history goroutine at 1 Hz.
func BuildHistoryPoint(s *Sampler) HistoryPoint {
	cpuPct, perCore := s.CPUState()
	read, write := s.DiskBps()
	rx, tx, _ := s.NetBps()
	mem := ReadMem()
	gpus := ReadGPUs()
	cpuPowerW := s.CPUPowerW()
	cpuTempC := s.CPUTempC()

	gpuPoints := make([]GPUPoint, len(gpus))
	for i, g := range gpus {
		gpuPoints[i] = GPUPoint{
			UtilPct: g.UtilPct,
			PowerW:  g.PowerW,
			TempC:   g.TempC,
			MemUsed: g.MemUsed,
		}
	}

	return HistoryPoint{
		Ts:           time.Now().Unix(),
		CPUPct:       cpuPct,
		CPUPerCore:   perCore,
		CPUPowerW:    cpuPowerW,
		CPUTempC:     cpuTempC,
		MemUsed:      mem.Used,
		DiskReadBps:  read,
		DiskWriteBps: write,
		NetRxBps:     rx,
		NetTxBps:     tx,
		GPU:          gpuPoints,
	}
}

// BuildCurrent reads the live (non-time-series) fields that the client
// needs on every poll. Unlike HistoryPoint, this is a direct read — not
// part of the ring.
func BuildCurrent(s *Sampler) Current {
	mem := ReadMem()
	_, _, iface := s.NetBps()
	gpus := ReadGPUs()
	gpuMetas := make([]GPUMeta, len(gpus))
	for i, g := range gpus {
		gpuMetas[i] = GPUMeta{Name: g.Name, MemTotal: g.MemTotal}
	}
	procs := s.TopProcesses(0)
	return Current{
		Host:       HostInfo{UptimeS: Uptime(), Load: LoadAvg()},
		MemTotal:   mem.Total,
		DiskFS:     ReadFilesystems(),
		ProcsTop:   procs,
		ProcsTotal: len(procs),
		GPUs:       gpuMetas,
		NetIface:   iface,
	}
}
