# PocketTop — Windows Implementation Plan

## Context

Linux host support ships end-to-end: iOS app → SSH install → `pockettopd` (Go) on systemd → HTTPS pinned polling. This plan adds **Windows** as a second supported *monitored machine* platform. The iOS client itself does not change in any visible way — the same wizard, Home tiles, Detail dashboard, and kill semantics. The `Server.osFamily` field exists already (default `"linux"`, now also `"windows"`).

The Linux implementation doc (`docs/Linux_Implementation.md`) and architecture reference (`docs/SSH_App_Architecture_Reference.md`) remain authoritative for the layers Windows reuses (SSH, TLS pinning, Keychain, SwiftData, URL session pool, AddServer wizard). This plan only documents where Windows **diverges** — everything not mentioned here is shared.

Decisions:
- **Target scope:** Windows 10 1809+ / Windows 11 / Server 2019+. Home SKUs included (they have OpenSSH Server available).
- **SSH prerequisite:** the host has **OpenSSH Server** enabled (built-in since Windows Server 2019 and Windows 10 1809, via `Add-WindowsCapability -Online -Name OpenSSH.Server`). The installer does **not** auto-install it — the preflight step checks and asks the user to enable it.
- **SSH user must be Administrator.** Windows has no sudo; the plan sidesteps elevation entirely by requiring the install-time SSH user to be in the local `Administrators` group. Steady-state service runs as `LocalSystem` (equivalent to root). This mirrors the Linux implementation's "sudo only at install/upgrade, never at steady state" rule, simplified for the OS.
- **Service manager:** native Windows Service via `golang.org/x/sys/windows/svc`. `pockettopd.exe` is *itself* a service — the install script registers it with `sc.exe create`. No NSSM, no third-party wrapper.
- **Installer language:** PowerShell (`pockettop_install.ps1`). Built-in since Windows 7; handles firewall, cert gen, service registration, and JSON progress lines natively.
- **Self-signed cert generation:** done by `pockettopd.exe --generate-cert` on first startup, using Go's `crypto/x509`. Avoids the `New-SelfSignedCertificate` + IP-SAN quirk (PowerShell's built-in cert cmdlet requires raw ASN.1 for IP SAN). The cert still has IP in SAN; no hostname. Same iOS-side pinning, no TLS client changes.
- **OS detection:** **user picks** Linux vs Windows as the first step of the Add Machine wizard. Auto-detection is a future polish item.
- **GPU:** NVIDIA only, via `nvidia-smi.exe` (same as Linux). AMD / Intel integrated GPUs are out of scope.
- **Kill signal mapping:** `TERM` → `TerminateProcess` (no grace period attempted — there is no true SIGTERM analogue on Windows for arbitrary processes). `KILL` → `TerminateProcess`, identical behavior. The UI still exposes both for forward-compat with a future macOS implementation, but on Windows the action sheet shows a note: *"On Windows both options terminate immediately."*

---

## Architecture Overview

```
┌──────────────┐    SSH (22, OpenSSH) ┌─────────────────────────────────┐
│  iOS App     │ ──── setup/admin ──►│  Windows host                   │
│  (SwiftUI)   │                     │                                 │
│              │    HTTPS (443)      │  pockettopd.exe (Windows Svc)   │
│  MetricsSvc  │ ◄──── pinned ──────►│  - GET /snapshot (same API)     │
│  (URLSession)│    self-signed TLS  │  - POST /processes/{pid}/kill   │
└──────────────┘                     │  - GlobalMemoryStatusEx /       │
                                     │    GetSystemTimes / EnumProc.   │
                                     └─────────────────────────────────┘
```

Same HTTPS surface. Same iOS code path. Only the installer, agent binary, and a handful of OS-specific strategy objects differ.

---

## Phase 0 — iOS Scaffolding for Multi-OS

### Introduce `InstallerStrategy`

A protocol abstracting the OS-specific parts of `InstallerService`. The orchestration logic (`install() -> AsyncThrowingStream`) stays in `InstallerService` and delegates:

