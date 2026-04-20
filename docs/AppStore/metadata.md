# App Store Connect — Metadata

Everything to paste into App Store Connect for the initial **PocketTop 1.0** submission. Lengths are Apple's hard caps; keep edits within them.

## App information

| Field | Value |
|---|---|
| **Name** (≤30) | `PocketTop` |
| **Subtitle** (≤30) | `Open-source homelab monitor` |
| **Bundle ID** | `com.bardiabarabadi.PocketTop` |
| **SKU** | `pockettop-ios-001` |
| **Primary language** | English (U.S.) |
| **Primary category** | Utilities |
| **Secondary category** | Developer Tools |
| **Content rights** | Does not contain, show, or access third-party content. |
| **Age rating** | 4+ (all answers "None"; no unrestricted web access) |
| **Copyright** | `© 2026 Bardia Barabadi` |

## URLs (all served from GitHub Pages — see `checklist.md`)

| Field | Value |
|---|---|
| **Support URL** (required) | `https://bardiabarabadi.github.io/PocketTop/AppStore/support.html` |
| **Privacy Policy URL** (required) | `https://bardiabarabadi.github.io/PocketTop/AppStore/privacy.html` |
| **Marketing URL** (optional) | `https://github.com/bardiabarabadi/PocketTop` |

## Pricing & availability

- **Price:** Free
- **In-App Purchases:** None at launch (kept available for later — IAPs added after first release do not require a fresh App Review of the app itself).
- **Availability:** All territories.
- **Pre-orders:** Off.

## Promotional text (≤170 chars, editable any time without re-review)

```
Live CPU, GPU, RAM, disk, and network for the Linux machines you own. Tap to kill a hot process. Open source, no cloud, no SSH on a phone keyboard.
```
*(147 characters)*

## Description (≤4000 chars)

```
PocketTop is a pocket-sized view of what your Linux machines are doing — and a way to act on it.

Live readings. The hottest processes. Tap to kill one. Then close the app and get on with your day.

Built for people who run their own machines: a homelab box in the basement, a gaming PC upstairs, a workstation at the office, a few Linux VMs in the cloud. Not for fleets, not for paging, not for dashboards you stare at all day.

WHAT YOU SEE
• CPU per-core, GPU usage, RAM, swap, disk I/O per device, network throughput per interface.
• Per-mount storage usage with free / used breakdowns.
• CPU and GPU power draw and temperatures, when the host exposes them.
• Uptime, load average, and the kernel a machine is running.
• A 5-minute rolling history with stacked charts you can scroll through.
• A live process table — sortable by CPU, memory, PID, user, command — top 10 by default, expandable to show all.

WHAT YOU CAN DO
• Tap a process to terminate it. Sends SIGTERM first, then SIGKILL if it won't go.
• Add or remove machines in seconds.
• Watch multiple machines from the home screen with at-a-glance health tiles.

HOW IT WORKS
PocketTop adds machines through a one-time SSH setup: enter host, port, user, and credentials, confirm the host-key fingerprint, and the app installs a tiny Go agent on your Linux box under systemd. From then on, the iOS app talks to the agent over HTTPS with certificate pinning. SSH is not used for steady-state monitoring. There is no cloud server in between — the app on your phone talks directly to your machine.

WHAT IT IS NOT
• Not an RMM tool for managing other people's computers.
• Not an alerting / paging / on-call system.
• Not a long-term metrics-history-and-dashboards product.
• Not a replacement for SSH or a terminal emulator.

REQUIREMENTS
• A Linux host running systemd (Debian, Ubuntu, Fedora, Arch — anything modern).
• SSH access with a user that can sudo (only needed for the one-time install).
• The host can listen on TCP port 443. The installer will fall back to 8443/9443/18443 and open ufw if present.

PRIVACY
• PocketTop ships with no analytics, no crash reporting, and no third-party SDKs.
• Your machine credentials live in the iOS Keychain on your device.
• The app talks only to the Linux machines you point it at — there is no PocketTop cloud.

OPEN SOURCE
PocketTop is GPL-3.0. Source for the iOS app and the Go agent is on GitHub: github.com/bardiabarabadi/PocketTop

A simple tool for a small but frequent question: what is my machine doing right now, and do I need to do anything about it?
```
*(~2,400 characters; well under the 4,000 cap.)*

## Keywords (≤100 chars, comma-separated, no spaces)

