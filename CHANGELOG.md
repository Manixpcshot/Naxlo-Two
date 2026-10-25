# Changelog

All notable changes to **Naxlo Two** are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions are not hand-edited: `VERSION` is the single source of truth,
`scripts/set_version.sh` fans it out to `packages/naxlo_core/lib/src/version.dart`
and `app/pubspec.yaml`, and `.github/workflows/auto-release.yml` bumps it from
conventional-commit subjects on every merge to `main`. Tag `vX.Y.Z` ⇒ GitHub
Release ⇒ regenerated [`release`](./release) manifest (see `docs/PACKAGING.md`).

## [Unreleased]

## [0.1.0] — 2026-10-25

First public build. Everything below ships in this tag.

### Added

* **`packages/naxlo_core`** — pure-Dart engine with no Flutter dependency, so the
  ranking math is unit-testable on its own (`dart test`, 8 suites).
* **Ranking, two modes.** `simple` is a ping-style ordering (latency + a little
  reliability). `advanced` scores an EWMA of latency (gap-aware, half-life
  decaying), jitter, a Jeffreys-LCB reliability estimate, throughput, sample
  freshness and stability, then adds a Thompson-sampled exploration term so a
  never-probed node gets one honest chance instead of sitting at the bottom
  forever. Switching needs to beat the current node by `switchMargin` and hold
  the lead for `dwellMs`; the cooldown doubles after repeated flips.
  Weights, half-life, margin, dwell, cooldown and exploration are all user-tunable,
  with `balanced` / `speed` / `stability` presets. Manual pin always wins.
* **Engines:** Xray-core (default) and sing-box as a second engine, per profile.
  Config is generated, then verified with `xray test` / `sing-box check` before the
  process is accepted; logs are tailed into the Logs screen; unexpected exits are
  restarted with capped exponential backoff and a kill-switch.
* **Import:** `vless://` (incl. Reality), `vmess://`, `trojan://`, `ss://` (SIP002),
  `socks5://`, plus subscription URLs (base64 link lists, `subscription-userinfo`
  quota/expiry headers, `package-info` update hints) with add/remove merge reports
  that keep per-node measurement history.
* **Routing:** presets (proxy-all, bypass LAN, direct-first, block ads), an ordered
  rule list (domain / suffix / keyword / regex / CIDR → proxy | direct | block),
  per-profile DNS strategy with leak protection, and a live "what would this host
  do" preview.
* **Connectivity:** SOCKS5 and HTTP(mixed) inbounds on loopback, system-proxy
  takeover on Windows (WinINET + winhttp), macOS (`networksetup`) and Linux
  (`gsettings`) with snapshot/restore so quitting never leaves a dead proxy behind,
  and TUN via sing-box when privileges allow.
* **Probe:** median-of-N TCP connect timing plus one real TLS handshake (correct
  SNI and ALPN) so a broken Reality key or SNI is caught before it is routed
  through; worker pool sized by `probeConcurrency`; four-phase `ProbeLoop`
  (unknown → active → stale → idle) keeps traffic cheap.
* **Updater:** reads the `release` manifest at this repo root, compares semver,
  honours `block` / `minSupported` / `warnalways` / `updateonly`, and downloads
  only after `sha256` verification (never installs an unverified artifact).
* **UI:** six-section shell (rail ≥ 720 px, `NavigationBar` below), per-node score
  breakdown sheets with the raw evidence behind them (decayed ok/fail weights,
  age, sample counts), traffic sparkline, logs with severity colouring and a
  ranker explanation block, profile manager with quota bars, English / فارسی /
  Русский / العربية with full RTL.
* **Storage:** atomic write (tmp + rename) with three rolling backups and
  quarantine-on-corruption, so a power cut mid-save cannot lose a profile.
* **CI/CD:** `dart analyze` + `dart test` for the core, `flutter analyze` +
  `flutter test` for the app, a tag-driven multi-platform release pipeline, and
  automatic semver bumping on merge to `main`.

### Known limitations in 0.1.0

* Platform folders (`app/android`, `app/ios`, `app/linux`, `app/macos`,
  `app/windows`) are generated, not vendored — run `scripts/bootstrap_platforms.sh`
  once before `flutter run` (see `docs/PACKAGING.md`).
* Engine binaries are fetched at build time by `scripts/fetch_engine.sh`; they are
  never committed.
* Traffic totals are parsed from the engine's access log (an estimate, labelled as
  one) — Xray's gRPC stats API is not wired in.
* iOS is build-from-source only; there is no signed, distributable NEProvider
  tunnel in this repo. TUN on Apple platforms therefore needs the Network
  Extension scaffold you supply.
* `packaging/` provides Debian/Arch/RPM templates; `.deb`/`.rpm`/`.pkg.tar.zst`
  are assembled in CI, and a Windows installer uses Inno Setup.

[Unreleased]: https://github.com/Manixpcshot/Naxlo-Two/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Manixpcshot/Naxlo-Two/releases/tag/v0.1.0
