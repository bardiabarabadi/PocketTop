package metrics

import (
	"context"
	"encoding/csv"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// GPUProvider is the extension point for additional vendors (AMD rocm-smi,
// Intel, etc.) in V2+. V1 only ships an NVIDIA implementation.
type GPUProvider interface {
	Read() []GPU
}

// ReadGPUs queries every registered GPU provider and concatenates the
// results. V1 hardwires NVIDIA only; future vendors can be appended here.
func ReadGPUs() []GPU {
	out := []GPU{}
	out = append(out, nvidiaProvider{}.Read()...)
	// TODO(v2): append amdProvider{}.Read(), intelProvider{}.Read(), ...
	return out
}

// nvidiaProvider shells out to nvidia-smi. Returns an empty slice if the
// binary is missing or the command fails (no GPU, driver mismatch, etc.).
type nvidiaProvider struct{}

func (nvidiaProvider) Read() []GPU {
	if _, err := exec.LookPath("nvidia-smi"); err != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	// power.draw and temperature.gpu have been supported since ~driver 340
	// (2014). Older drivers print "[Not Supported]" which ParseFloat will
	// reject; we swallow that and emit 0 for those fields.
	cmd := exec.CommandContext(ctx, "nvidia-smi",
		"--query-gpu=name,utilization.gpu,memory.used,memory.total,power.draw,temperature.gpu",
		"--format=csv,noheader,nounits")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	reader := csv.NewReader(strings.NewReader(string(out)))
	reader.TrimLeadingSpace = true
	records, err := reader.ReadAll()
	if err != nil {
		return nil
	}
	var gpus []GPU
	for _, row := range records {
		if len(row) < 6 {
			continue
		}
		util, _ := strconv.Atoi(strings.TrimSpace(row[1]))
		memUsedMB, _ := strconv.ParseUint(strings.TrimSpace(row[2]), 10, 64)
		memTotalMB, _ := strconv.ParseUint(strings.TrimSpace(row[3]), 10, 64)
		powerW, _ := strconv.ParseFloat(strings.TrimSpace(row[4]), 64)
		tempC, _ := strconv.ParseFloat(strings.TrimSpace(row[5]), 64)
		gpus = append(gpus, GPU{
			Name:     strings.TrimSpace(row[0]),
			UtilPct:  util,
			MemUsed:  memUsedMB * 1024 * 1024,
			MemTotal: memTotalMB * 1024 * 1024,
			PowerW:   powerW,
			TempC:    tempC,
		})
	}
	return gpus
}
