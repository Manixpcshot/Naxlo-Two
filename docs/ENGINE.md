# Engine integration

Naxlo Two is a Flutter/Dart application that *configures and supervises* a proxy
engine. It never links engine code into its own process, and the engine never
links ours. That boundary is the whole design, so it is documented precisely.

## Two engines, one interface

| | [Xray-core](https://github.com/XTLS/Xray-core) | [sing-box](https://github.com/SagerNet/sing-box) |
| --- | --- | --- |
| Language | Go | Go |
| License | MPL-2.0 | GPL-3.0 |
| Config | one JSON file, `log`/`inbounds`/`outbounds`/`routing`/`dns` | one JSON file, `log`/`inbounds`/`outbounds`/`route`/`dns` |
| Verify before run | `xray test -config <file>` | `sing-box check -c <file>` |
| Version | `xray version` | `sing-box version` |
| TUN | not in the standalone build | `inbounds[0].type = "tun"` |
| Reality | yes (VLESS, `security: reality`) | yes |
| Invocation | `xray run -config <file>` | `sing-box run -c <file>` |

The choice is **per profile** (`Profile.engine`), not per app, because the two are
good at different things and a user with both should not have to pick globally. The
enum with the CLI shapes lives in
`packages/naxlo_core/lib/src/models/engine_kind.dart` (`cliName`, `runArgs`,
`verifyArgs`), so nothing in the UI hard-codes an argument list.

## Process lifecycle

`app/lib/state/engine_service.dart` owns the child process. Nothing else spawns
anything.

```
                    ┌──────────── generate ────────────┐
Profile + ServerNode + RuntimeSettings                 │
                    └──────────── write file ───────────┘
                                    │
                    config.json  (in the support dir, one per profile)
                                    │
                     verify: xray test / sing-box check
                                    │  ← failure here means "never spawned"
                                    │
                     Process.start(binary, runArgs)
                                    │
              stdout/stderr ──► LogBuffer ──► Logs screen + level inference
                                    │
              access log ──► TrafficTally (byte estimates for the sparkline)
                                    │
                     exit ──► backoff restart (≤ maxRestarts) ──► kill switch
```

The order matters in two places:

1. **Verify before accept.** The config is written and handed to the engine's own
   checker *before* we treat the profile as usable. An invented JSON key is not a
   Dart error and a unit test cannot see it; `xray test` can. A verification
   failure surfaces as `EngineStartResult(ok: false, message: <engine's words>)`
   in the UI instead of a process that dies 200 ms after starting.
2. **SIGTERM, then SIGKILL.** Xray removes its own PID/lock files and closes
   listeners on SIGTERM; killing it outright can leave a stale lock and, on
   Windows, a held port. `stop()` waits, then escalates. `dispose()` does the same
   on quit.

Restart policy: capped exponential backoff (`min(2^n · 500 ms, 30 s)`) up to
`maxRestarts` (default 5) with a reset window, so a miskeyed server that exits
immediately produces a handful of attempts and a clear log rather than a CPU
fan-spin. When the process dies while the system proxy was ours, the kill switch
runs `restore()` first: leaking traffic into a dead SOCKS port is worse than
having no proxy.

## Binary discovery

`app/lib/state/engine_locator.dart`, in this order, and each step is reported in
Settings → Engine so "which xray am I running" is never a guess:

1. `RuntimeSettings.xrayBinaryPath` / `singBoxBinaryPath` — explicit user choice.
   Wins even if the file is not executable, with a warning, because a wrong path
   you typed is more diagnosable than a silent fallback to a different binary.
2. `<app-support>/engine/<name>` — what a packaged install or an in-app engine
   update put there.
3. Next to our own executable (`<exe dir>/engine/xray`, `<exe dir>/xray`) — the
   portable-zip layout.
4. `PATH`, via `where` on Windows and `which` elsewhere.

Nothing is downloaded by the app itself; `scripts/fetch_engine.sh` is a
build-time step. A client that fetches and executes a binary on first run is what
malware installers do, and it makes the engine version something the user cannot
see before connecting.

## Config generation

Pure Dart, no filesystem, in `packages/naxlo_core`:

* `lib/src/xray/xray_config.dart` — `XrayConfigBuilder(profile, node, settings).build()`
* `lib/src/singbox/singbox_config.dart` — `SingBoxConfigBuilder(...).build()`

Both return `GeneratedConfig{engine, config, warnings, outboundTag, json,
compactJson}`. Two invariants worth knowing before you edit them:

* **`build()` never throws on user data.** A half-filled node from an import
  should produce a config plus `warnings`, not an exception — the alternative is
  a client that cannot open its own settings screen because of one bad link.
* **Anything the user asked for that the engine cannot do becomes a warning, not a
  silent drop.** `allowInsecure` on Reality, a `flow` on a transport that ignores
  it, `mixed` port collisions in sing-box, TUN without privileges, "no inbound
  enabled at all" — all of them reach `GeneratedConfig.warnings` and show up in
  the config preview.

Per-profile routing (`RoutingConfig`) and DNS (`DnsConfig`) are translated to the
engine's own vocabulary here — `domainSuffix` → `domain`, `bypassLan` → the
private CIDR set + `geoip:private`, `sniffOverrideTls` → `sniffing.enabled` with
`overrideDestination` — and not before. The UI never edits engine JSON.

### Inbounds

| Inbound | Default | Notes |
| --- | --- | --- |
| SOCKS5 | `127.0.0.1:20151` | `auth: noauth`, `udp: true`, IP pinned to loopback so a LAN peer cannot use us as an open proxy |
| HTTP (mixed) | `127.0.0.1:20152` | needed by the many clients that only speak HTTP proxy; also carries CONNECT for TLS |
| TUN | sing-box only | `tunStack` (`system`/`gvisor`/`mixed`), `mtu`, `tunIndex`; requires privileges, which is why it is opt-in and warned about |

Both loopback ports are configurable in Settings, and `engine_service` will fail
the start (rather than silently shifting to another port) if the requested one is
occupied — a proxy that moved ports is a proxy nobody is using.

### Outbounds and tags

One `proxy` outbound per connection, tagged with the node id (`outboundTag` in
`GeneratedConfig`), plus `direct` and `block`. Routing rules that name an action
resolve to those tags; `freeHex`-style adblocking lists and geosite files are not
bundled (see `NOTICE` — the geo data is CC-BY-NC-SA, and shipping it would
change this repo's licensing story for no user-visible gain).

## Logs and traffic

The engine writes to `logDir` (access + error log paths are settings), and
`LogBuffer` receives both the piped stdout/stderr and the file tail. Levels are
inferred once, in `LogBuffer._inferLevel`, from both Xray's
`level=warning`-style structured prefixes and plain words, because the two
engines and their versions disagree — and the Logs screen colours lines from the
same source of truth as any exported file.

Traffic numbers come from `TrafficTally` parsing the `… N bytes` trailer the
access log writes when a connection closes. It is an estimate and the UI says so:
neither engine exposes cheap aggregate counters to a client without Xray's gRPC
stats API, and standing up a gRPC server inside a tray app to draw one sparkline
is the wrong trade. Direction is taken from `>>>`/`<<<` (or `inbound`/`outbound`);
a line with no marker counts as download, which is what "how much did I pull"
means to a user.

## What is deliberately *not* wired in

| Not done | Why |
| --- | --- |
| Xray gRPC stats / `apiStatsPort` | needs a gRPC + protobuf stack for numbers the access log already gives approximately |
| Outbound-level rate limiting | no cross-platform way to do it without a TUN and a qdisc; would be a lie in the UI |
| `reverse`/reverse-forward proxy config | an operator feature with no ranking story; the JSON passthrough covers it |
| Custom transport `xhttpExtra` editing | the builder passes it through; a form for a field three people use is not worth the UI surface |
| Engine auto-update in-app | see `scripts/fetch_engine.sh` — engine upgrades are a release decision, not a background download |
| `mux` per-node UI beyond on/off + concurrency | Xray deprecated `mux` in favour of `xhttp`/h2 muxing; a toggle that half-works is worse than none |

## Verifying config output locally

```bash
scripts/fetch_engine.sh --engine both --os linux --arch amd64
(cd packages/naxlo_core && dart run tool/gen_samples.dart build/engine-samples)
bash scripts/verify-engine-config.sh
```

The last command generates every (engine × protocol) config with the real
builders and runs each through `xray test` / `sing-box check`. That is also what
the `manifest-and-config` CI job does, and it is the check that catches a renamed
upstream field — the class of bug where every unit test passes and every user
fails to connect.
