package metrics

import (
	"bufio"
	"math"
	"os"
	"strconv"
	"strings"
)

// netCounters holds cumulative rx/tx bytes for one interface.
type netCounters struct {
	rxBytes uint64
	txBytes uint64
}

// readNetDev parses /proc/net/dev and returns a map of iface name to
// cumulative rx/tx bytes. Returns empty map on non-Linux.
func readNetDev() map[string]netCounters {
	f, err := os.Open("/proc/net/dev")
	if err != nil {
		return map[string]netCounters{}
	}
	defer f.Close()

	out := map[string]netCounters{}
	scanner := bufio.NewScanner(f)
	// Skip the two header lines.
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		if lineNo <= 2 {
			continue
		}
		line := scanner.Text()
		// Format: "  eth0: 1234 5 0 0 0 0 0 0  6789 ..."
		colon := strings.IndexByte(line, ':')
		if colon < 0 {
			continue
		}
		iface := strings.TrimSpace(line[:colon])
		rest := strings.Fields(line[colon+1:])
		if len(rest) < 16 {
			continue
		}
		rx, _ := strconv.ParseUint(rest[0], 10, 64)
		tx, _ := strconv.ParseUint(rest[8], 10, 64)
		out[iface] = netCounters{rxBytes: rx, txBytes: tx}
	}
	return out
}

// readDefaultRouteIface parses /proc/net/route and returns the interface
// that holds the IPv4 default route (destination 0.0.0.0/0). When
// multiple default routes exist (multi-homing, failover), the lowest-
// metric wins — that's the one the kernel will actually use. Returns
// ("", false) when no default route is present (air-gapped host, network
// namespaces with nothing routed, …) so the caller can fall back.
//
// /proc/net/route layout:
//   Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT
// Destination and Mask are hex, little-endian — "00000000" means 0.0.0.0,
// which combined with Mask "00000000" marks the default route.
func readDefaultRouteIface() (string, bool) {
	f, err := os.Open("/proc/net/route")
	if err != nil {
		return "", false
	}
	defer f.Close()

	var bestIface string
	var bestMetric uint64 = math.MaxUint64
	scanner := bufio.NewScanner(f)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		if lineNo == 1 {
			continue // header
		}
		fields := strings.Fields(scanner.Text())
		if len(fields) < 8 {
			continue
		}
		if fields[1] != "00000000" {
			continue
		}
		m, err := strconv.ParseUint(fields[6], 10, 64)
		if err != nil {
			continue
		}
		if m < bestMetric {
			bestMetric = m
			bestIface = fields[0]
		}
	}
	return bestIface, bestIface != ""
}