```swift
protocol InstallerStrategy: Sendable {
    var osFamily: String { get }                                   // "linux" | "windows"
    var binaryResourceName: (x86_64: String, arm64: String) { get }
    var binaryRemotePath: String { get }                           // "/tmp/pockettopd" | "C:\\Windows\\Temp\\pockettopd.exe"
    var scriptResourceName: String { get }                         // "pockettop_install.sh" | "pockettop_install.ps1"
    var scriptRemotePath: String { get }
    var logRemotePath: String { get }
    var pidRemotePath: String { get }

    /// `uname -m` on Linux, PowerShell `[System.Environment]::Is64BitOperatingSystem` + arch on Windows.
    func detectArch(via ssh: SSHService) async throws -> AgentArch

    /// Returns the full shell command to launch the install script detached.
    /// Linux: `nohup setsid bash … &`
    /// Windows: `Start-Process powershell -ArgumentList '-File',...,'install' -PassThru -NoNewWindow`
    func launchCommand(scriptPath: String, logPath: String, pidPath: String) -> String

    /// Liveness check. Linux returns `"RUNNING"` from `[ -d /proc/PID ]`, Windows from `Get-Process -Id`.
    func livenessCommand(pid: Int) -> String

    /// Source-of-truth reads after install success. Returns the two values as stdout separated by `"---"`.
    func readInstalledCredentialsCommand() -> String
}

enum AgentArch: String, Sendable { case amd64, arm64 }
```

Two implementations: `LinuxInstaller` (existing Linux logic moved behind this protocol) and `WindowsInstaller` (new).

`InstallerService` is refactored so its `install()` method:
1. Calls `strategy.detectArch(...)`.
2. Reads the right bundled binary (`"pockettopd-linux-amd64"` vs `"pockettopd-windows-amd64.exe"`, etc.) and uploads to `strategy.binaryRemotePath`.
3. Uploads `strategy.scriptResourceName` to `strategy.scriptRemotePath`.
4. Runs `strategy.launchCommand(...)` via `ssh.execute(...)`.
5. Polls `strategy.logRemotePath` + `strategy.livenessCommand(pid)`.
6. On success, runs `strategy.readInstalledCredentialsCommand()` and parses the `api_key---cert_fingerprint` pair.

The `Server.osFamily` value selects which strategy to instantiate.

### Add OS picker to `AddServerFlow`

`ConnectionFormView` gains a `Picker("Operating system", selection: $state.osFamily) { Text("Linux"); Text("Windows") }` as the first field. The choice is written into `server.osFamily` at persistence time and picks the installer strategy in `InstallProgressView`.

### Update `ConnectionRecoveryService` to delegate via strategy

Same dispatch: `recover(server:)` branches on `server.osFamily` to pick a `RecoveryStrategy` (Linux/Windows). The composite "read api_key && compute fingerprint" command differs per OS — on Windows it's a PowerShell one-liner that reads the `C:\ProgramData\PocketTop\api_key` file and computes the cert fingerprint via `[System.Security.Cryptography.X509Certificates.X509Certificate2]::new('C:\ProgramData\PocketTop\certs\server.crt').GetCertHashString('SHA256').ToLower()`.

No UI changes beyond the picker.

---

## Phase 1 — Go Agent: Windows Port (`pockettopd.exe`)

### New files under `server/pockettopd/`