```
linux,server,monitor,ssh,homelab,htop,sysadmin,cpu,gpu,ram,process,devops,nas,vps,opensource
```
*(92 characters)*

**Notes:**
- No competitor app names (App Review will reject those).
- All terms are generic / tool category names, safe to use.
- "htop" / "glances" are open-source utilities, not competing apps — fine to keep.

## What's New in This Version (≤4000 chars, version 1.0)

```
First public release of PocketTop.

• Live CPU, GPU, memory, disk, and network metrics for Linux hosts.
• 5-minute rolling history with scrollable Swift Charts.
• Sortable process table with one-tap process kill.
• One-time SSH setup; certificate-pinned HTTPS for steady-state polling.
• iPhone and iPad support.
• Free and open source under GPL-3.0. No accounts, no cloud, no analytics.
```

## App Review Information

| Field | Value |
|---|---|
| **First name** | Bardia |
| **Last name** | Barabadi |
| **Phone number** | *(your phone, required by Apple — not displayed publicly)* |
| **Email** | *(your email, required by Apple — not displayed publicly)* |
| **Sign-in required** | **No** |
| **Demo account** | Not applicable (see notes below) |

### Notes for the App Review team

```
PocketTop is a "bring your own server" tool: it monitors a Linux machine that the user controls. There is no PocketTop backend service, no demo cloud, and no built-in account system. Reviewers will need a Linux host (any modern distribution with systemd, e.g. Ubuntu 22.04+) reachable over SSH to fully exercise the app.

Setup flow to verify:
1. Tap "+" on the home screen.
2. Enter SSH host, port (22), username, and credential (password or paste an SSH private key).
3. Confirm the host-key fingerprint when prompted.
4. The app uploads an embedded Go binary (pockettopd-linux-amd64 or arm64) to the host, runs the installer over SSH, and starts pockettopd as a systemd service. The installer needs sudo for this one-time step.
5. The host appears on the home screen. Tap it to see live CPU / GPU / memory / disk / network and the process table.
6. From the process table, tap a process row to terminate it (SIGTERM, escalating to SIGKILL).

Network behaviour:
- All connections are from the iOS device directly to the user-provided Linux host.
- Steady-state monitoring uses HTTPS (TCP 443 by default, falling back to 8443/9443/18443) with certificate pinning against a self-signed cert generated on the host during install.
- The "Local Network" permission is requested because users typically point PocketTop at RFC1918 hosts on their LAN. Without this entitlement, iOS returns EPERM on private-range connects.

If the reviewer cannot easily provision a Linux host, please contact us via the support URL — we are happy to provide temporary SSH credentials to a test VM.

PocketTop is open source under GPL-3.0. Full source for the iOS app and the agent: https://github.com/bardiabarabadi/PocketTop
```

## App Privacy ("Data Types")

Answer in App Store Connect → App Privacy:

- **Do you or your third-party partners collect data from this app?** **No**

That single answer produces a "Data Not Collected" privacy nutrition label. PocketTop does not collect any data on Apple's terms because:
- No analytics SDK.
- No crash reporter.
- No third-party SDKs at all.
- All credentials and host metadata stay on the device (iOS Keychain + on-device SwiftData store).
- All network traffic is from the user's device directly to the user's own machines; the developer never sees it.

If App Review pushes back asking how the app communicates without any data collection, the answer is: it talks to user-controlled servers, and no data is sent to the developer or any third party.

## Export Compliance

- The app uses HTTPS / TLS via the iOS system frameworks (URLSession + SecTrust) and SSH via the Citadel Swift package.
- No proprietary cryptography; only standard, widely available encryption shipped with the OS or used as transport security.
- This qualifies for the **standard exemption** under U.S. Export Administration Regulations §740.17(b)(1).

Set in Info.plist (auto-generated by Xcode from build settings — see `checklist.md`):

```
ITSAppUsesNonExemptEncryption = NO
```

With that key set, App Store Connect skips the encryption questionnaire on every upload.

## Version & Build Numbers

| Field | Value |
|---|---|
| **Marketing version** (`CFBundleShortVersionString`) | `1.0` |
| **Build number** (`CFBundleVersion`) | `1` |
| **Minimum iOS** | `17.0` (current `IPHONEOS_DEPLOYMENT_TARGET`) |

Increment the build number on every TestFlight upload; bump the marketing version for user-visible releases (1.0 → 1.0.1 → 1.1, etc.).

## Localization

Single locale at launch: **English (U.S.)**. Add others later if there is demand.
