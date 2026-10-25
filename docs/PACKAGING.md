# Packaging, releases and how to run this locally

Three things live here: the version pipeline, the artifact build, and the
generated platform scaffolding that this repo deliberately does not commit.

## Layout

```
VERSION                                  single source of truth for the version
release                                  in-app update manifest (generated; committed)
scripts/set_version.sh                   VERSION → version.dart → pubspecs → packaging templates
scripts/fetch_engine.sh                  xray / sing-box into app/assets/engine/ (never committed)
scripts/bootstrap_platforms.sh             flutter create → app/{android,ios,linux,macos,windows}
scripts/gen_release_manifest.sh            GitHub Release assets → release manifest JSON
scripts/verify-engine-config.sh            generated configs through `xray test` / `sing-box check`
packaging/linux/build_packages.sh          flutter bundle → .deb / .rpm / .pkg.tar.zst / .AppImage
packaging/linux/{PKGBUILD,naxlo-two.spec,debian/,naxlo-two.desktop}
packaging/windows/naxlo-two.iss            Inno Setup script for setup-Naxlo.x64.exe
.github/workflows/{ci,release,auto-release}.yml
```

Identifiers used consistently everywhere:

| Thing | Value |
| --- | --- |
| Dart package (app) | `naxlo_two` |
| Org / Android package | `dev.naxlo` / `dev.naxlo.naxlo_two` |
| macOS / iOS bundle id | `dev.naxlo.naxloTwo` |
| Linux `.desktop` / binary | `naxlo-two` → `/opt/naxlo-two/naxlo_two` |
| Windows executable | `naxlo_two.exe` |
| App id in the update manifest | `naxlo_two` (`kNaxloAppId`) |
| Asset names in the README table | `setup-Naxlo.x64.exe`, `Naxlo.macOS.universal.dmg`, `Naxlo.linux.{x64,arm64}.{deb,rpm,pkg.tar.zst,AppImage}`, `Naxlo.apk` |

## Why platform folders are generated, not vendored

`app/android`, `app/ios`, `app/linux`, `app/macos`, `app/windows` are in
`.gitignore`. They are produced by `scripts/bootstrap_platforms.sh`, which runs
`flutter create --org dev.naxlo --project-name naxlo_two` per platform.

Vendoring them would freeze the repo to the Flutter version that generated them
and turn every SDK upgrade into conflicts in hundreds of Gradle/CMake/plist files
nobody reviews. The cost is one command on a fresh clone, which CI runs for you.

Two things the generated scaffolding does *not* get right, and you should fix in
your fork rather than here:

* `linux/runner/my_application.cc` — the GtkApplication id and window class must be
  `dev.naxlo.naxloTwo` / `naxlo_two`, or the window will not group under its own
  launcher icon. The bootstrap script warns if it still says `app`.
* `android/app/src/main/AndroidManifest.xml` — no permissions are needed for the
  SOCKS/HTTP-proxy mode; TUN (not implemented on Android in this repo) would need
  a `VpnService` and a signing identity.

## Local build

```bash
git clone https://github.com/Manixpcshot/Naxlo-Two && cd Naxlo-Two
scripts/bootstrap_platforms.sh              # needs flutter on PATH
scripts/fetch_engine.sh                     # optional: bundle the engine next to the build
cd app && flutter pub get
flutter run -d linux                        # or windows / macos
```

Debug runs use the debug engine build; release artifacts do not need anything
special because the app talks to the engine only through its CLI contract.

### Tests

```bash
cd packages/naxlo_core && dart analyze && dart test     # pure Dart, ~seconds
cd app && flutter analyze && flutter test                # widget + state tests
bash scripts/verify-engine-config.sh                     # needs engines fetched
```

`naxlo_core` has no Flutter dependency, so ranking/config tests run without the
SDK download. The app tests use `AppState.inMemory()` — no disk, no process, no
network (`checkForUpdates: false` is passed explicitly so a test never reaches out).

## Version + release flow

```
merge to main
   └─► auto-release.yml
         ├─ reads conventional-commit subjects since the last tag
         ├─ fix/perf/refactor → patch · feat or ! → minor · BREAKING CHANGE → major
         ├─ scripts/set_version.sh NEXT   (VERSION + version.dart + pubspecs + templates)
         ├─ commit "chore(release): vNEXT [skip ci]" and tag vNEXT
         └─ tag push triggers ▼
release.yml
   ├─ preflight: VERSION == tag == version.dart, then core + app analyze & test
   ├─ engines: fetch_engine.sh per target, cached as an artifact
   ├─ build: linux x64/arm64 · windows x64 (Inno) · macos arm64 + x86_64 → lipo universal → dmg
   │         · android split-ABI APKs (signed only if the keystore secrets exist)
   ├─ publish: gh release create with every artifact + SHA256SUMS.txt
   └─ gen_release_manifest.sh → commit `release` back to main  [skip ci]
```

Manual release of an already-tagged commit:

```bash
gh workflow run release.yml -f tag=v0.1.0        # or: git push origin v0.1.0
```

Opting a push out of auto-release: put `[skip-release]` in any commit message of
the push, or disable the workflow. Cutting a hotfix release: bump `VERSION` with
`scripts/set_version.sh`, commit `fix: …`, tag it, `gh workflow run release.yml -f tag=v…`.

### Required repository settings

