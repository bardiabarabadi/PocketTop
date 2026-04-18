# PocketTop — Linux Implementation

## Context

This document describes how PocketTop's **Linux** host support is built — the shipped end-to-end flow: add a machine, install a monitoring agent over SSH, watch live CPU / GPU / memory / disk / network, see the hottest processes, and kill one in a tap. Windows support is planned (`docs/Windows_Implementation.md`); macOS is further out.

The architectural playbook in `docs/SSH_App_Architecture_Reference.md` (extracted from the sibling CloseAI app) is the canonical guide for SSH, installer, TLS, cert pinning, Keychain, SwiftData, and reconnection. PocketTop reuses those layers wholesale and swaps the server payload (Python + Ollama → a Go metrics daemon).

Decisions:
- **Agent language:** Go, single static binary (`pockettopd`). Departs from the ref doc's Python, but a better fit for a tiny metrics API — no runtime install, reads `/proc` directly.
- **Transport:** pinned HTTPS, client polls `GET /snapshot` every 1–2s while the detail screen is open. Actions (kill) are `POST /processes/{pid}/kill`.
- **Auth at setup:** both password and bring-your-own-key (PEM) are supported, mirroring CloseAI.
- **OS scope:** Linux (systemd + Debian/Ubuntu primarily). The `Server` model carries an `osFamily` field so Windows/macOS slot in later without schema churn.

---

## Architecture Overview

```
┌──────────────┐    SSH (22)         ┌─────────────────────────────┐
│  iOS App     │ ──── setup/admin ──►│  Linux host                 │
│  (SwiftUI)   │                     │                             │
│              │    HTTPS (443)      │  pockettopd (systemd)       │
│  MetricsSvc  │ ◄──── pinned ──────►│  - GET /snapshot            │
│  (URLSession)│    self-signed TLS  │  - POST /kill               │
└──────────────┘                     │  - reads /proc, /sys        │
                                     └─────────────────────────────┘
```

Flow matches CloseAI: SSH to install and capture `{api_key, cert_fingerprint, https_port}`, disconnect, then steady-state HTTPS with fingerprint pinning. SSH is only reopened for upgrade / credential recovery.

---

## Phase 0 — Scaffolding

1. **Strip the template.** Delete `Item.swift` and the list UI in `ContentView.swift`. Replace the `ModelContainer` schema in `PocketTopApp.swift` with the PocketTop schema below.
2. **Fix deployment target.** `project.pbxproj` currently says iOS 26.4 — verify this is intentional (flagged in Resolved Decisions). Plan assumes iOS 17+ APIs are available.
3. **Add SPM dependencies** to `PocketTop.xcodeproj`:
   - `github.com/orlandos-nl/Citadel` (SSH)
   - No others — Keychain, URLSession, CryptoKit, LocalAuthentication are stdlib/frameworks.
4. **Create folder structure** under `PocketTop/PocketTop/`:
   - `App/` — app entry, root view, schema bootstrap
   - `Models/` — SwiftData `@Model` types
   - `Services/SSH/` — `SSHService` actor, `HostKeyCaptureValidator`, `SSHConnectionHelper`
   - `Services/Installer/` — `InstallerService`, install script bundler
   - `Services/Metrics/` — `MetricsService`, `MetricsSessionPool`, `CertPinningDelegate`
   - `Services/Keychain/` — `KeychainService`, `KeychainKey` enum
   - `Services/Recovery/` — `ConnectionRecoveryService`
   - `Features/AddServer/` — onboarding wizard views
   - `Features/Home/` — machine list / glance tiles
   - `Features/Detail/` — live metrics + process table + kill
   - `Resources/` — `pockettop_install.sh`, `pockettopd` binaries per arch (amd64, arm64)

---

## Phase 1 — SwiftData Models

**`Models/Server.swift`** — primary entity, adapted from ref doc §3 with PocketTop-specific fields:

