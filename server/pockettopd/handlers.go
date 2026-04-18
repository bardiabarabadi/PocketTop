package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"syscall"

	"github.com/bardiabarabadi/PocketTop/server/pockettopd/metrics"
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func handleVersion(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"version": version,
		"api":     "v1",
	})
}

// handleHistory returns the ring buffer of recent per-second samples plus
// the current (non-time-series) scalars. With `?since=<unix-ts>` only
// samples with `ts > since` are returned. With `?brief=1` the bulky
// fields in `current` (procs_top, disk_fs, gpus) are replaced with empty
// arrays — used by the Home-view tiles which only need `mem_total`,
// `net_iface`, and the latest sample's CPU / mem / net rates.
//
// Invariants:
//   - Samples are ordered oldest-first.
//   - `ts_end` is the most recent sample's ts, or 0 when the ring is empty.
//   - `current` is always fully populated (even when `samples` is empty);
//     brief responses keep the keys but emit empty arrays for the
//     omitted collections, preserving the wire contract.
func handleHistory(sampler *metrics.Sampler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var since int64
		if s := r.URL.Query().Get("since"); s != "" {
			// Negative / garbage values fall through to 0 (= full ring).
			v, err := strconv.ParseInt(s, 10, 64)
			if err == nil && v > 0 {
				since = v
			}
		}
		brief := r.URL.Query().Get("brief") == "1"
		// procs=<N> caps the process list at N (e.g. `procs=10` for the
		// Detail-view "top 10 + more…" pattern). `procs=0` returns an
		// empty array — equivalent to brief for the procs field only.
		// Omitted or unparseable means "no cap" (full list).
		procsLimit := -1
		if s := r.URL.Query().Get("procs"); s != "" {
			if v, err := strconv.Atoi(s); err == nil && v >= 0 {
				procsLimit = v
			}
		}
		ring := sampler.History()
		current := metrics.BuildCurrent(sampler)
		if brief {
			// Non-nil empty slices so JSON encoder emits "[]" and the
			// client decoder (non-optional arrays) still accepts the
			// response. `procs_total` stays intact.
			current.ProcsTop = []metrics.Process{}
			current.DiskFS = []metrics.FS{}
			current.GPUs = []metrics.GPUMeta{}
		} else if procsLimit >= 0 && len(current.ProcsTop) > procsLimit {
			current.ProcsTop = current.ProcsTop[:procsLimit]
		}
		resp := metrics.HistoryResponse{
			TsEnd:     ring.LatestTs(),
			IntervalS: 1,
			Samples:   ring.Since(since),
			Current:   current,
		}
		writeJSON(w, http.StatusOK, resp)
	}
}

type killRequest struct {
	Signal string `json:"signal"`
}

func handleKill(w http.ResponseWriter, r *http.Request) {
	pidStr := r.PathValue("pid")
	pid, err := strconv.Atoi(pidStr)
	if err != nil || pid <= 1 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid pid"})
		return
	}

	// Default to SIGTERM when no body or empty body is provided.
	sig := syscall.SIGTERM
	var req killRequest
	if r.Body != nil {
		// Ignore decode errors so empty/missing body is treated as default.
		_ = json.NewDecoder(r.Body).Decode(&req)
	}
	switch req.Signal {
	case "", "TERM", "SIGTERM":
		sig = syscall.SIGTERM
	case "KILL", "SIGKILL":
		sig = syscall.SIGKILL
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "signal must be TERM or KILL",
		})
		return
	}

	if err := syscall.Kill(pid, sig); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
