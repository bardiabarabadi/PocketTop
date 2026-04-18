package metrics

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// cpuTempSensor is a discovered hwmon sensor chosen once at startup. The
// path points at the specific temp{N}_input file, already labelled as the
// canonical CPU package / die temperature for the platform.
//
// We look at /sys/class/hwmon/hwmon*/name to find a supported driver, then
// scan its temp{N}_label files to pick the preferred channel. Driver ↦
// preferred label:
//
//	coretemp   → "Package id 0" (Intel package temp)
//	k10temp    → "Tdie" (Zen+ actual junction), else "Tctl"
//	zenpower   → "Tdie"     (out-of-tree driver for AMD)
//
// Falls back to temp1_input when no labels match.
type cpuTempSensor struct {
	path string
}

// findCPUTempSensor scans hwmon and returns the preferred CPU temperature
// input file. Returns !ok when none of the supported drivers is present.
func findCPUTempSensor() (cpuTempSensor, bool) {
	entries, err := os.ReadDir("/sys/class/hwmon")
	if err != nil {
		return cpuTempSensor{}, false
	}
	// Iterate in a stable order — /sys re-numbers hwmon* across reboots.
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)

	// Priority: coretemp and k10temp are in-tree; zenpower is out-of-tree
	// and only present when the user has installed it deliberately.
	priority := map[string]int{"coretemp": 0, "k10temp": 1, "zenpower": 2}

	type candidate struct {
		dir    string
		driver string
		rank   int
	}
	var cands []candidate
	for _, n := range names {
		dir := filepath.Join("/sys/class/hwmon", n)
		nameBytes, err := os.ReadFile(filepath.Join(dir, "name"))
		if err != nil {
			continue
		}
		driver := strings.TrimSpace(string(nameBytes))
		rank, ok := priority[driver]
		if !ok {
			continue
		}
		cands = append(cands, candidate{dir: dir, driver: driver, rank: rank})
	}
	sort.Slice(cands, func(i, j int) bool {
		return cands[i].rank < cands[j].rank
	})
	for _, c := range cands {
		if p, ok := pickTempInput(c.dir, c.driver); ok {
			return cpuTempSensor{path: p}, true
		}
	}
	return cpuTempSensor{}, false
}

// pickTempInput chooses the correct temp{N}_input for a given driver.
func pickTempInput(dir, driver string) (string, bool) {
	preferred := map[string][]string{
		"coretemp": {"Package id 0"},
		"k10temp":  {"Tdie", "Tctl"},
		"zenpower": {"Tdie"},
	}[driver]

	// Scan temp*_label → pick first that matches a preferred label.
	for _, want := range preferred {
		matches, _ := filepath.Glob(filepath.Join(dir, "temp*_label"))
		for _, lbl := range matches {
			content, err := os.ReadFile(lbl)
			if err != nil {
				continue
			}
			if strings.TrimSpace(string(content)) == want {
				// temp1_label → temp1_input
				input := strings.TrimSuffix(lbl, "_label") + "_input"
				if _, err := os.Stat(input); err == nil {
					return input, true
				}
			}
		}
	}
	// Fallback to temp1_input if present.
	fallback := filepath.Join(dir, "temp1_input")
	if _, err := os.Stat(fallback); err == nil {
		return fallback, true
	}
	return "", false
}

// read returns the current temperature in degrees Celsius (float). The
// hwmon files report milli-degrees C, so we divide by 1000.
func (s cpuTempSensor) read() (float64, error) {
	b, err := os.ReadFile(s.path)
	if err != nil {
		return 0, err
	}
	m, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return 0, err
	}
	return float64(m) / 1000.0, nil
}
