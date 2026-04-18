package metrics

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

// ReadMem parses /proc/meminfo and returns total, used, available in bytes.
// used = total - available (Linux's MemAvailable is the best "free" proxy).
// Returns zeros if /proc/meminfo is unavailable.
func ReadMem() MemInfo {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return MemInfo{}
	}
	defer f.Close()

	vals := map[string]uint64{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		// Format: "MemTotal:       16384000 kB"
		colon := strings.IndexByte(line, ':')
		if colon < 0 {
			continue
		}
		key := line[:colon]
		rest := strings.TrimSpace(line[colon+1:])
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		n, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			continue
		}
		// Every meminfo value is in kB.
		vals[key] = n * 1024
	}

	total := vals["MemTotal"]
	available := vals["MemAvailable"]
	if available == 0 {
		// Fallback approximation for old kernels without MemAvailable.
		available = vals["MemFree"] + vals["Buffers"] + vals["Cached"]
	}
	used := uint64(0)
	if total > available {
		used = total - available
	}
	return MemInfo{Total: total, Used: used, Available: available}
}
