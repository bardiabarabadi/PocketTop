package metrics

import (
	"sync"
	"time"
)

// sampleInterval is how often the background goroutine refreshes all
// rate-based metrics (CPU, disk, net, per-process CPU).
const sampleInterval = 500 * time.Millisecond

// Sampler holds cached rate-based state updated by a background goroutine.
// All accessors take a read lock; the sampler loop takes a write lock when
// swapping snapshots in place.
type Sampler struct {
	mu sync.RWMutex

	// CPU
	lastCPUTotal cpuTimes
	lastCPUCores []cpuTimes
	cpuPct       float64
	cpuPerCore   []float64

	// Disk
	lastDisk    map[string]diskCounters
	diskRead    uint64
	diskWrite   uint64
	lastDiskAt  time.Time

	// Net
	lastNet    map[string]netCounters
	netRx      uint64
	netTx      uint64
	netIface   string
	lastNetAt  time.Time

	// Per-process CPU — scanned on alternating sampler ticks (see
	// `sampleCounter`), which halves the /proc/<pid>/* syscall rate.
	lastProcs   map[int]procCPUState
	lastProcsAt time.Time
	procCPUPct  map[int]float64

	// Monotonic tick counter; proc scan runs when this is even, giving
	// an effective 1 Hz enumeration rate while the other metrics (cpu,
	// disk, net, rapl, hwmon) remain at the 500 ms sampler cadence.
	sampleCounter uint64

	// CPU power (RAPL)
	rapl          raplPackage
	raplOK        bool
	lastEnergyUJ  uint64
	lastEnergyAt  time.Time
	cpuPowerW     float64

	// CPU temperature (hwmon)
	cpuTempSensor cpuTempSensor
	cpuTempOK     bool
	cpuTempC      float64

	// History ring (1 Hz).
	history *HistoryRing
}

// NewSampler returns a Sampler with empty caches. Call Start to launch the
// background goroutine.
func NewSampler() *Sampler {
	s := &Sampler{
		lastDisk:   map[string]diskCounters{},
		lastNet:    map[string]netCounters{},
		lastProcs:  map[int]procCPUState{},
		procCPUPct: map[int]float64{},
		history:    NewHistoryRing(HistorySeconds),
	}
	s.rapl, s.raplOK = findRAPLPackage()
	s.cpuTempSensor, s.cpuTempOK = findCPUTempSensor()
	return s
}

// Start launches the sampling goroutine. It runs forever; there is no
// stop method because the daemon's lifetime matches the process.
func (s *Sampler) Start() {
	// Prime the caches once synchronously so the first request returns
	// non-zero rates as soon as a second sample lands.
	s.sampleOnce()

	go func() {
		ticker := time.NewTicker(sampleInterval)
		defer ticker.Stop()
		for range ticker.C {
			s.sampleOnce()
		}
	}()

	// History feeder runs on its own 1 Hz ticker so ring cadence stays
	// independent of the 500ms rate sampler.
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for range ticker.C {
			s.history.Push(BuildHistoryPoint(s))
		}
	}()
}

