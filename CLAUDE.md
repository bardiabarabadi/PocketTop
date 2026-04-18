# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project State

PocketTop is an iOS app for monitoring and acting on personal/homelab machines. The Linux end-to-end flow is shipped: the iOS app SSHes into a target host, installs a Go agent (`pockettopd`) under systemd, disconnects, and then talks to the agent over cert-pinned HTTPS to poll metrics and kill processes. Windows host support is planned (`docs/Windows_Implementation.md`); macOS is further out.

Source layout:
- `PocketTop/` — Xcode project (iOS app, SwiftUI + SwiftData).
- `server/pockettopd/` — Go agent source. Cross-compiled binaries are committed at `PocketTop/PocketTop/Resources/pockettopd-linux-{amd64,arm64}` so the iOS app can bundle them without a fresh build.
- `docs/` — design docs (see below).

## Product Intent

The intended product is described in `docs/Executive Summary.md`:
- A pocket-sized iOS app for checking on and acting on personal/homelab machines (see CPU/GPU/mem/disk/net, identify hot processes, kill them) — a middle ground between observation-only tools (iStat, Glances) and heavyweight RMM stacks (Pulseway, Site24x7).
- **Platform priority:** monitored machines = Linux → Windows → macOS; client = iOS → web.
- **Anti-goals:** not an RMM, not a paging/alerting system, not a metrics-history dashboard, not an SSH terminal replacement.

When adding features, weigh them against the "simple enough to be casual, capable enough to act" framing in the Executive Summary — it is the north star for scope calls.

## Architecture Reference

`docs/SSH_App_Architecture_Reference.md` is the canonical architectural playbook, extracted from a sibling app (CloseAI) whose SSH + install + cert-pinning pattern is reused here. Before designing anything that touches SSH, installers, TLS, credentials, or reconnection, **read the relevant section first** — it captures gotchas that are not obvious from the code (e.g., avoid Citadel SFTP, use base64-heredoc upload; `[ -d /proc/PID ]` instead of `kill -0` for sudo'd installers; `SecTrustEvaluateWithError` must be called before `.useCredential`; pass sudo via base64-piped stdin).

Key patterns:
- **SSH layer:** actor wrapping Citadel `SSHClient`; host-key fingerprint pinning stored in SwiftData; sudo password piped via base64 stdin.
- **Persistence:** SwiftData `@Model` classes, one `ModelContainer` configured in the `@main` App struct. New fields use optional-with-default for lightweight migration; a `resetStoreFiles()` fallback deletes the store if migration fails.
- **Remote lifecycle:** short-lived SSH only for admin/install/recovery; steady-state client talks to a cert-pinned HTTPS API on the server. Install scripts run **detached** (systemd-run into system.slice + PID file + log tailing) so install survives SSH drops.
- **Secrets:** iOS Keychain via `Security.framework`, with an app-wide shared SSH keypair under account `"app-shared-ssh-key"`.

Platform-specific build docs:
- `docs/Linux_Implementation.md` — the shipped Linux host implementation.
- `docs/Windows_Implementation.md` — planned Windows host implementation.

## Build & Run

Standard Xcode project — open and build via Xcode or xcodebuild. There is no Swift Package Manager manifest at the repo root, no test target yet, no linter config, and no CI.

```bash
# Open in Xcode
open PocketTop/PocketTop.xcodeproj

# Build from CLI (adjust destination as needed)
xcodebuild -project PocketTop/PocketTop.xcodeproj -scheme PocketTop \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Go agent has its own build:

```bash
cd server/pockettopd
make build-all   # dist/pockettopd-linux-{amd64,arm64}
```

Project settings worth knowing:
- **Deployment target:** iOS 26.4 (set in `project.pbxproj`) — be deliberate before lowering it; SwiftData and several APIs the reference doc uses are iOS-17+, and some newer-OS APIs may have been assumed.
- **Bundle ID:** `com.bardiabarabadi.PocketTop`.
- **Go module path:** `github.com/bardiabarabadi/PocketTop/server/pockettopd`.
- **Device family:** iPhone + iPad (`TARGETED_DEVICE_FAMILY = "1,2"`).
- **Swift:** 5.0.

## License

GPL-3.0 — see `LICENSE`. Contributions are licensed under the same.
