package metrics

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

// cpuTimes captures the jiffies fields from /proc/stat for total or one
// core. Layout: user, nice, system, idle, iowait, irq, softirq, steal.
type cpuTimes struct {
	user, nice, system, idle, iowait, irq, softirq, steal uint64
}

func (c cpuTimes) isZero() bool {
	return c == cpuTimes{}
}

func (c cpuTimes) total() uint64 {
	return c.user + c.nice + c.system + c.idle + c.iowait + c.irq + c.softirq + c.steal
}

func (c cpuTimes) idleAll() uint64 {
	return c.idle + c.iowait
}

// computeCPUPct returns a percentage in [0,100] given two samples.
func computeCPUPct(prev, cur cpuTimes) float64 {
	totalDelta := float64(cur.total()) - float64(prev.total())
	idleDelta := float64(cur.idleAll()) - float64(prev.idleAll())
	if totalDelta <= 0 {
		return 0
	}
	pct := (totalDelta - idleDelta) / totalDelta * 100.0
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return pct
}

// readCPUStat parses /proc/stat and returns (total, perCore) samples. On
// non-Linux platforms it returns zero values.
func readCPUStat() (cpuTimes, []cpuTimes) {
	f, err := os.Open("/proc/stat")
	if err != nil {
		return cpuTimes{}, nil
	}
	defer f.Close()

	var total cpuTimes
	var cores []cpuTimes
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "cpu") {
			break
		}
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		name := fields[0]
		t := parseCPUFields(fields[1:])
		if name == "cpu" {
			total = t
		} else {
			// Parse core index from the label, e.g., "cpu0" -> 0.
			cores = append(cores, t)
		}
	}
	return total, cores
}

func parseCPUFields(fields []string) cpuTimes {
	vals := make([]uint64, 8)
	for i := 0; i < 8 && i < len(fields); i++ {
		vals[i], _ = strconv.ParseUint(fields[i], 10, 64)
	}
	return cpuTimes{
		user: vals[0], nice: vals[1], system: vals[2], idle: vals[3],
		iowait: vals[4], irq: vals[5], softirq: vals[6], steal: vals[7],
	}
}
