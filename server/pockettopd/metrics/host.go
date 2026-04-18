package metrics

import (
	"os"
	"strconv"
	"strings"
)

// Uptime returns /proc/uptime's first field (seconds since boot) rounded
// to int64. Returns 0 on non-Linux.
func Uptime() int64 {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0
	}
	f, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0
	}
	return int64(f)
}

// LoadAvg returns /proc/loadavg's three load averages. Returns [0,0,0]
// on non-Linux.
func LoadAvg() []float64 {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return []float64{0, 0, 0}
	}
	fields := strings.Fields(string(data))
	if len(fields) < 3 {
		return []float64{0, 0, 0}
	}
	out := make([]float64, 3)
	for i := 0; i < 3; i++ {
		f, _ := strconv.ParseFloat(fields[i], 64)
		out[i] = f
	}
	return out
}

// clockTicksPerSecond returns _SC_CLK_TCK. On Linux this is ~always 100.
// We hardcode 100 rather than cgo'ing sysconf; if a kernel reports a
// different value our per-process CPU% is a proportional scale, which is
// fine for the top-N ordering we use it for.
func clockTicksPerSecond() int {
	return 100
}
