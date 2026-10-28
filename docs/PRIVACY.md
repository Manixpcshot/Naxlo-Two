# Privacy

## The short version

Naxlo Two collects nothing. No analytics, no crash reporter, no metrics endpoint,
no "anonymous usage statistics", no feature-flag service, no fetch of a
tracking pixel on launch. There is no account, no device id, and no server
operated by this project.

The only request the app can make on its own is the update-manifest fetch, and
it is on the network path you choose (default: this repository on GitHub). It can
be turned off in Settings → Diagnostics → *Check for updates*, or pointed at
another URL.

## Everything that leaves the machine

| Destination | When | What goes out | What comes back |
| --- | --- | --- | --- |
| **Your proxy servers** | only while connected | your tunneled traffic, plus the credentials in the node you picked | the traffic you asked for |
| **A subscription URL** | only when you press Refresh (or on launch if you enabled auto-refresh for that profile) | a `GET` with `User-Agent: naxlo-two/<version>` and the headers the subscription itself asked for | the link list + `subscription-userinfo` headers |
| **The update manifest** | on launch and on demand, if enabled | a `GET` of one JSON URL — no body, no identifying headers | version, link, sha256, size |
| **DNS** | during probes and while connected | the server hostnames you configured, resolved per your DNS policy | addresses |

That is the complete list. Nothing else in the app opens a socket: search the
source for `HttpClient`, `Socket`, `SecureSocket` and `Process.start` and every
hit belongs to one of the four rows above.

### Deliberate details of those requests

* **The subscription `User-Agent` is `naxlo-two/<version>`, with no device, model,
  OS version, install id or hash of your server list.** Some panels use the UA to
  fingerprint clients; the version is there because a panel needs to reject
  clients whose parser is too old, and that is a compatibility need, not an
  identifying one. If you want even that gone, set it in Settings.
* **A subscription is fetched over HTTPS unless you added a plain `http://` URL
  yourself**, in which case the app warns instead of silently encrypting nothing.
  A panel on plain HTTP can rewrite your server list to anything.
* **Update checks are `GET` only, with no ETag tied to an install id.** GitHub
  (or your mirror) sees a request for one file from an IP address. That is also
  true of opening any web page; the difference worth caring about is that we do
  not send a client-generated identifier along with it.
* **Probing uses TCP connect, not `ICMP` echo.** Ping needs raw sockets
  (privileges) and is frequently deprioritised by the very networks a proxy is
  used on, so it measures the wrong thing while asking for more rights. The
  trade-off is documented in `docs/RANKING.md`.

## Everything that stays on the machine

In the app-support directory (`~/.local/share/naxlo_two`,
`~/Library/Application Support/naxlo_two`, `%APPDATA%\naxlo_two`):

| File | Contents |
| --- | --- |
| `bundle.json` | profiles, servers with their credentials, per-profile routing/DNS, ranking config, runtime settings, selection state, metrics and recent samples |
| `bundle.json.bak1..3` | rolling backups, written with tmp + rename |
| `config-<profile>.json` | the last config handed to the engine (same credentials, expanded) |
| `logs/` | engine access/error logs |

There is no cloud sync and no export-to-server. "Backup" means you copy a file.

**Treat `bundle.json` like a password file.** It contains your server addresses
and keys — that is what makes the app work, and it is also what makes the file
sensitive. The app does not encrypt it at rest, because a keyfile encrypted with
a password would need its own password manager to be useful, and half-implementing
at-rest encryption is worse than documenting the risk. If you need the former,
put the app-support directory on an encrypted volume (FileVault, LUKS,
`cipherfs`), which also covers the logs and the last-written config.

The `share` button writes a share link — including the credentials — to your
clipboard. That is a deliberate, explicit action with a confirmation dialog, and
the exported link is the same text you would have pasted into a friend's chat.

## Traffic-level privacy

What the app does *not* do, and what it therefore cannot promise:

* **It is not a VPN provider.** It encrypts the path between you and *your*
  server. What happens after that hop is up to that server and to the destination.
* **DNS is only as private as your DNS policy.** `systemOnly` means the OS
  resolver is used and your ISP sees the names — that is the "no leak, no
  protection" default some people want, so it exists, but it is why the Routing
  screen shows the effective strategy rather than a green checkmark.
* **`allowInsecure` disables the one thing that verifies you reached your
  server.** It exists because self-signed setups are real; the config preview
  warns, and on Reality the field is ignored with a warning rather than obeyed.
* **A kill switch cannot cover a power cut.** The proxy settings are restored on
  clean exit, on engine death and by the packaging hooks, but if the machine
  loses power mid-session the system proxy points at a dead port. The result is
  "browser cannot load pages", not "traffic unencrypted" — fail-closed by
  construction, which is the correct direction for this failure.
* **TUN mode with `overrideDestination` sees everything the machine sends**, which
  is the point of it. That data goes to your server; nothing is retained locally
  beyond the access log lines (which contain destination hosts and byte counts —
  that is exactly why `logs/` is not sent anywhere).

## Telemetry you can verify yourself

Because "trust me" is not a verification:

```bash
# No analytics domains, no crash endpoints, no tracking ids in the source.
grep -rniE "analytics|sentry|firebase|telemetry|posthog|matomo|amplitude" app/lib packages/*/lib

# Every outbound network call site in the app.
grep -rn "HttpClient(\|Socket.connect\|SecureSocket.connect" app/lib

# Every process we spawn.
grep -rn "Process.start\|Process.run" app/lib
```

The last two should return only: the prober (`probe_service.dart`), the
subscription fetch (`subscription_service.dart`), the updater
(`update_service.dart`), the engine supervisor (`engine_service.dart`), the
engine locator (`engine_locator.dart`) and the system-proxy commands
(`system_proxy.dart`). If a patch adds a six-line variant of any of these, it
should say in the pull request which of them it belongs to — otherwise it does
not belong here.

The updater's endpoints are `api.github.com` (which release is newest, and the
digest GitHub computed for each asset), `raw.githubusercontent.com` (the `release`
manifest, for block lists) and the asset host those two name. It spawns exactly
one process per user action — the platform hasher, and the installer only when
the hash matched — and never composes a shell string, so an asset name containing
a quote is a file name and not a second command.

There is a CI job for the second-order version of the same promise
(`.github/workflows/ci.yml` → the manifest and privacy guards), because a policy
nobody checks becomes a policy nobody follows.

## Data-deletion answer, for when someone asks

"Delete the app-support directory." There is nothing else to delete, nothing
that survives on a server, and no account to close.
