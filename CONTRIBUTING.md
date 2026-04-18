# Contributing

Thanks for your interest in PocketTop. This is a personal project — contributions are welcome but responses may be slow.

## Before opening a PR

- Keep changes focused. One feature or bug fix per PR.
- Test the relevant flow end-to-end — add a machine, open the detail view, kill a process — for any change that touches SSH, install, metrics, or the HTTPS path. Unit-level checks aren't enough for those layers.
- Match the existing code style: SwiftUI + SwiftData on iOS, idiomatic Go (stdlib where possible) for the agent.
- New dependencies are a big deal. Open an issue first to discuss.

## Filing issues

Useful info to include:
- iOS version and Xcode version.
- Monitored host's OS and distribution.
- Steps to reproduce.
- Expected vs. actual behavior.
- Relevant logs — Xcode Console for the iOS side, `journalctl -u pockettopd` on the Linux agent side.

## Where help would be welcome

- **Windows host support.** The plan is in [`docs/Windows_Implementation.md`](docs/Windows_Implementation.md).
- **macOS host support.** No plan yet — needs a macOS equivalent of the Linux `/proc`-backed metrics.
- **Web client.** The agent's HTTPS API is client-agnostic — a browser client is doable.
- **Screenshots and UI polish.**
- **Getting-started docs.** Especially a walkthrough with a test VM.

## License

By contributing, you agree your contributions are licensed under GPL-3.0, the same license as the rest of the project.