| Setting | Where | Needed for |
| --- | --- | --- |
| `contents: write` | set in both workflows | tagging, releasing, committing the manifest |
| `XRAY_VERSION`, `SINGBOX_VERSION` | Settings → Secrets and variables → Actions → *Variables* | pinning engines; unset means "latest release" |
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Secrets | signing APKs; without them the release notes say the APKs are debug-signed |
| `NAXLO_MANIFEST_URL` (optional) | Variable | if you serve the manifest somewhere other than the repo root |

Branch protection note: `release.yml` pushes `release` directly to `main`. If you
protect `main` against direct pushes, either allow the bot user or change the
publish job to open a PR (`gh pr create`) and merge it manually — the app keeps
working either way; only the manifest's freshness changes.

## The update manifest

`release` at the repo root is what the app's `UpdateService` fetches by default
(`kDefaultManifestUrl`). It mirrors the shape Happ publishes, with integrity
fields added:

```jsonc
{
  "app": "naxlo_two",
  "filenum": 7,
  "generatedAt": "2026-10-25T00:00:00Z",
  "windows": {
    "block": ["0.1.1"],                  // versions the app must not update onto
    "stable": {
      "version": "0.1.0",
      "link": "https://github.com/…/setup-Naxlo.x64.exe",
      "details": "markdown shown in the update dialog",
      "sha256": "…",                     // empty ⇒ never auto-installed, only notified
      "size": 43000000,
      "minSupported": "",                 // below this: "you must update"
      "update": { "warnalways": "", "updateonly": "" }
    },
    "beta": {}                           // `updateChannel: beta` in settings reads this
  },
  "macos": { … }, "linux": { … }, "android": { … }, "ios": { "stable": {} }
}
```

Parsing lives in `packages/naxlo_core/lib/src/update/release_manifest.dart`, the
decision (notify / update / force / blocked / none) in `ReleaseManifest.decide()`.
Behaviour worth knowing before you hand-edit the file:

* A missing or empty `sha256` means **notify only** — the app will show you the
  release and its link, but will not download-and-install something it cannot
  verify. Verification runs `sha256sum` / `Get-FileHash` on the downloaded file.
* A `block` entry is how you tell the world "0.1.1 is broken, stay off it".
* `update.updateonly` forces the update for everyone at or below that version;
  `warnalways` nags everyone below it. Both are for protocol breaks.
* An unparseable manifest is treated as "no update information", never as
  "up to date" — and `gen_release_manifest.sh` validates with `jq` before writing
  for the same reason.

Serving your own: point `manifestUrl` (Settings → Diagnostics) at any HTTPS URL
returning this JSON, e.g. a Pages site. `scripts/gen_release_manifest.sh` works
from any repo you have `gh` access to.

## Platform notes

**Windows.** Inno Setup builds `setup-Naxlo.x64.exe`. Per-user install by default
(no UAC); `PrivilegesRequiredOverridesAllowed=dialog` lets a machine-wide install
happen when TUN is wanted. The uninstaller clears WinINET proxy values *only* if
they still point at our own ports, and profile deletion is an opt-in task —
`bundle.json` holds your servers, so removing them silently would be hostile.
ARM64 needs an ARM64 host to build (Flutter has no cross-arch flag for Windows);
the workflow keeps that target behind the `include_arm` input rather than
pretending an x64 runner can emit a working arm64 installer.

**macOS.** Two native builds (`macos-14` arm64, `macos-13` x64) are merged with
`lipo` into a universal `.app`, then `hdiutil` makes the dmg. Unsigned by
default: the first launch needs right-click → Open (or `xattr -dr
com.apple.quarantine`), and `docs/ENGINE.md` explains why TUN is the one feature
that additionally needs a Network Extension — which this repo does not ship,
because it requires an Apple Developer signing identity to be anything but a
skeleton.

**Linux.** `packaging/linux/build_packages.sh` produces `.deb`, `.rpm`,
`.pkg.tar.zst` and (when `APPIMAGETOOL` is set) an `.AppImage` from one staging
tree, so the formats cannot drift into installing different file sets. Layout is
`/opt/naxlo-two/` + `/usr/bin/naxlo-two` launcher, because a Flutter Linux bundle
is a directory (executable + `lib/` + `data/flutter_assets`), not one binary.
`postinst`/`%post` run `setcap cap_net_admin,cap_net_raw=eip` on the bundled
engine — privileges for the *engine*, never for the UI. `packaging/linux/PKGBUILD`
and `debian/` are for people building from source; CI does not use them.

**Android.** `flutter build apk --release --split-per-abi` plus a universal
`Naxlo.apk`. No Play Store metadata, no `VpnService` (this app is a proxy client
on Android; TUN via `VpnService` is the sing-box tunnel mode this repo leaves as
a documented gap). Sideload, or use the split-ABI APK matching your device.

**iOS.** Not built in CI: it needs a signing identity and an APProvider/NEProvider
extension for any tunnel mode. `flutter build ios` after
`scripts/bootstrap_platforms.sh ios` gets you a project you can sign yourself.

## Reproducibility and licensing of what you ship

* Engine binaries are fetched by `scripts/fetch_engine.sh` from the upstream
  GitHub releases, checksum-verified against the upstream `checksums.txt` /
  `.sha256sum`, and never committed. Xray is MPL-2.0, sing-box is GPL-3.0; both
  are separate processes we exec rather than link, which is the arrangement
  `NOTICE` documents.
* GeoIP/GeoSite data is **not** bundled (upstream licensing is CC-BY-NC-SA); if
  your build needs it, add it in your own release and read its terms.
* Every artifact in a release has a line in `SHA256SUMS.txt`, and the manifest
  carries the digest of the one a given platform should install.