| File | Purpose |
|---|---|
| `metrics/cpu_windows.go` | `GetSystemTimes` for overall; per-core via `NtQuerySystemInformation(SystemProcessorPerformanceInformation)`. Jiffy-diffing model identical to the Linux version, just different source of the sample. |
| `metrics/mem_windows.go` | `GlobalMemoryStatusEx` → total / avail; used = total − avail. |
| `metrics/disk_windows.go` | `GetLogicalDrives` + `GetDiskFreeSpaceEx` for capacity. I/O counters via `DeviceIoControl(IOCTL_DISK_PERFORMANCE)` against `\\.\PhysicalDrive0` etc. Diffed every 500ms like Linux. |
| `metrics/net_windows.go` | `GetIfTable2` → iterate `MIB_IF_ROW2` entries, pick the primary (highest total bytes, non-loopback, `OperStatus == IfOperStatusUp`). Diffed for rx/tx bps. |
| `metrics/procs_windows.go` | `EnumProcesses` → for each PID: `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ)` → `GetProcessTimes` (CPU% diff), `GetProcessMemoryInfo` (`WorkingSetSize` == RSS-equivalent), `QueryFullProcessImageName` (exe name), `GetTokenInformation(TokenUser)` + `LookupAccountSid` (user). |
| `metrics/gpu_windows.go` | `nvidia-smi.exe` shell-out (reuses the Linux parser — CSV output is identical across OSes). Discovered via `exec.LookPath("nvidia-smi")`; returns `[]` if absent. |
| `metrics/host_windows.go` | Uptime via `GetTickCount64`. Load average doesn't exist on Windows — report `[]` (empty slice) in the `load` field. iOS renders "—" when empty. |
| `metrics/sampler_windows.go` | Same 500ms goroutine pattern, wiring the Windows collectors. Mutex is shared with the existing one. |
| `service_windows.go` | `golang.org/x/sys/windows/svc` handler: implements `svc.Handler.Execute`. Handles `SERVICE_CONTROL_STOP`, graceful shutdown. |
| `kill_windows.go` | `TerminateProcess` for both `TERM` and `KILL`. Document in a comment that Windows has no SIGTERM analogue; both do the same thing. |

### New files cross-platform (`//go:build !linux && !windows` fallback)

`metrics/*_other.go` stubs for darwin/dev-compile. Already effectively present via zero-value returns in the Linux-only build; with Windows landing we formalize them with build tags so both specializations compile cleanly on any target.

### `main.go` additions

- `--service-install` / `--service-remove` / `--service-run` flags. On Windows these register / unregister / execute as a service via `svc.Run(...)`. On Linux they're no-ops (or print a short "use systemd" message).
- `--generate-cert` flag: if the cert file doesn't exist, generate a self-signed EC P-256 cert with the provided IP in SAN (flag `--cert-ip`). Write to `--cert` + `--key` paths. Exit. Used by both Linux and Windows installers (simplifies the Linux flow too — but only if we want the simplification; the Linux installer currently uses `openssl` CLI, keeping that for now means Linux is unchanged).

### Makefile additions

```
build-windows-amd64:
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -o dist/pockettopd-windows-amd64.exe .

build-windows-arm64:
	CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -ldflags="-s -w" -o dist/pockettopd-windows-arm64.exe .

build-all: build-amd64 build-arm64 build-windows-amd64 build-windows-arm64
```

`file dist/pockettopd-windows-*.exe` should report `PE32+ executable`.

### Validation

- `cd server/pockettopd && make build-all` produces four binaries.
- On a Windows VM (OrbStack Windows 11 ARM or UTM): `pockettopd.exe --generate-cert --cert C:\test\cert.pem --key C:\test\key.pem --cert-ip 10.0.0.5` produces a valid PEM pair; `openssl x509 -in C:\test\cert.pem -noout -text` (if openssl available) or `certutil -dump C:\test\cert.pem` shows the IP SAN.
- `pockettopd.exe --service-install` then `Start-Service pockettopd` launches. `curl -k https://127.0.0.1/health` returns 200.

---

## Phase 2 — PowerShell Installer (`pockettop_install.ps1`)

### Location and bundling

`PocketTop/PocketTop/Resources/pockettop_install.ps1`. Bundled the same way `.sh` is (file-system synchronized group auto-includes).

### Subcommands

Same as Linux: `preflight | install | upgrade | status | uninstall | version`. Takes a single positional `$Subcommand` parameter.

### Install flow (10 steps, paralleling Linux Phase 5 in `docs/Linux_Implementation.md`)