```swift
@Model final class Server {
    var id: UUID
    var serverIdentity: String          // /etc/machine-id
    var name: String
    var host: String
    var sshPort: Int
    var sshUsername: String
    var httpsPort: Int                  // 443
    var osFamily: String = "linux"      // "linux" | "windows" | "macos" — V2/V3 ready
    var certFingerprint: String         // SHA-256 DER hex
    var sshHostKeyFingerprint: String
    var isInstalled: Bool
    var createdAt: Date
    var updatedAt: Date
    // auth
    var authMethodRaw: String = "password"   // "password" | "key"
    var keyType: String?
    var publicKeyFingerprint: String?
    var keyComment: String?
    var keychainKeyAccount: String?          // "app-shared-ssh-key" when BYO-key or installer-injected
    var sudoPasswordSaved: Bool = false
}
```

**Migration strategy:** all additions are optional-with-default (ref doc §3). `resetStoreFiles()` fallback in the app entry point deletes the store if schema bootstrap fails — acceptable because configs can be re-added.

No chat models — PocketTop has no conversation history to persist.

---

## Phase 2 — Keychain

**`Services/Keychain/KeychainService.swift`** — lift the `KeychainService` API verbatim from ref doc §8:

- `KeychainKey` enum: `sshPassword`, `sshPrivateKey`, `sudoPassword`, `apiKey`, `savedConnectionPassword`.
- Service identifier: `"com.bardiabarabadi.PocketTop"`.
- Biometry rules preserved: SSH keys = no biometry, sudo password = biometry, SSH password = no biometry with `AfterFirstUnlockThisDeviceOnly`.
- App-wide SSH key account: `"app-shared-ssh-key"`.

---

## Phase 3 — SSH Layer

**`Services/SSH/SSHService.swift`** — port the Citadel-backed actor from ref doc §4 without changes:

- `connect(host:port:username:password:expectedFingerprint:)`
- `connectWithEd25519Key(...)` and `connectWithRSAKey(...)`
- `execute(_:)` — full stdout capture
- `uploadFile(content:remotePath:)` — **base64 heredoc, not SFTP** (ref doc §4 gotcha)
- `disconnect()`

**`HostKeyCaptureValidator`** — custom `NIOSSHClientServerAuthenticationDelegate`, stores SHA-256 of serialized `NIOSSHPublicKey` in `Server.sshHostKeyFingerprint` on first connect, pins thereafter.

**`SSHConnectionHelper`** — single entry point used by installer and recovery; handles password-vs-key branch + Keychain lookup + host-key pinning.

**Sudo transport** (ref doc §4, §5): base64-encode the sudo password and pipe via stdin:
```
echo <b64> | base64 -d | sudo -S bash -c '…' 2>/dev/null
```
Cache `id -u` result per connection; skip `sudo` entirely if uid==0.

---

## Phase 4 — Server-Side Agent (`pockettopd`, Go)

A new Go module at `server/pockettopd/` (inside the repo for now; can split later).

### Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/health` | none | `{"status":"ok"}` |
| `GET` | `/version` | none | `{"version":"1.0.0","api":"v1"}` |
| `GET` | `/snapshot` | Bearer | one JSON object: host info + cpu/gpu/mem/disk/net totals + top-N processes |
| `POST` | `/processes/{pid}/kill` | Bearer | body: `{"signal":"TERM"\|"KILL"}` — returns `{ok:true}` or error |

A single `/snapshot` endpoint (vs `/cpu`, `/mem`, etc.) is the right call: the client's steady-state ask is *one* screen, one poll. Keeps the request count down and avoids cross-endpoint consistency headaches.

### Snapshot payload sketch

