# Security Policy

## Reporting a vulnerability

Email **security@naxlo.dev** with the word `naxlo-two` in the subject. If the
key is unavailable, open a normal issue with only the words "security issue —
please contact" and we will arrange a private channel; do not post details
publicly.

We aim to acknowledge within 3 business days and ship a fix or a workaround
within 30 days for anything that can affect a user's traffic. There is no bounty
program: this is a small open-source project, and the reward is a credited fix
and a written explanation of what went wrong.

## What this app is, cryptographically

Naxlo Two is a *client for servers you run or were given*. It is not a VPN
provider, does not operate any relay, and holds no server-side state. That has
consequences for what counts as a vulnerability here:

* **In scope:** anything that lets a *malicious server or a malicious
  subscription* execute code, read the profile store, or route traffic somewhere
  the user did not choose; anything that leaks DNS or reveals the real IP while
  the tunnel is up; anything that lets a local user read another user's data;
  signature/provenance bypasses in the updater.
* **Not in scope:** the security of Xray-core or sing-box themselves (report
  those upstream: [Xray](https://github.com/XTLS/Xray-core/blob/main/SECURITY.md),
  [sing-box](https://github.com/SagerNet/sing-box/blob/main/SECURITY.md)), the
  protocol's cryptographic properties, and any attack that already requires code
  execution as your user.

## Threat model, honestly stated

| Threat | Where it is handled | Residual risk |
| --- | --- | --- |
| Malicious subscription link list | `SubscriptionService` refuses plain `http://` unless you add the URL yourself; parser caps entry count and skips lines it cannot parse | A hostile subscription can still *choose which of your own servers you use*; it cannot add outbound requests on its own |
| Share link with hostile fields | Every field is length- and range-checked before it reaches a generated config; unknown keys are dropped | Config generation is the trust boundary — see `docs/ENGINE.md` |
| `allowInsecure` TLS | Per-node opt-in, surfaced as a warning in the config preview and the server sheet | Disabled verification is trivially MITM'd; that is why the UI keeps reminding you |
| Engine binary | Resolved in a fixed order: explicit user path → app-support dir → executable dir → `PATH`. Nothing is downloaded and executed silently | If you point the path at an attacker-writable directory, the app will happily run whatever `xray` is there |
| Update artifact | Manifest is fetched over HTTPS; installer is downloaded and **`sha256`-verified before it is offered for install**; a mismatch is refused, not "warned about" | The manifest is unsigned. Whoever controls the repo controls the update channel — the honest mitigation is that the URL is visible in Settings and can be repointed or disabled |
| Local config/log files | Written with tmp+rename under the user's app-support dir; config contains your server keys | Filesystem permissions are the OS's job; on a shared machine treat `config.json` like a password |
| Traffic leak on engine death | Kill-switch: proxy settings are restored/cleared and routing stops when the process exits unexpectedly | A hard `SIGKILL` from outside the app leaves a window of a few ms; TUN mode depends on the engine's own `override_destination` behaviour |

## Practical guidance the app cannot enforce for you

* **Reality/`pbk` typos fail closed** — the config is verified by
  `xray test`/`sing-box check` before it is accepted, so a bad key means "won't
  start", not "silently downgrades".
* **Prefer a subscription over pasted links** only if you trust the publisher.
  A subscription is a remote-controlled config; that is the whole feature and the
  whole risk.
* **TUN + `isPrivileged` means the engine sees all local traffic.** Use it when
  you need it (games, apps that ignore proxy settings), not by default.
* Do not run the app as root/admin to make TUN "just work". `docs/PACKAGING.md`
  documents the `setcap` route for Linux.

## Verified-fixed advisories

None to date. If an advisory is filed here it will appear in
[`CHANGELOG.md`](./CHANGELOG.md) with a `security:` prefix and, where GitHub
supports it, a drafted security advisory.
