# Naxlo Two — Proxy Utility

Naxlo Two is a cross-platform client for self-hosted proxy servers, built on the same engine
architecture as [Happ](https://github.com/Happ-proxy): a **Flutter / Dart** application that
configures, supervises and routes traffic through **Xray-core** (and optionally **sing-box**).

> Naxlo Two is an independent project. It shares Happ's engine and language, **not** its code —
> Happ's application source is closed-source, so everything here is written from scratch.
> No Happ assets, strings, icons or binaries are redistributed.

| Platform | Artifact | Platform | Artifact |
| --- | --- | --- | --- |
| Windows x64 | [`setup-Naxlo.x64.exe`](https://github.com/Manixpcshot/Naxlo-Two/releases/latest/download/setup-Naxlo.x64.exe) | macOS universal | [`Naxlo.macOS.universal.dmg`](https://github.com/Manixpcshot/Naxlo-Two/releases/latest/download/Naxlo.macOS.universal.dmg) |
| Windows ARM64 | [`setup-Naxlo.arm64.exe`](https://github.com/Manixpcshot/Naxlo-Two/releases/latest/download/setup-Naxlo.arm64.exe) | Linux x64 `.deb` | [`Naxlo.linux.x64.deb`](https://github.com/Manixpcshot/Naxlo-Two/releases/latest/download/Naxlo.linux.x64.deb) |
| Android | [`Naxlo.apk`](https://github.com/Manixpcshot/Naxlo-Two/releases/latest/download/Naxlo.apk) | Linux ARM64 `.deb` | [`Naxlo.linux.arm64.deb`](https://github.com/Manixpcshot/Naxlo-Two/releases/latest/download/Naxlo.linux.arm64.deb) |
| iOS | build from source (`app/ios`) | Arch x64 `.pkg` | [`Naxlo.linux.x64.pkg.tar.zst`](https://github.com/Manixpcshot/Naxlo-Two/releases/latest/download/Naxlo.linux.x64.pkg.tar.zst) |

Every artifact is produced by GitHub Actions from the tagged commit — see
[.github/workflows/release.yml](.github/workflows/release.yml). The in-app updater reads the
[`release`](./release) manifest at the repo root, which is regenerated on every published release.

## What it does

* **Protocols:** VLESS (Reality), VMess, Trojan, Shadowsocks (SIP002), SOCKS, HTTP.
* **Import:** `vless://`, `vmess://`, `trojan://`, `ss://`, `socks5://` share links, JSON config
  files, and subscription URLs (base64 link lists, `subscription-userinfo` quota headers).
* **Engines:** pick **Xray-core** or **sing-box** per profile; the app generates the JSON config,
  spawns the process, tails its log, restarts it with backoff and shuts it down cleanly.
* **Connectivity:** local SOCKS5 + HTTP(mixed) inbound on `127.0.0.1`, optional system-proxy
  takeover on Windows / macOS / Linux, TUN via sing-box when running with privileges.
* **Routing:** per-profile rules (domain / suffix / keyword / regex / CIDR), presets
  (bypass LAN, bypass private & bogon ranges, block ads, direct-first), DNS with sniffing,
  kill-switch on unexpected engine exit.
* **Probe:** parallel TCP latency measurement with jitter and loss tracking, feeding the ranker.
* **Ranking:** the part where Naxlo Two deliberately diverges from Happ — see below.
* **Privacy:** zero telemetry, zero analytics. Profiles, samples and logs live in the app-support
  directory on your machine and never leave it.

## Ranking: the differentiator

Happ picks a server by a single number: the last ping. Naxlo Two treats server choice as an
online learning problem. The ranker (`packages/naxlo_core/lib/src/ranking/`) scores every server
from a rolling window of observations and picks a node through a policy you can actually reason
about:

```
score(s) = w_L · f_ewma(latency)  +  w_J · f(jitter)  +  w_R · Beta⁻¹(success)
         +  w_T · f(throughput)   −  w_S · staleness  −  w_F · failure_streak
```

* **Two modes.** `Simple` = ranked median latency (predictable, Happ-like).
  `Advanced` = EWMA smoothing with half-life decay + Beta-binomial reliability + **Thompson
  sampling** exploration, so a temporarily bad node is re-probed instead of being blacklisted
  forever, and a good node is not abandoned after one flaky measurement.
* **Hysteresis & anti-flapping.** Auto-switch only fires when a candidate is better by a
  configurable margin (`switchMargin`), sustained for `dwellMs`, and outside the `cooldownMs`
  window — the ping-pong you get from naive "lowest ping wins" selection is designed out.
* **Sticky weighting + capacity.** `stickiness` biases toward the node already carrying your
  traffic; `loadSpread` optionally spreads concurrent profiles across near-tied nodes.
* **Explainable.** Every ranked row carries the reason it ranked there
  (`latency 82ms ▾ · jitter 6ms · ok 97% · fresh 40s`), so the list never looks like magic.
* **Tunable.** All seven weights are sliders in Settings, with Balanced / Speed / Stability
  presets, and the ranking spec, formulas and benchmarks are documented in
  [docs/RANKING.md](docs/RANKING.md).

## Layout

```
app/                 Flutter app (Windows, macOS, Linux, Android, iOS)
  lib/core/          thin layer over naxlo_core + engine/process/proxy code
  lib/features/      home · servers · profile editor · routing · settings · logs
  lib/theme/         Naxlo design system (violet/cyan, dark-first, Material 3)
packages/naxlo_core/ pure-Dart engine — no Flutter, no plugins, unit tested
  lib/src/sharelink/ share-link parser/writer for every protocol
  lib/src/ranking/   EWMA · Thompson · hysteresis · selector
  lib/src/config/    Xray & sing-box JSON config builders
scripts/             set_version.sh · fetch_engine.sh · bootstrap_platforms.sh
release              in-app update manifest (regenerated by CI on every release)
docs/                [RANKING](docs/RANKING.md) · [ENGINE](docs/ENGINE.md) · [PACKAGING](docs/PACKAGING.md) · [PRIVACY](docs/PRIVACY.md)
```

## Build from source

Prerequisites: Flutter **3.24+** (stable), Dart 3.5+, and for desktop the usual native toolchain
(VS Build Tools / Xcode / `gtk+-3.0`, `ninja`, `cmake`).

```bash
git clone https://github.com/Manixpcshot/Naxlo-Two.git && cd Naxlo-Two

# 1. generate the platform scaffolding once (idempotent)
./scripts/bootstrap_platforms.sh

# 2. fetch the engine binaries you want (xray / sing-box) into app/assets/engine
./scripts/fetch_engine.sh xray sing-box

# 3. run
cd app && flutter pub get && flutter run -d linux        # or windows / macos / android
```

Static checks and tests (no device needed):

```bash
cd packages/naxlo_core && dart analyze && dart test
cd app && flutter analyze && flutter test
```

Making a release is one command — it bumps versions, commits, and tags; the tag triggers the
full multi-platform build, the GitHub Release and the manifest update:

```bash
./scripts/set_version.sh patch "improve thompson seeding"
```

## Legal & safety notes

* Naxlo Two **does not sell or provide VPN/proxy access**. You bring your own server or
  subscription. The app is a client and a config generator.
* Circumvention tooling is restricted or illegal in some jurisdictions (Iran, Russia, China,
  Oman, UAE …). Check your local law and accept the risk before using it.
* Bypassing censorship can carry real personal risk. Pair the client with sane operational
  security: no logs, trusted server, up-to-date engine, Reality/TLS on.
* Bundled third-party engines stay under their own licenses — Xray-core (MPL-2.0), sing-box
  (GPL-3.0). They are downloaded from their upstream GitHub releases, never re-hosted here.
  See [NOTICE](./NOTICE).

## Credits

* [Happ](https://github.com/Happ-proxy) — the UX and engine concept this client is modelled on.
* [Xray-core](https://github.com/XTLS/Xray-core) and [sing-box](https://github.com/SagerNet/sing-box).

## License

MIT (Naxlo Two source). Third-party engines keep their own licenses — see [LICENSE](./LICENSE)
and [NOTICE](./NOTICE).

---

## Naxlo Two (فارسی)

این برنامه یک کلاینت چندنُفس (دسکتاپ و موبایل) برای سرورهای پراکسی شخصی است که با **Flutter/Dart**
نوشته شده و دقیقاً مثل **Happ** از موتور **Xray-core** (و در صورت انتخاب، **sing-box**) استفاده می‌کند.
کد این پروژه از صفر نوشته شده و هیچ بخشی از سورس Happ (که بسته است) در آن استفاده نشده؛ تنها شباهت،
همان موتور، همان زبان و همان مدل تجربه کاربری است.

* **پروتکل‌ها:** VLESS (Reality)، VMess، Trojan، Shadowsocks، SOCKS، HTTP
* **واردات:** لینک‌های اشتراک، فایل JSON، و URL سابسکریپشن (همراه با نمایش حجم/انقضای باقی‌مانده)
* **رنکینگ متفاوت:** به‌جای «کمترین پینگ»، انتخاب سرور با میانگین متحرک نمایی (EWMA)، اطمینان
  بتا-دوجمله‌ای، کاوش با **Thompson Sampling**، و هیسترزیس برای جلوگیری از پرش مکرر بین سرورها
  انجام می‌شود. همه وزن‌ها در تنظیمات قابل تغییرند و دلیل هر رتبه در لیست نشان داده می‌شود.
* **خصوصی‌سازی:** بدون تله‌متری؛ همه داده‌ها روی دستگاه شما می‌ماند.
* **رلیز خودکار:** بعد از هر آپدیت روی `main`، یک ورک‌فلو نسخه بعدی را محاسبه و تگ می‌کند و
  بیلد همه پلتفرم‌ها به‌صورت خودکار روی GitHub منتشر می‌شود.