1. **Elevation check** — `[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`. Fail with `{"error":"must run as administrator"}` if not.
2. **Cleanup** — `Stop-Service pockettopd -ErrorAction SilentlyContinue`; `sc.exe delete pockettopd`; `Remove-Item C:\ProgramData\PocketTop -Recurse -Force -ErrorAction SilentlyContinue`; `Get-Process pockettopd -ErrorAction SilentlyContinue | Stop-Process -Force`.
3. **Firewall** — `New-NetFirewallRule -DisplayName "PocketTop (443)" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow` (idempotent: check `Get-NetFirewallRule -DisplayName` first; update or create). Windows Firewall is always present, so no "if missing, skip" path needed.
4. **Directories** — `New-Item -ItemType Directory -Force C:\ProgramData\PocketTop\{certs}`; `New-Item -ItemType Directory -Force "$env:USERPROFILE\.pockettop"`.
5. **Binary placement** — move `$env:TEMP\pockettopd.exe` to `C:\ProgramData\PocketTop\pockettopd.exe`. ACL via `icacls`: `Administrators:F, SYSTEM:F, Users:RX` (let the service LocalSystem read/exec; users can run `--help` but not modify).
6. **API key** — `[System.Convert]::ToHexString((New-Object byte[] 32 | ForEach-Object { Get-Random -Maximum 256 }))` → write to `C:\ProgramData\PocketTop\api_key`. ACL: `Administrators:F, SYSTEM:F` only (nobody else can read).
7. **TLS cert** — invoke `C:\ProgramData\PocketTop\pockettopd.exe --generate-cert --cert C:\ProgramData\PocketTop\certs\server.crt --key C:\ProgramData\PocketTop\certs\server.key --cert-ip <detected-ip>`. IP detection via `Invoke-RestMethod https://api.ipify.org` → fallback to `Invoke-RestMethod https://ifconfig.me` → fallback to `(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -notmatch 'Loopback'} | Select -First 1).IPAddress`.
8. **User cache** — copy API key to `$env:USERPROFILE\.pockettop\api_key`; compute cert FP via `(Get-FileHash -Algorithm SHA256 -Path C:\ProgramData\PocketTop\certs\server.crt).Hash.ToLower()` — wait, that's the file hash, not the cert DER hash. Use instead: `[System.Security.Cryptography.X509Certificates.X509Certificate2]::new("C:\ProgramData\PocketTop\certs\server.crt").GetCertHashString("SHA256").ToLower()`. Write to `~\.pockettop\cert_fp`.
9. **Service registration** — `sc.exe create pockettopd binPath= "C:\ProgramData\PocketTop\pockettopd.exe --service-run --cert C:\ProgramData\PocketTop\certs\server.crt --key C:\ProgramData\PocketTop\certs\server.key --api-key-file C:\ProgramData\PocketTop\api_key --port 443" start= auto obj= LocalSystem`. Then `sc.exe failure pockettopd reset= 30 actions= restart/3000/restart/3000/restart/3000` for crash-restart. `Start-Service pockettopd`.
10. **Health check** — loop `Invoke-WebRequest -UseBasicParsing -SkipCertificateCheck https://127.0.0.1/health` (PowerShell 7+ has `-SkipCertificateCheck`; PowerShell 5.1 needs a `[ServicePointManager]::ServerCertificateValidationCallback` override). Up to 30s timeout. Emit `{"error":"health check timed out"}` on failure.
11. **Final success line** — exact same schema as Linux: `{"result":"success","api_key":"<hex>","cert_fingerprint":"<hex>","https_port":443,"version":"1.0.0"}`.

### JSON progress contract

Same as Linux: one JSON object per line. Keep `step` values identical to Linux where they exist (`cleanup`, `firewall`, `directories`, `binary`, `apikey`, `cert`, `cache`, `systemd`, `health`) — on Windows `systemd` → `service` (renamed). The iOS `InstallProgressView` renders both with a small map: `systemd|service → "Registering service"`.

