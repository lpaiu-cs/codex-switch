# Changelog

All notable changes to this project are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Release tags are `v<version>` (e.g. `v1.0.0`), and `codex-switch.ps1 -Version` reports the
version of the copy you have.

## [1.0.0] - 2026-09-08

First release. A sibling of [claude-switch](https://github.com/lpaiu-cs/claude-switch) for Codex,
redesigned around how Codex actually stores an account (see [docs/DESIGN.md](docs/DESIGN.md)).

### Added

- **Single-file profile switching.** A Codex profile is `auth.json` and nothing else: everything
  else under `CODEX_HOME` (sessions, sqlite thread index, memories, plugins, skills, config) is
  shared by the desktop app, the CLI and the VS Code extension and carries no account identity.
  Switching **moves** the live `%USERPROFILE%\.codex\auth.json` into `.codex-profiles\<outgoing>\`
  and the target's file back in. Sessions and settings are shared across accounts as a result.
- **Move, never copy.** The ChatGPT refresh token rotates on every use, so a stale copy is a dead
  login. The active profile's folder never holds an `auth.json`; a parked copy found there is
  kept as a dated `.bak` and the live file wins.
- **`-Stop`**: closes the Codex desktop app (MSIX, exe named `ChatGPT.exe`) and every
  `codex.exe` regardless of who started it - terminal sessions, the VS Code extension's
  app-server, node / node_repl / pwsh runtimes, sandbox helpers - matched by image path so the
  regular ChatGPT app (a different package with the same exe name) is left alone. The shell the
  script runs from is protected even when Codex spawned it.
- **Account identity in listings.** `-List`, `-Menu` and `-Status` decode the `id_token` JWT
  locally to show each profile's e-mail, plan and token freshness. No network, no quota.
- **Guards**: refuses to run when `config.toml` sets `cli_auth_credentials_store` to anything but
  `file` (the keyring slot is keyed by the `CODEX_HOME` path, so profiles would collide); profile
  name validation; cross-process lock with 5-minute stale recovery; rollback of a failed
  activation; the profile store is ACL-restricted to the current user because Codex sets no
  Windows permissions on `auth.json`.
- **CLI-only support.** If the desktop app is not installed the switch works the same and just
  skips the launch. `CODEX_HOME` is honoured; the store then lives at `<CODEX_HOME>-profiles`.
- Double-click helpers: `시작하기.cmd`, `menu.cmd`, `list.cmd`, `status.cmd`, `stop.cmd`,
  `1-main.cmd`, `2-work.cmd`; Korean manual `사용설명서.md`; release packaging and workflow ported
  from claude-switch.

### Not included (planned)

- `-Isolated` mode that also moves `sessions/`, `archived_sessions/`, `session_index.jsonl`,
  `thread_history_1.sqlite`, `state_5.sqlite`, `memories/` per profile for users who need thread
  history kept apart between accounts.

[1.0.0]: https://github.com/lpaiu-cs/codex-switch/releases/tag/v1.0.0
