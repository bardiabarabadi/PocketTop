package metrics

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// diskCounters holds cumulative read/write sector counts for one device.
type diskCounters struct {
	readSectors  uint64
	writeSectors uint64
}

// readDiskStats parses /proc/diskstats, keeping only "real" block devices
// (not loop/ram/dm partitions we already count via their parent). We
// filter to top-level sd*/nvme*/vd*/hd*/mmcblk* devices and skip numeric
// partitions so we don't double-count.
func readDiskStats() map[string]diskCounters {
	f, err := os.Open("/proc/diskstats")
	if err != nil {
		return map[string]diskCounters{}
	}
	defer f.Close()

	out := map[string]diskCounters{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		// Fields: major minor name reads readsMerged readSectors readMs
		// writes writesMerged writeSectors writeMs ...
		if len(fields) < 14 {
			continue
		}
		name := fields[2]
		if !isWholeDisk(name) {
			continue
		}
		reads, _ := strconv.ParseUint(fields[5], 10, 64)
		writes, _ := strconv.ParseUint(fields[9], 10, 64)
		out[name] = diskCounters{readSectors: reads, writeSectors: writes}
	}
	return out
}

// isWholeDisk decides whether a /proc/diskstats name is a whole disk we
// want to count (not a partition, loop, or ram device).
func isWholeDisk(name string) bool {
	if strings.HasPrefix(name, "loop") || strings.HasPrefix(name, "ram") || strings.HasPrefix(name, "dm-") {
		return false
	}
	// sd*, vd*, hd*: whole disk has no trailing digit (e.g. sda vs sda1).
	if strings.HasPrefix(name, "sd") || strings.HasPrefix(name, "vd") || strings.HasPrefix(name, "hd") {
		return !endsWithDigit(name)
	}
	// nvme0n1 is a whole disk; nvme0n1p1 is a partition. Heuristic:
	// count 'p' after the "nXX" section.
	if strings.HasPrefix(name, "nvme") {
		// If the name contains "p" followed by digits, it's a partition.
		for i := 0; i < len(name)-1; i++ {
			if name[i] == 'p' && name[i+1] >= '0' && name[i+1] <= '9' {
				// Only treat as partition if 'p' is preceded by a digit
				// (so we don't misclassify "nvme" itself).
				if i > 0 && name[i-1] >= '0' && name[i-1] <= '9' {
					return false
				}
			}
		}
		return true
	}
	// mmcblk0 vs mmcblk0p1
	if strings.HasPrefix(name, "mmcblk") {
		return !strings.Contains(name, "p")
	}
	return false
}

func endsWithDigit(s string) bool {
	if s == "" {
		return false
	}
	c := s[len(s)-1]
	return c >= '0' && c <= '9'
}

// ReadFilesystems returns usage for mounted filesystems backed by real
// block devices. We read /proc/mounts, skip pseudo filesystems, and call
// Statfs for each remaining mount.
func ReadFilesystems() []FS {
	f, err := os.Open("/proc/mounts")
	if err != nil {
		return nil
	}
	defer f.Close()

	var out []FS
	seen := map[string]bool{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 3 {
			continue
		}
		source, mount, fstype := fields[0], fields[1], fields[2]
		if !isRealFSType(fstype) {
			continue
		}
		if !strings.HasPrefix(source, "/") {
			// Skip pseudo sources like "tmpfs" (already filtered by type,
			// but belt-and-braces).
			continue
		}
		if seen[mount] {
			continue
		}
		seen[mount] = true

		var stat syscall.Statfs_t
		if err := syscall.Statfs(mount, &stat); err != nil {
			continue
		}
		bs := uint64(stat.Bsize)
		total := stat.Blocks * bs
		free := stat.Bavail * bs
		used := total - free
		if total == 0 {
			continue
		}
		out = append(out, FS{Mount: mount, Used: used, Total: total})
	}
	return out
}

// isRealFSType filters out pseudo filesystems that would pollute the
// filesystem list.
func isRealFSType(t string) bool {
	switch t {
	case "ext2", "ext3", "ext4", "xfs", "btrfs", "zfs",
		"f2fs", "reiserfs", "jfs", "nilfs2", "bcachefs",
		"vfat", "exfat", "ntfs", "ntfs3", "fuseblk",
		"apfs", "hfs", "hfsplus":
		return true
	}
	return false
}
