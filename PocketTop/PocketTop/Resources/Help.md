# PocketTop

A pocket-sized iOS app for checking on and acting on your Linux homelab machines. See CPU, GPU, memory, disk, and network at a glance, spot hot processes, and kill them from your phone.

## How it works

When you add a machine, PocketTop SSHes in once to install a tiny Go agent (`pockettopd`) under `systemd`, then disconnects. From then on the app talks to the agent over a certificate-pinned HTTPS connection — no more SSH needed for day-to-day use.

## Adding a machine

1. Tap the **+** button in the top-right of the machine list.
2. Enter the host, port, and username.
3. Pick password or SSH key authentication.
4. If the user is non-root, enter the sudo password (only used for the install).
5. Confirm the SSH host-key fingerprint the first time you connect — this pins the host so we can detect a swapped server later.
6. Wait for the install to finish. The agent survives SSH drops, so a flaky connection won't wreck the install.

## The machine list

Each row is a **self-polling glance tile**: it pulls recent history from the agent every 5 seconds and shows three sparklines (CPU, memory, combined network throughput) plus a red/amber/green dot.

- **Green** — CPU below 70% and memory below 85% used.
- **Amber** — CPU 70–89% or memory above 85%.
- **Red** — CPU at 90%+ or the agent has been unreachable for more than 15 seconds.

Swipe a row left or long-press it to **rename** or **delete** the machine.

## The detail screen

Tap a machine to open the live dashboard. It polls at 1 Hz while visible and shows:

- **Overview rings** — CPU, each GPU, RAM, Disk I/O, Network.
- **Usage graphs** — CPU (overall or per-core), per-GPU, RAM, Disk I/O, Network over the last 5 minutes.
- **Power & Thermal** — watts and temperatures for CPU and each GPU.
- **Processes** — top 10 by default; tap **Show all** to fetch the full list. Tap a process to kill it (SIGTERM or SIGKILL).

The **…** menu at the top-right lets you rename or delete this machine.

## What PocketTop is not

- Not an RMM. No fleet management, policy, or patching.
- Not a paging or alerting system. No background notifications.
- Not a metrics historian. The 5-minute window is kept in RAM on the agent and is lost on restart.
- Not an SSH terminal. SSH is used only for install and recovery.

## Privacy & security

- All secrets (SSH password or key, sudo password, API token) live in the iOS Keychain on your device — they are never synced off-device.
- The agent accepts only connections authenticated with its per-install API token and only from clients that pin its TLS certificate fingerprint.
- The app does not send telemetry. No analytics, no crash reporting.

## Source & issues

PocketTop is open source under GPL-3.0.

- Source: [github.com/bardiabarabadi/PocketTop](https://github.com/bardiabarabadi/PocketTop)
- Issues & feature requests: [github.com/bardiabarabadi/PocketTop/issues](https://github.com/bardiabarabadi/PocketTop/issues)
