package metrics

import (
	"os"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// procCPUState captures the utime+stime of a process at a point in time
// so the sampler can compute CPU% by diffing across intervals.
type procCPUState struct {
	utime uint64
	stime uint64
}

// readAllProcCPU walks /proc/<pid> and returns current utime+stime for
// each process. This is the hot-path snapshot used by the sampler.
func readAllProcCPU() map[int]procCPUState {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return map[int]procCPUState{}
	}
	out := make(map[int]procCPUState, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		ut, st, ok := readProcTimes(pid)
		if !ok {
			continue
		}
		out[pid] = procCPUState{utime: ut, stime: st}
	}
	return out
}

// readProcTimes parses /proc/<pid>/stat for just the utime+stime fields.
// Handles the classic "comm field may contain spaces and parens" trap by
// scanning for the last ')' before parsing the remaining fields.
func readProcTimes(pid int) (uint64, uint64, bool) {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return 0, 0, false
	}
	return parseProcStatTimes(data)
}

func parseProcStatTimes(data []byte) (uint64, uint64, bool) {
	s := string(data)
	rparen := strings.LastIndexByte(s, ')')
	if rparen < 0 || rparen+2 > len(s) {
		return 0, 0, false
	}
	// After "(comm) ", fields are space-separated. utime = field 14
	// (index 11 after we've consumed pid, comm, state, so from rest
	// the layout is: state ppid pgrp session tty_nr tpgid flags minflt
	// cminflt majflt cmajflt utime stime ...).
	rest := strings.Fields(s[rparen+2:])
	// indices: 0 state, 1 ppid, 2 pgrp, 3 session, 4 tty_nr, 5 tpgid,
	// 6 flags, 7 minflt, 8 cminflt, 9 majflt, 10 cmajflt,
	// 11 utime, 12 stime
	if len(rest) < 13 {
		return 0, 0, false
	}
	ut, err1 := strconv.ParseUint(rest[11], 10, 64)
	st, err2 := strconv.ParseUint(rest[12], 10, 64)
	if err1 != nil || err2 != nil {
		return 0, 0, false
	}
	return ut, st, true
}

// procStatic reads the non-CPU fields for a process: comm, rss, uid.
type procStatic struct {
	name string
	rss  uint64
	uid  int
}

func readProcStatic(pid int) (procStatic, bool) {
	var ps procStatic
	// /proc/<pid>/stat for comm + rss (rss in pages).
	statData, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return ps, false
	}
	s := string(statData)
	lparen := strings.IndexByte(s, '(')
	rparen := strings.LastIndexByte(s, ')')
	if lparen < 0 || rparen < 0 || rparen <= lparen {
		return ps, false
	}
	ps.name = s[lparen+1 : rparen]
	rest := strings.Fields(s[rparen+2:])
	// rss is at index 21 in the post-comm fields:
	// 0 state 1 ppid 2 pgrp 3 session 4 tty_nr 5 tpgid 6 flags
	// 7 minflt 8 cminflt 9 majflt 10 cmajflt 11 utime 12 stime
	// 13 cutime 14 cstime 15 priority 16 nice 17 num_threads
	// 18 itrealvalue 19 starttime 20 vsize 21 rss
	if len(rest) > 21 {
		rssPages, _ := strconv.ParseUint(rest[21], 10, 64)
		ps.rss = rssPages * uint64(os.Getpagesize())
	}

	// /proc/<pid>/status for Uid line.
	statusData, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "status"))
	if err == nil {
		lines := strings.Split(string(statusData), "\n")
		for _, line := range lines {
			if strings.HasPrefix(line, "Uid:") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					ps.uid, _ = strconv.Atoi(fields[1])
				}
				break
			}
		}
	}
	return ps, true
}

// readProcCmdline reads the full command line with NULs replaced by
// spaces. Falls back to empty string on failure; callers default to comm.
func readProcCmdline(pid int) string {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
	if err != nil || len(data) == 0 {
		return ""
	}
	// Trim trailing NUL, replace interior NULs with spaces.
	for len(data) > 0 && data[len(data)-1] == 0 {
		data = data[:len(data)-1]
	}
	for i := range data {
		if data[i] == 0 {
			data[i] = ' '
		}
	}
	return string(data)
}

// uidCache caches username lookups to avoid re-parsing /etc/passwd for
// every process on every snapshot.
var (
	uidCacheMu sync.RWMutex
	uidCache   = map[int]string{}
)

func usernameForUID(uid int) string {
	uidCacheMu.RLock()
	if name, ok := uidCache[uid]; ok {
		uidCacheMu.RUnlock()
		return name
	}
	uidCacheMu.RUnlock()

	name := strconv.Itoa(uid)
	if u, err := user.LookupId(strconv.Itoa(uid)); err == nil {
		name = u.Username
	}
	uidCacheMu.Lock()
	uidCache[uid] = name
	uidCacheMu.Unlock()
	return name
}

// TopProcesses returns the top N processes by CPU%, ties broken by RSS
// descending. Missing CPU% (e.g. first pass after startup) is treated as
// zero so short-lived procs don't hide the persistent ones. Pass `n <= 0`
// to return the full list (still sorted, just not truncated).
func (s *Sampler) TopProcesses(n int) []Process {
	s.mu.RLock()
	pids := make([]int, 0, len(s.lastProcs))
	for pid := range s.lastProcs {
		pids = append(pids, pid)
	}
	s.mu.RUnlock()

	procs := make([]Process, 0, len(pids))
	for _, pid := range pids {
		ps, ok := readProcStatic(pid)
		if !ok {
			continue
		}
		cmd := readProcCmdline(pid)
		if cmd == "" {
			cmd = ps.name
		}
		procs = append(procs, Process{
			PID:    pid,
			User:   usernameForUID(ps.uid),
			CPUPct: s.procCPUPctOf(pid),
			MemRSS: ps.rss,
			Name:   ps.name,
			Cmd:    cmd,
		})
	}

	sort.Slice(procs, func(i, j int) bool {
		if procs[i].CPUPct != procs[j].CPUPct {
			return procs[i].CPUPct > procs[j].CPUPct
		}
		return procs[i].MemRSS > procs[j].MemRSS
	})
	if n > 0 && len(procs) > n {
		procs = procs[:n]
	}
	return procs
}