// sampleOnce takes one reading of every rate-based source and updates the
// cached deltas. CPU/disk/net run every tick (500 ms); the process table
// is enumerated every other tick (1 Hz) because its cost dominates — on
// a host with ~600 running processes it accounts for >80% of the agent's
// CPU time, and a 1 Hz refresh is indistinguishable from 2 Hz at the UI.
func (s *Sampler) sampleOnce() {
	s.sampleCounter++
	scanProcs := s.sampleCounter%2 == 0

	// CPU
	total, cores := readCPUStat()
	// Disk
	diskNow := readDiskStats()
	diskAt := time.Now()
	// Net
	netNow := readNetDev()
	netAt := time.Now()
	// Procs — scanned on alternating ticks to halve the /proc walk cost.
	var procsNow map[int]procCPUState
	var procsAt time.Time
	if scanProcs {
		procsNow = readAllProcCPU()
		procsAt = time.Now()
	}
	// RAPL (may fail transiently; treat as "no update this tick")
	var energyUJ uint64
	var energyErr error
	energyAt := time.Now()
	if s.raplOK {
		energyUJ, energyErr = s.rapl.read()
	}
	// Temp sensor
	var tempC float64
	var tempErr error
	if s.cpuTempOK {
		tempC, tempErr = s.cpuTempSensor.read()
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// CPU deltas
	if !s.lastCPUTotal.isZero() {
		s.cpuPct = computeCPUPct(s.lastCPUTotal, total)
		if len(s.lastCPUCores) == len(cores) {
			s.cpuPerCore = make([]float64, len(cores))
			for i := range cores {
				s.cpuPerCore[i] = computeCPUPct(s.lastCPUCores[i], cores[i])
			}
		} else {
			s.cpuPerCore = make([]float64, len(cores))
		}
	} else {
		s.cpuPerCore = make([]float64, len(cores))
	}
	s.lastCPUTotal = total
	s.lastCPUCores = cores

	// Disk deltas
	if !s.lastDiskAt.IsZero() {
		dt := diskAt.Sub(s.lastDiskAt).Seconds()
		if dt > 0 {
			var rd, wr uint64
			for dev, cur := range diskNow {
				prev, ok := s.lastDisk[dev]
				if !ok {
					continue
				}
				if cur.readSectors >= prev.readSectors {
					rd += uint64(float64((cur.readSectors-prev.readSectors)*512) / dt)
				}
				if cur.writeSectors >= prev.writeSectors {
					wr += uint64(float64((cur.writeSectors-prev.writeSectors)*512) / dt)
				}
			}
			s.diskRead = rd
			s.diskWrite = wr
		}
	}
	s.lastDisk = diskNow
	s.lastDiskAt = diskAt

	// Net: choose the primary interface, then report its rx/tx rate.
	//
	// Preferred: the iface holding the IPv4 default route (what the
	// kernel would actually use for traffic leaving the host). Falls
	// back to "non-loopback iface with highest cumulative bytes" when
	// no default route exists — rare, but possible on air-gapped hosts
	// or network namespaces with nothing routed.
	defaultIface, hasDefault := readDefaultRouteIface()

	if !s.lastNetAt.IsZero() {
		dt := netAt.Sub(s.lastNetAt).Seconds()
		if dt > 0 {
			// Compute rx/tx rate for every non-loopback iface up front.
			type rate struct {
				rx, tx, totalLifetime uint64
			}
			rates := make(map[string]rate, len(netNow))
			for iface, cur := range netNow {
				if iface == "lo" {
					continue
				}
				prev, ok := s.lastNet[iface]
				if !ok {
					continue
				}
				var rx, tx uint64
				if cur.rxBytes >= prev.rxBytes {
					rx = uint64(float64(cur.rxBytes-prev.rxBytes) / dt)
				}
				if cur.txBytes >= prev.txBytes {
					tx = uint64(float64(cur.txBytes-prev.txBytes) / dt)
				}
				rates[iface] = rate{rx: rx, tx: tx, totalLifetime: cur.rxBytes + cur.txBytes}
			}

			// Pick iface: default-route first, else highest-cumulative.
			chosen := ""
			if hasDefault {
				if _, ok := rates[defaultIface]; ok {
					chosen = defaultIface
				}
			}
			if chosen == "" {
				var bestTotal uint64
				for iface, r := range rates {
					if r.totalLifetime > bestTotal {
						bestTotal = r.totalLifetime
						chosen = iface
					}
				}
			}
			if r, ok := rates[chosen]; ok {
				s.netIface = chosen
				s.netRx = r.rx
				s.netTx = r.tx
			}
		}
	} else if hasDefault {
		// First pass with a default route: display the name right away
		// even though rates are 0 until the second sample lands.
		s.netIface = defaultIface
	} else {
		// First pass, no default route: show any non-loopback iface with
		// bytes so the UI has something to render.
		for iface, cur := range netNow {
			if iface == "lo" {
				continue
			}
			if cur.rxBytes+cur.txBytes > 0 {
				s.netIface = iface
				break
			}
			if s.netIface == "" {
				s.netIface = iface
			}
		}
	}
	s.lastNet = netNow
	s.lastNetAt = netAt

	// Per-process CPU deltas. Only runs on scan ticks — on non-scan
	// ticks we leave the cached map in place, so reads from the history
	// goroutine or handlers see the last-computed values unchanged.
	if scanProcs {
		newPct := make(map[int]float64, len(procsNow))
		if !s.lastProcsAt.IsZero() {
			// Elapsed between scans is ~1s (every-other tick at 500 ms
			// cadence). The /proc/<pid>/stat utime+stime fields are in
			// "clock ticks" (sysconf(_SC_CLK_TCK), typically 100). We
			// assume 100; if the kernel reports otherwise our number is
			// a proportional scale, which is fine for top-N ordering.
			elapsed := procsAt.Sub(s.lastProcsAt).Seconds()
			clkTck := float64(clockTicksPerSecond())
			for pid, cur := range procsNow {
				prev, ok := s.lastProcs[pid]
				if !ok {
					continue
				}
				deltaTicks := float64((cur.utime + cur.stime) - (prev.utime + prev.stime))
				if elapsed > 0 && deltaTicks >= 0 {
					pct := (deltaTicks / clkTck) / elapsed * 100.0
					newPct[pid] = pct
				}
			}
		}
		s.lastProcs = procsNow
		s.lastProcsAt = procsAt
		s.procCPUPct = newPct
	}

	// CPU power: compute Watts from energy delta over elapsed time.
	if s.raplOK && energyErr == nil {
		if !s.lastEnergyAt.IsZero() {
			dt := energyAt.Sub(s.lastEnergyAt).Seconds()
			s.cpuPowerW = computePowerW(s.lastEnergyUJ, energyUJ, s.rapl.maxRangeUJ, dt)
		}
		s.lastEnergyUJ = energyUJ
		s.lastEnergyAt = energyAt
	}
	// CPU temp: single read, no delta.
	if s.cpuTempOK && tempErr == nil {
		s.cpuTempC = tempC
	}
}

// CPUPowerW returns the cached CPU package power in Watts (0 when RAPL
// is unavailable or we haven't collected two samples yet).
func (s *Sampler) CPUPowerW() float64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cpuPowerW
}

// CPUTempC returns the cached CPU package / die temperature in Celsius
// (0 when no supported hwmon driver is present).
func (s *Sampler) CPUTempC() float64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cpuTempC
}

// History returns the shared ring buffer. Used by the /history handler.
func (s *Sampler) History() *HistoryRing {
	return s.history
}

// CPUState returns the cached total CPU % and per-core CPU %.
func (s *Sampler) CPUState() (float64, []float64) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	perCore := make([]float64, len(s.cpuPerCore))
	copy(perCore, s.cpuPerCore)
	return s.cpuPct, perCore
}

// DiskBps returns the cached aggregate disk read/write bytes-per-second.
func (s *Sampler) DiskBps() (uint64, uint64) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.diskRead, s.diskWrite
}

// NetBps returns the cached primary-interface rx/tx bytes-per-second and
// the name of the chosen interface.
func (s *Sampler) NetBps() (uint64, uint64, string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.netRx, s.netTx, s.netIface
}

// procCPUPctOf returns the cached CPU % for a given pid (0 if unknown).
func (s *Sampler) procCPUPctOf(pid int) float64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.procCPUPct[pid]
}
