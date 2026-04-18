# Pocket Top

*A pocket-sized view of what your machines are doing — and a way to act on it.*

## The Problem

People who run their own machines — a homelab box in the basement, a gaming PC upstairs, a work laptop at the office, a handful of Linux VMs — have no simple way to check on those machines when they're not sitting in front of them.

The moments when you actually need this are small and frequent:

- You left a long build, a game download, or a training run going, and you want to know if it's finished before you head home.
- Your home server feels sluggish from across the room and you want to know *why* without walking over and plugging in a keyboard.
- A process is pegged at 100% CPU and you want to kill it now, from wherever you are, without SSHing in on a phone keyboard.
- You just want the quiet reassurance, once in a while, that your machine is still healthy.

None of these are emergencies. None of them justify a dashboard, an agent-fleet, a ticketing system, or an on-call rotation. They are small questions asked often, and today the answer to each one takes far more effort than the question deserves.

## Who Feels This

Not enterprises. Enterprises have monitoring stacks, and the people running them get paid to learn Grafana.

The people who feel this pain are individuals:

- Homelab owners with one to five machines.
- Developers who leave long-running jobs on a workstation.
- Power users who treat their home PC as an always-on resource (media server, game host, AI workloads, file share).
- Small-team tinkerers and hobbyists.

They manage their own infrastructure because they want to, not because it's their job. They are technically capable but time-poor. They don't want to run a server to monitor their server.

## Why Existing Tools Don't Fit

The market has two camps, and neither is built for this person.

**Enterprise monitoring and RMM tools** (Pulseway, Site24x7, SolarWinds, OpManager, Atera) do the job on paper but are sized for managing fleets for a business. Their pricing, onboarding, UI density, and feature scope all assume a professional context. For a person with two machines at home, they are wildly disproportionate — like renting a forklift to move a grocery bag.

**Consumer-friendly monitors** (iStat, Stats, Glances) look right but are observational only. You can see the CPU graph; you cannot kill the process causing it. The moment something is wrong, you still have to get to a real terminal.

**SSH on a phone** is the default fallback and it is miserable. Typing `htop` on a 6-inch touchscreen, squinting at a 120-column process list, trying to tap the right PID — this is what the app exists to replace.

The gap is a tool that is *simple enough to be casual* and *capable enough to act*, for people who own their machines personally.

## What Success Looks Like

A Pocket Top user should be able to, within seconds of opening the app:

- See at a glance whether each of their machines is healthy.
- Drill into CPU, GPU, memory, disk I/O, and network activity when something looks off.
- Identify which process is responsible for what they're seeing.
- End that process, if they choose to, without leaving the app.

And then close the app and get on with their day. The whole interaction should feel closer to checking the weather than to logging into a console.

## Platforms & Priority

- **Monitored machines:** Linux first, Windows second, macOS third.
- **Client:** iOS first. Web later.

## What Pocket Top Is Not

- Not an RMM tool for managing other people's computers.
- Not an alerting/paging/on-call system.
- Not a metrics-history-and-dashboards product.
- Not a replacement for SSH or a terminal emulator.

It is the answer to one question, asked often: *what is my machine doing right now, and do I need to do anything about it?*