Emit via `Write-Host` with `ConvertTo-Json -Compress`. Stderr goes to a separate log via `Write-Error 2>&1 | Out-File`.

### Detached launch from iOS

The Windows equivalent of `nohup setsid`:

```powershell
$launcher = @"
`$pid | Out-File -Encoding ASCII C:\Windows\Temp\pockettop_install.pid
powershell -ExecutionPolicy Bypass -File C:\Windows\Temp\pockettop_install.ps1 install *>&1 | Out-File -Encoding UTF8 C:\Windows\Temp\pockettop_install.log
"@
$launcher | Out-File -Encoding UTF8 C:\Windows\Temp\pockettop_launcher.ps1

Start-Process -NoNewWindow -FilePath powershell.exe `
    -ArgumentList '-ExecutionPolicy','Bypass','-File','C:\Windows\Temp\pockettop_launcher.ps1' `
    -WorkingDirectory C:\Windows\Temp
```

(The exact incantation lives in `WindowsInstaller.launchCommand(...)` on iOS — this is the shape.)

Liveness: `Get-Process -Id <PID> -ErrorAction SilentlyContinue; if ($?) { "RUNNING" } else { "EXITED" }`. No `[ -d /proc/PID ]` equivalent needed — Windows doesn't have the EPERM issue because the SSH user is Administrator and can see all processes.

Log tailing: `Get-Content -Path C:\Windows\Temp\pockettop_install.log -Tail <N>` (or `Select-Object -Skip`). Works the same as `tail -n +N` for our polling needs.

---

## Phase 3 — iOS `WindowsInstaller` strategy

Exactly the protocol conformance described in Phase 0. Key deltas:

- `binaryResourceName` → `"pockettopd-windows-amd64.exe"` / `"pockettopd-windows-arm64.exe"`.
- `binaryRemotePath` → `"C:\\Windows\\Temp\\pockettopd.exe"` (escaped for Swift string literal).
- `scriptResourceName` → `"pockettop_install.ps1"`.
- `scriptRemotePath` → `"C:\\Windows\\Temp\\pockettop_install.ps1"`.
- `detectArch(via:)` runs `powershell -c "if ([Environment]::Is64BitOperatingSystem) { if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' } } else { 'x86' }"`. x86 throws `remoteArchUnknown("x86")` — 32-bit not supported.
- `launchCommand(scriptPath:logPath:pidPath:)` returns the PowerShell launcher shown above.
- `livenessCommand(pid:)` → PowerShell `Get-Process -Id` one-liner.
- `readInstalledCredentialsCommand()` → PowerShell that emits `api_key---cert_fp` to stdout.

### Binary upload over OpenSSH (Windows)

Windows OpenSSH tolerates the same base64-heredoc upload pattern, provided we target PowerShell as the remote shell. Caveat: the default OpenSSH shell on Windows since 10.0.19041 is `cmd.exe`, not PowerShell. Two options:

1. Configure the SSH command explicitly: `ssh user@host 'powershell -c "[IO.File]::WriteAllBytes(\"C:\Windows\Temp\pockettopd.exe\", [Convert]::FromBase64String(\"<base64>\"))"'` — piping via stdin also works but is fiddly under OpenSSH-for-Windows.
2. Always prefix commands with `powershell -NonInteractive -Command` in `WindowsInstaller`.

**Pick option 2.** Cleaner and survives cmd.exe shell defaults. Document in `WindowsInstaller`: every `ssh.execute(...)` call is pre-wrapped with `powershell -NonInteractive -Command "…"`. This includes the PowerShell base64-decode for the binary upload.

Binary size verification: `(Get-Item "C:\Windows\Temp\pockettopd.exe").Length` → parse to Int and compare against expected.

---

## Phase 4 — Connection recovery on Windows

`WindowsRecoveryStrategy` mirrors Linux but the command is:

```powershell
$k = Get-Content -Raw "C:\ProgramData\PocketTop\api_key"
$c = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new("C:\ProgramData\PocketTop\certs\server.crt").GetCertHashString("SHA256").ToLower()
"$k---$c"
```

Because the SSH user is Administrator, no elevation dance is needed — file reads succeed directly. There is **no user-readable cache path** on Windows (the Linux `~/.pockettop/` cache was a workaround for non-root SSH users, which doesn't apply here). If the admin requirement is ever relaxed, we'd add one then.

`verifyConnection()` (in `ConnectionRecoveryService`) is unchanged — it hits HTTPS, not SSH.

---

## Phase 5 — Kill semantics on Windows

`pockettopd.exe` implements `/processes/{pid}/kill`:

```go
// kill_windows.go
func KillProcess(pid int32, signal string) error {
    h, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, uint32(pid))
    if err != nil { return err }
    defer windows.CloseHandle(h)
    // On Windows, both "TERM" and "KILL" end the process immediately.
    // There is no universal WM_CLOSE equivalent for non-GUI/non-console processes.
    return windows.TerminateProcess(h, 1)
}
```

iOS side: the `ProcessTable` action sheet stays the same, but `DetailView` shows a footnote when `server.osFamily == "windows"`: *"On Windows, both SIGTERM and SIGKILL terminate immediately."* The footnote only renders on Windows rows.

---

## Phase 6 — Testing

### Unit-level
- `cd server/pockettopd && go test ./...` on darwin compiles both Linux and Windows build-tagged files (stubs) — we won't *run* Windows tests on darwin. Cross-compile smoke: `GOOS=windows go build ./...` must succeed.
- iOS: `xcodebuild build` must still succeed with both `LinuxInstaller` and `WindowsInstaller` present.

### End-to-end on a Windows VM

Target: Windows 11 Pro ARM64 in UTM (for Apple Silicon dev hosts). Alternative: cloud Windows Server 2022.

Setup:
1. Enable OpenSSH Server: `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service -Name sshd -StartupType Automatic`.
2. Create a local admin user; set a password.
3. Note the VM's IP.

E2E checklist:
- Add the Windows host in the wizard (pick Windows in the OS dropdown). Password auth.
- Install completes; Home tile goes live.
- Detail shows CPU / mem / disk / net ticking at ~1Hz. Compare against Task Manager — rough agreement.
- Spawn a busy-loop: `powershell -c "while($true){}"`. It should climb the process list.
- Tap it → "Force kill (SIGKILL)" → confirm `Get-Process` no longer shows it.
- Close the app, reopen. Server reconnects without prompting.
- Change the cert on the VM (stop service, delete certs, `--generate-cert` again, restart). Confirm the app refuses to connect (pinning works).

### Cross-platform regression

After Windows lands, re-run the full Linux E2E checklist (`docs/Linux_Implementation.md` → Verification) to make sure the `InstallerStrategy` refactor didn't regress Linux. Key: all existing `Server` rows (`osFamily == "linux"`) must recover correctly on app launch.

---

## Critical Files to Create

| Path | Purpose |
|---|---|
| `PocketTop/PocketTop/Services/Installer/InstallerStrategy.swift` | Protocol, `AgentArch` enum. |
| `PocketTop/PocketTop/Services/Installer/LinuxInstaller.swift` | Extract existing Linux logic behind the protocol. |
| `PocketTop/PocketTop/Services/Installer/WindowsInstaller.swift` | New — Windows PowerShell dispatch. |
| `PocketTop/PocketTop/Services/Recovery/WindowsRecoveryStrategy.swift` | New — PowerShell composite read. |
| `PocketTop/PocketTop/Services/Recovery/LinuxRecoveryStrategy.swift` | Extract existing. |
| `PocketTop/PocketTop/Resources/pockettop_install.ps1` | PowerShell installer. |
| `PocketTop/PocketTop/Resources/pockettopd-windows-amd64.exe` | Cross-compiled agent. |
| `PocketTop/PocketTop/Resources/pockettopd-windows-arm64.exe` | Cross-compiled agent. |
| `server/pockettopd/service_windows.go` | `svc.Handler` implementation. |
| `server/pockettopd/kill_windows.go` | `TerminateProcess` wrapper. |
| `server/pockettopd/metrics/{cpu,mem,disk,net,procs,gpu,host,sampler}_windows.go` | Win32-API collectors. |
| `server/pockettopd/metrics/{cpu,mem,disk,net,procs,gpu,host}_other.go` | Darwin/BSD stub collectors (dev-compile). |
| `server/pockettopd/cert.go` | `--generate-cert` flag handler (cross-platform, Go's `crypto/x509`). |

### Existing files refactored (not rewritten)

- `InstallerService.swift` — accepts a `strategy: InstallerStrategy` parameter; existing logic calls strategy methods.
- `ConnectionRecoveryService.swift` — same, `strategy: RecoveryStrategy`.
- `AddServerFlow.swift` / `ConnectionFormView.swift` — add OS picker.
- `InstallProgressView.swift` — map `"service"` step to the same human-friendly label as `"systemd"`.
- `DetailView.swift` / `ProcessTable.swift` — Windows kill-semantics footnote.
- `server/pockettopd/main.go` — add `--service-install/remove/run` and `--generate-cert` flags.
- `server/pockettopd/Makefile` — add Windows targets.

### Existing files unchanged

Everything under `Services/SSH/`, `Services/Keychain/`, `Services/Metrics/`, `Models/`, `Features/Home/`, `Features/Detail/MetricCards.swift`, the `Snapshot` payload schema. The entire transport + pinning + persistence layer carries over as-is.

---

## Reused Patterns from Ref Doc

- **§4 SSH upload pattern** — base64 heredoc still used, wrapped in `powershell -c` for Windows commands.
- **§5 Detached install** — `Start-Process -NoNewWindow` replaces `nohup setsid`; PID file + log-tailing identical.
- **§5 Post-install verification** — re-read from server (not from log) is the source of truth. Same pattern.
- **§7 TLS pinning** — zero change. Same delegate, same policy, same session pool.
- **§8 Keychain** — same `KeychainKey`s, same `app-shared-ssh-key` account. The `sudoPassword` key simply never gets written on Windows servers (the `sudoPasswordSaved` flag stays false).
- **§9 Recovery** — same "SSH briefly, read credentials, disconnect, HTTPS-verify" pattern, just with PowerShell commands.
- **§12 gotchas** — IP SAN still required (iOS doesn't care what OS the cert came from), `SecTrustEvaluateWithError` still mandatory, session pool still needed.

---

## Resolved Decisions

1. **SSH shell wrapping:** `WindowsInstaller` always prefixes remote commands with `powershell -NonInteractive -Command "…"`. Prevents the cmd.exe-vs-PowerShell default-shell uncertainty.
2. **Cert generation:** `pockettopd.exe --generate-cert` in Go, not `New-SelfSignedCertificate` in PowerShell. Cleaner IP-SAN handling.
3. **Service model:** native Windows Service (`golang.org/x/sys/windows/svc`), not NSSM. One fewer binary to bundle.
4. **OS picker:** explicit user choice. Auto-detection is future polish.
5. **Kill mapping:** TERM and KILL are both `TerminateProcess` on Windows; footnote shown in the UI.
6. **GPU:** NVIDIA only via `nvidia-smi.exe` — identical to Linux.
7. **No user-readable cache** on Windows: admin SSH user makes it unnecessary.
8. **No WinRM fallback:** OpenSSH Server is a hard prerequisite. Preflight checks it and asks the user to enable it if missing.

---

## Out of Scope (Deferred)

- macOS host support.
- Auto-detecting OS from the SSH banner.
- Intel / AMD GPU metrics.
- Non-admin Windows SSH users (requires a UAC-elevation dance that has no iOS-friendly flow).
- Domain-joined / Active Directory credential handling.
- Windows-native SSH via WinRM as an alternative transport.
- Windows-on-ARM tested on a real device beyond a VM.