```json
{
  "ts": 1713312000,
  "host": { "uptime_s": 12345, "load": [0.4, 0.3, 0.2] },
  "cpu":  { "pct": 37.2, "per_core": [12.1, 55.3, ...] },
  "mem":  { "total": 16777216000, "used": 8123456000, "available": 8500000000 },
  "disk": { "read_bps": 120000, "write_bps": 45000, "fs": [{"mount":"/","used":..,"total":..}] },
  "net":  { "rx_bps": 12345, "tx_bps": 6789, "iface":"eth0" },
  "gpu":  [{"name":"NVIDIA 3060","util_pct":22,"mem_used":3200000000,"mem_total":12000000000}],
  "procs_top": [
    {"pid":1234,"user":"www","cpu_pct":42.1,"mem_rss":512000000,"name":"node","cmd":"node index.js"},
    ...  // top N=20 by CPU, ties broken by RSS
  ]
}
```

### Implementation notes (Go)

- stdlib `net/http` + TLS (no framework). One `http.ServeMux`, middleware for Bearer auth.
- Metrics source = `/proc` and `/sys` directly (avoid cgo). CPU% computed by sampling `/proc/stat` and `/proc/<pid>/stat` at process start and diffing per request.
- Maintain a cheap in-memory CPU sampler goroutine that refreshes every ~500ms so `/snapshot` reads cached deltas instead of sleeping inside the handler.
- GPU: shell out to `nvidia-smi --query-gpu=... --format=csv,noheader,nounits` if present; return `[]` otherwise. No AMD/Intel in V1 — stub extension points.
- Kill: `syscall.Kill(pid, SIGTERM)` with `SIGKILL` escalation on explicit request. Requires the service to run as root (it does — systemd unit runs as root, same as ref doc's `closeai.service`).
- Build matrix: `GOOS=linux GOARCH=amd64` and `GOOS=linux GOARCH=arm64`. Both binaries get bundled in the iOS app's resources; the install script picks the right one by `uname -m`.

### TLS & auth

Exactly as ref doc §6–§7:
- Self-signed EC (prime256v1) cert, 10-year expiry, **IP in `subjectAltName`** (iOS 14+ requires SAN; CN alone is ignored).
- `/opt/pockettop/.api_key` (chmod 600, root), generated by `openssl rand -hex 32` during install.
- User-readable cache at `~/.pockettop/api_key` + `~/.pockettop/cert_fp` so key-auth clients can recover without sudo (ref doc §9).

### systemd unit

`/etc/systemd/system/pockettopd.service` with `Restart=always`, `User=root`, `ExecStart=/opt/pockettop/pockettopd`, listens on `0.0.0.0:443`.

---

## Phase 5 — Installer (shell + iOS driver)

### `Resources/pockettop_install.sh`

Subcommands mirroring ref doc §5: `preflight`, `install`, `upgrade`, `status`, `uninstall`.

`install` steps (adapted from the 12-step CloseAI flow; PocketTop is simpler because no Python / Ollama):

1. Cleanup (systemd stop/disable, `rm -rf /opt/pockettop`, kill orphan `pockettopd`)
2. Firewall (`ufw allow OpenSSH`, `ufw allow 443/tcp`) — skip silently if `ufw` missing
3. Directories (`/opt/pockettop/{bin,certs}`, `~/.pockettop`)
4. Drop in `pockettopd` binary (already uploaded by iOS) at `/opt/pockettop/bin/pockettopd`
5. API key (`openssl rand -hex 32`, chmod 600)
6. Self-signed cert (EC prime256v1, 10-year, **IP SAN**)
7. Cache API key + cert fingerprint into `~/.pockettop/` (chmod 600)
8. systemd unit + `systemctl enable --now pockettopd`
9. Health check loop (`curl -k https://127.0.0.1:443/health` until 200)
10. Emit final JSON:
    ```json
    {"result":"success","api_key":"…","cert_fingerprint":"…","https_port":443,"version":"1.0.0"}
    ```

### Detached execution (ref doc §5 — critical)

The iOS `InstallerService` launches install via `nohup setsid` + PID file + log tailing so the install survives if SSH drops mid-flight:

```
/tmp/pockettop_launcher.sh:
  echo $$ > /tmp/pockettop_install.pid
  exec bash /tmp/pockettop_install.sh install > /tmp/pockettop_install.log 2>&1

# iOS runs:
nohup setsid bash /tmp/pockettop_launcher.sh > /dev/null 2>&1 < /dev/null &
```

The iOS side then polls `/tmp/pockettop_install.log` every 2s, parses JSON progress lines (`{"step":"…","status":"started"}`), and uses `[ -d /proc/<PID> ]` (**not** `kill -0`, ref doc §5) to check liveness — `kill -0` fails with EPERM when the SSH user can't signal root-owned processes.

### iOS upload pattern

`pockettopd` binaries (amd64 + arm64) are bundled in the app. `InstallerService.uploadAgentBinary(for: server)` reads `uname -m` over SSH, picks the right blob, base64-heredocs it (chunked — binaries are ~5MB, one big heredoc is fine but we verify size with `wc -c` afterward per ref doc §4).

---

## Phase 6 — HTTPS Client & Cert Pinning

**`Services/Metrics/CertPinningDelegate.swift`** — copy from ref doc §7 verbatim. Three non-negotiables:

1. `SecTrustEvaluateWithError` **must** be called before `.useCredential` (without it URLSession silently cancels with -999).
2. Use `SecPolicyCreateBasicX509()`, not the default SSL policy — the self-signed cert has only an IP SAN, no hostname.
3. Anchor: `SecTrustSetAnchorCertificates` + `SecTrustSetAnchorCertificatesOnly(true)` with the leaf cert.

**`Services/Metrics/MetricsSessionPool.swift`** — singleton keyed by `"host:port:certFP.prefix(16)"` (ref doc §7). Prevents multi-view cold-start hang. Polling clients share one warm `URLSession` with 5s request / 10s resource timeouts.

**`Services/Metrics/MetricsService.swift`** — one per open detail screen:

```swift
actor MetricsService {
    init(server: Server, apiKey: String)
    func start(interval: Duration) -> AsyncStream<Snapshot>   // polls /snapshot
    func stop()
    func kill(pid: Int32, signal: KillSignal) async throws
}
```

Polling loop uses `Task.sleep(for:)` between requests; cancels on `stop()` or task cancellation. Pauses when the app backgrounds (observe `ScenePhase`).

---

## Phase 7 — Onboarding (Add Machine Wizard)

`Features/AddServer/` — a multi-step sheet that mirrors CloseAI's setup flow but for PocketTop's much smaller server surface:

1. **Connection** — host, port, username, auth method picker (Password / SSH key).
2. **Auth detail** — password field *or* key import (paste PEM, or pick from Files; passphrase optional). Option to "Use the same app-wide key I already have" if one exists under `"app-shared-ssh-key"`.
3. **Host key confirmation** — after first SSH handshake, show fingerprint + "Trust this host?". Stored in `Server.sshHostKeyFingerprint` on accept.
4. **Sudo password** (if non-root user) — stored to Keychain *with biometry*.
5. **Install progress** — live log view backed by JSON progress polling. On the final `"result":"success"` line, persist `{api_key, certFingerprint, httpsPort}`, set `isInstalled=true`.
6. **Done** — push into the home screen.

BYO-key path: user pastes a PEM, we fingerprint it, offer to reuse across future machines (sets `keychainKeyAccount="app-shared-ssh-key"` if they agree).

---

## Phase 8 — Home & Detail UI

### Home (`Features/Home/`)

Scrollable list of `Server` rows. Each row is a glance tile: name, host, a 3-up sparkline band (CPU / mem / net), and a green/amber/red dot (derived from the latest snapshot). Tapping a row pushes to Detail.

The home view runs a **low-rate** poll (every 5s, `/snapshot` on each visible row) so tiles are always ~fresh. Shared via `MetricsSessionPool`.

### Detail (`Features/Detail/`)

Single-screen dashboard, top to bottom:

- Header: name, host, uptime
- Metric cards: CPU% (with per-core mini-bars), memory, disk read/write, network rx/tx, GPU(s) — live-updating at 1Hz
- Process table: top 20 by CPU, sortable by CPU / memory. Each row: pid, user, name, CPU%, RSS.
- **Kill action:** tap a row → action sheet with "Terminate (SIGTERM)" (default) and "Force kill (SIGKILL)" (destructive style, requires a second tap). No undo, but the short confirm step satisfies the "act in one tap, but not by accident" principle from the Executive Summary.

Polling cadence: 1s while screen visible + foreground, pause on background / navigation-away.

---

## Phase 9 — Reconnection & Recovery

**`Services/Recovery/ConnectionRecoveryService.swift`** — port from ref doc §9, simplified:

- Password-auth: SSH connect → read `/opt/pockettop/.api_key` with sudo → compute cert FP via `openssl x509 -fingerprint -sha256 -in /opt/pockettop/certs/server.crt` → disconnect SSH → return `ConnectionDetails`.
- Key-auth: SSH connect → try `~/.pockettop/api_key` + `~/.pockettop/cert_fp` cache first (no sudo) → fallback to sudo + root-only files → throw `sudoPasswordRequired` if no saved sudo password.
- `verifyConnection()`: up to 10 attempts polling `/version` then one authenticated `/snapshot`, 300ms between attempts.

Called on app launch for every `isInstalled == true` server, concurrently; failures surface as a "can't reach" state on the home tile rather than blocking the UI.

---

## Phase 10 — Multi-OS Forward-Compatibility

The `Server.osFamily` field and a thin protocol around the installer/agent will let Windows and macOS slot in without schema migration:

- `InstallerStrategy` protocol with implementations: `LinuxInstaller`, `WindowsInstaller` (later), `MacOSInstaller` (later).
- `pockettopd` Go module is cross-compilable; Windows gets `GOOS=windows` + a different service wrapper (nssm / WinSW) + WMI/PDH for metrics. macOS gets launchd + `host_statistics64` / `libproc`.
- HTTP API contract stays identical across platforms — only the agent implementation and installer differ.

No Windows/macOS code here — just the seams.

---

## Critical Files to Create

| Path | Purpose |
|---|---|
| `PocketTop/PocketTop/App/PocketTopApp.swift` (rewrite) | ModelContainer + schema bootstrap |
| `PocketTop/PocketTop/App/RootView.swift` | Top-level navigation |
| `PocketTop/PocketTop/Models/Server.swift` | `@Model` |
| `PocketTop/PocketTop/Services/SSH/SSHService.swift` | Citadel actor |
| `PocketTop/PocketTop/Services/SSH/HostKeyCaptureValidator.swift` | Pinning delegate |
| `PocketTop/PocketTop/Services/SSH/SSHConnectionHelper.swift` | Shared connect util |
| `PocketTop/PocketTop/Services/Installer/InstallerService.swift` | Detached install + log poll |
| `PocketTop/PocketTop/Services/Metrics/MetricsService.swift` | Polling client |
| `PocketTop/PocketTop/Services/Metrics/MetricsSessionPool.swift` | URLSession pool |
| `PocketTop/PocketTop/Services/Metrics/CertPinningDelegate.swift` | Pinning |
| `PocketTop/PocketTop/Services/Keychain/KeychainService.swift` | Wrapper |
| `PocketTop/PocketTop/Services/Recovery/ConnectionRecoveryService.swift` | Reconnect |
| `PocketTop/PocketTop/Features/AddServer/AddServerFlow.swift` | Wizard |
| `PocketTop/PocketTop/Features/Home/HomeView.swift` | Machine list |
| `PocketTop/PocketTop/Features/Detail/DetailView.swift` | Live dashboard |
| `PocketTop/PocketTop/Resources/pockettop_install.sh` | Server install script |
| `PocketTop/PocketTop/Resources/pockettopd-linux-amd64` | Bundled agent binary |
| `PocketTop/PocketTop/Resources/pockettopd-linux-arm64` | Bundled agent binary |
| `server/pockettopd/main.go` | Go HTTP server |
| `server/pockettopd/metrics/*.go` | `/proc`, `/sys`, `nvidia-smi` collectors |
| `server/pockettopd/Makefile` | Cross-compile both arches |

Files to delete: `PocketTop/PocketTop/Item.swift`, the template `ContentView.swift` body (replace wholesale).

---

## Reused Patterns (by ref doc section)

- **§3 SwiftData migration:** optional-with-default fields + `resetStoreFiles()` fallback.
- **§4 SSH:** Citadel actor, base64-heredoc upload (no SFTP), host-key pinning, sudo-via-base64-stdin, `id -u` caching.
- **§5 Installer:** `nohup setsid` + PID file + `[ -d /proc/PID ]` liveness + JSON log lines + final success object + post-install verification.
- **§7 TLS:** `SecTrustEvaluateWithError`, `SecPolicyCreateBasicX509`, anchor with `SetAnchorCertificatesOnly(true)`.
- **§7 Session pool:** singleton `MetricsSessionPool` to avoid cold-start hang.
- **§8 Keychain:** biometry policy per secret type; app-wide SSH key account.
- **§9 Recovery:** password vs key branch, user-cache-first-then-sudo for key auth.
- **§12 Gotchas to carry forward:** apt lock wait (install step 2), stderr suppression on sudo, IP-SAN requirement, URLSession.bytes incompatibility (use `didReceive(data:)` if/when we add streaming later), `@State` race in nav, post-install `disconnect()` before pushing to home.

---

## Verification

1. **Build:** `xcodebuild -project PocketTop/PocketTop.xcodeproj -scheme PocketTop -destination 'platform=iOS Simulator,name=iPhone 16' build`.
2. **Agent unit tests:** `cd server/pockettopd && go test ./...` — snapshot JSON schema, `/proc` parsing, top-N selection, kill signal resolution.
3. **End-to-end on a real Linux VM** (Ubuntu 22.04 or 24.04 in OrbStack / UTM / cloud):
   - Add the machine via password auth → wait for install → see the home tile go live.
   - Open detail, confirm CPU/mem/net tick at ~1Hz, match `top`/`htop` roughly.
   - Run `yes > /dev/null &`, verify it climbs the process list, kill it from the app, confirm it's gone (`pgrep yes`).
   - Force-quit the app, reopen, confirm the server reconnects without prompting for sudo (user-readable cache path for key-auth; SSH-password path for pw-auth).
   - Change the host key on the server (`ssh-keygen -A` + reboot sshd) → confirm the app blocks the connection with a "host key changed" warning.
4. **Second Linux host with ARM** (Raspberry Pi 5 or EC2 Graviton) — confirms `arm64` binary selection works.
5. **Cert pinning negative test:** swap the server's cert for a different self-signed one → confirm the app refuses to connect rather than silently trusting.

---

## Resolved Decisions

1. **iOS deployment target:** iOS 17+. Current `project.pbxproj` value of 26.4 is treated as an artifact and will be lowered to `17.0` (or the latest stable SDK available at implementation time) during Phase 0.
2. **GPU support:** NVIDIA only via `nvidia-smi`. AMD (`rocm-smi`) and Intel are future work. Snapshot schema already allows a multi-GPU array, so no schema change later.
3. **Process-kill UX:** tap row → action sheet with "Terminate (SIGTERM)" default and "Force kill (SIGKILL)" destructive-style. No single-tap / swipe-to-kill.
4. **Privilege model:** matches CloseAI exactly — `User=root` in the systemd unit, sudo only at install/upgrade, never at steady state. No dedicated service user, no capability juggling.
