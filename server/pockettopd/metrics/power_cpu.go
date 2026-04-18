package metrics

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// raplPackage is a discovered RAPL "package-*" domain. Ubuntu's kernel
// exposes AMD Zen/Zen+ RAPL via the same intel-rapl pseudo-driver, so the
// "intel-rapl:N" layout works on AMD hosts too. Subdomains (core, uncore,
// dram) use a second colon — e.g. intel-rapl:0:0 — and are ignored here.
type raplPackage struct {
	path         string // directory containing energy_uj + max_energy_range_uj
	maxRangeUJ   uint64 // counter wrap point (read once at discovery)
}

// findRAPLPackage scans /sys/class/powercap for the first top-level
// "package-*" domain and returns its handle. Returns ("", _, false) when
// RAPL isn't exposed (pre-Sandy-Bridge Intel, AMD without the module, VMs,
// containers without /sys). Caller holds onto the result for sampleOnce.
func findRAPLPackage() (raplPackage, bool) {
	entries, err := os.ReadDir("/sys/class/powercap")
	if err != nil {
		return raplPackage{}, false
	}
	for _, e := range entries {
		name := e.Name()
		// Skip subdomains (they contain a second colon: intel-rapl:0:0).
		if strings.Count(name, ":") != 1 {
			continue
		}
		if !strings.HasPrefix(name, "intel-rapl:") {
			continue
		}
		dir := filepath.Join("/sys/class/powercap", name)
		label, _ := os.ReadFile(filepath.Join(dir, "name"))
		if !strings.HasPrefix(strings.TrimSpace(string(label)), "package-") {
			continue
		}
		maxBytes, err := os.ReadFile(filepath.Join(dir, "max_energy_range_uj"))
		if err != nil {
			continue
		}
		max, err := strconv.ParseUint(strings.TrimSpace(string(maxBytes)), 10, 64)
		if err != nil || max == 0 {
			continue
		}
		// Probe energy_uj: must be readable. On stock installs it's root-
		// only (0400); the pockettopd systemd unit runs as root, so this
		// is fine at runtime but will return !ok during `go test` as a
		// regular user.
		if _, err := os.ReadFile(filepath.Join(dir, "energy_uj")); err != nil {
			continue
		}
		return raplPackage{path: dir, maxRangeUJ: max}, true
	}
	return raplPackage{}, false
}

// read returns the current energy counter in microjoules.
func (r raplPackage) read() (uint64, error) {
	b, err := os.ReadFile(filepath.Join(r.path, "energy_uj"))
	if err != nil {
		return 0, err
	}
	return strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
}

// computePowerW converts two energy samples into average wattage over the
// interval dt seconds. Handles counter wrap by adding one full range when
// `cur < prev`. Returns 0 on degenerate inputs.
func computePowerW(prev, cur, maxRange uint64, dt float64) float64 {
	if dt <= 0 || maxRange == 0 {
		return 0
	}
	var delta uint64
	if cur >= prev {
		delta = cur - prev
	} else {
		// Wrap. The counter is monotonic modulo maxRange.
		delta = (maxRange - prev) + cur
	}
	// µJ → J by /1e6, then J/s → W.
	return float64(delta) / 1e6 / dt
}
