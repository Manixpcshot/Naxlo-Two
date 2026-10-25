# Ranking

This is the part Naxlo Two does differently on purpose. Everything else — the
engine, the config generation, the share-link parsers — is deliberately close to
what a Flutter/Xray client normally does. Choosing *which server to use* is where
it diverges.

The implementation is in `packages/naxlo_core/lib/src/ranking/` and has no
Flutter dependency, so it can be read, run and tested on its own:

| File | Role |
| --- | --- |
| `sample_point.dart` | one measurement: time, ok/fail, latency, bytes |
| `metrics.dart` | per-server decayed statistics (`ServerMetrics`) |
| `thompson.dart` | Beta/normal sampling for the exploration term |
| `ranker.dart` | score composition → `List<RankedServer>` |
| `ranked_server.dart` | score + components + human-readable reasons |
| `selection.dart` | hysteresis: *should we actually move?* |

## What a ping-based list gets wrong

Ordering servers by the last RTT measurement is fast to explain and wrong in
four repeatable ways:

1. **It is stale.** A measurement from 40 minutes ago is presented as if it were
   now. Networks change with time of day; so does "fastest".
2. **It is one sample.** A single 38 ms probe on a server that is at 300 ms the
   other 9 times out of 10 wins the list.
3. **It has no memory of failure.** A server that fails half the time and is
   instant when it works looks better than one that is slower and never fails.
4. **It never explores.** A server that has not been probed yet sits at the
   bottom, so it is never probed, so it stays at the bottom.

None of that matters for a list you read. It matters a lot for a list the app
*acts on* by itself.

## The score

`Ranker.rank()` produces one `RankedServer` per node. Six components, each
normalised into `0..1`, each with a user-visible weight:

```
score = w_latency   · latency_component      # lower median latency is better
      + w_jitter    · jitter_component       # lower spread is better
      + w_reliab    · reliability_component  # decayed success rate, lower confidence bound
      + w_through   · throughput_component   # bytes/s observed through the engine
      + w_fresh     · freshness_component    # how recent the evidence is
      + w_stab      · stability_component    # penalty on swings and reconnects
      + manual_bias                          # user's ±100 slider, scaled small
      + exploration                          # Thompson draw, advanced mode only
```

### 1. Latency, with a half-life

`ServerMetrics` keeps an exponentially weighted mean, and the decay factor is
computed from the **gap since the last sample**, not from a fixed per-sample
alpha:

```
alpha = 1 − 0.5 ^ (gap_ms / half_life_ms)      # clamped to 0.02 .. 1.0
ewma  = ewma + alpha · (x − ewma)
```

Why gap-aware: if a probe loop stalls (laptop slept, engine restarting, no
network for an hour), a fixed alpha would keep blending stale values as if the
silence meant "nothing changed". With the gap in the exponent, an hour of silence
*is* decay — the old number's influence halves every `halfLifeMs` of wall-clock
time whether samples arrive or not. Clamping at the bottom keeps a 2 ms blip from
erasing 40 samples; clamping at the top means "this is effectively the new
measurement".

Median, not mean, for the reported number: `latencyMsRounded` comes from the
window of recent samples, so one 4 s timeout on a 40 ms link does not make the
tile read "2 s".

### 2. Reliability uses a lower confidence bound

A naive success rate over 4 samples says "100% up" for a server you have tried
four times. That is not evidence, it is a small number. We use a Beta posterior
with a Jeffreys prior (`α = β = 0.5`) and then take a **lower** bound:

```
reliability   = (ok + 0.5) / (ok + fail + 1)          # point estimate
reliabilityLcb = quantile-ish lower bound, used for scoring
```

Practical effect: 4/4 up scores *near* but below a 400/402 server, and "healthy"
requires `reliabilityLcb ≥ 0.7`. Three consecutive failures mark the node `down`
regardless of history — an outage is information, not noise to be averaged away.

Failures also decay: `failWeight` halves with the same half-life, so yesterday's
outage does not disqualify a server forever. That asymmetry is deliberate: it is
better to re-try a server that came back than to abandon it permanently.

### 3. Latency draws are median-anchored, so variance is not free

`advanced` scores the *draw*, not the mean: `sampleLatencyMs` fits a log-normal
whose **median** is the EWMA, giving `E[draw] = mean · exp(σ²/2) > mean`. Centring
the log at `log(mean) − σ²/2` (the unbiased parameterisation) would make
high variance free in expectation — and a ranker where risk is free keeps
choosing the node that spikes every third minute. The test in
`metrics_test.dart` ("log-normal is right-skewed") pins which of the two this
project means.

### 4. Jitter and stability are different things

`jitterEwmaMs` is the decayed mean absolute deviation of latency — how much the
same server moves around. `stability` penalises *the app's experience* of it:
reconnect churn, `noteEngineFailure()` events, and swings between the top and the
bottom of the list. A server can be low-jitter and still unstable (TLS handshake
succeeds instantly, then the tunnel drops in 20 s), which is exactly the case a
ping list cannot see at all.

### 5. Normalisation is median-based, not min-max

Min-max across the current candidate set has a nasty property: one outlier (a
server at 6 s because it is 9000 km away) compresses every "normal" server's
latency difference into 0.001, so the ranking collapses into noise and the
*other* components silently take over. We divide by the median of the set
instead, which keeps 40 ms vs 90 ms meaning roughly the same thing whether or not
someone added a server in Australia.

### 6. Missing data is a middle score, not a zero

An unmeasured node gets `_unknownComponent = 0.55` for latency/jitter/throughput.
Not 0 — that would mean "unproven is worse than proven bad", which permanently
locks out new servers. Not 1 — that would let a fresh import steal your traffic
before it has done anything. It is a slight lean toward "give it a look", and
`exploration` does the actual pushing.

### 7. Exploration is a Thompson draw, not an ε-greedy coin flip

For each candidate we draw `θ ~ Beta(ok + 0.5, fail + 0.5)` and combine it with a
latency-shaped normal draw; `ThompsonSampler.pick()` then scales the winner by
`exploration` (default 0.06, user-tunable).

Why this over `ε`-greedy ("10% of the time pick a random server"): ε picks a
*random* server, including ones that have proven bad, and it does not stop when
there is nothing to learn. Thompson sampling's variance is driven by the
posterior width, so an under-sampled node gets a wide draw and a
well-measured-but-mediocre node gets almost none. The `pick()` reward is capped
below the current best's typical score, so exploration can **promote a probe
slot**, and it can win the ranking when it genuinely should — it cannot send your
traffic to a node the data says is bad for more than the exploration weight
allows. `seed` makes it deterministic, which is what makes the tests in
`test/ranker_test.dart` meaningful.

### 8. Manual bias is small on purpose

The user's −100..+100 slider contributes `±0.05` (`weight/100 · 0.05`). It is an
intentional nudge between comparable options, not a way to fight the data. If a
slider could dominate the score, ranking becomes decorative and the "why did it
pick this" sheet becomes a lie. Pinning a server (`pin` in the server sheet) is
the separate, absolute mechanism: it sets the current server and the selector
will not move while pinned.

## Mode: `simple` vs `advanced`

`simple` is the "I just want the lowest ping, don't be clever" mode. Same code
path, different constants:

| | simple | advanced |
| --- | --- | --- |
| latency / jitter / reliability weights | 1.0 / 0 / 0.25 | user-configurable (7 weights) |
| throughput, freshness | off | on |
| stability (failure streaks) | 0.25 — kept, a node failing right now must not win | `stability` |
| stickiness (prefer the active node) | **off** | `stickiness` |
| exploration | **0** | `exploration` |
| decay | long half-life, gentle | `halfLifeMs` as configured |

No branch in the maths, so both modes are exercised by the same tests —
`simple` is the same scorer with a different weight vector
(`RankingConfig.effectiveForMode`).

Two of those choices are deliberate and were argued out by tests:

* **stickiness is off in `simple`.** In "median latency" mode the list the user
  reads has to be ordered by median latency, and a bonus for whichever node
  happens to be carrying traffic makes it look arbitrary exactly when someone
  is comparing nodes. Resistance to flapping is the selector's job (dwell +
  switch margin), and that applies in both modes.
* **missing data scores in the middle, for every component.** `simple` and
  `advanced` both use a Jeffreys lower bound for *observed* failures, which is
  a pessimistic reading of data you have. Applying it to "no data at all" would
  put a freshly imported node below a flaky one, permanently — the ranker would
  never probe it hard enough to find out it was the best server in the list.

## Scoring is not switching

`SelectionDecision` carries two ids, because a `keep` needs both: `serverId` is
the node to stay on, `betterId` is the node currently ahead of it. Dwell timing
must follow `betterId` — timing the incumbent measures the wrong thing and the
leader's streak never accumulates, so auto-switching silently never fires.
A high-scoring server must also *earn the move*, because every switch costs a
reconnect: TCP+TLS handshakes, a new latency ramp, and for the user a dropped
download. `ServerSelector.decide()` implements that with three knobs:

```
margin   = switchMargin · (1 + 0.5 · recentFlips)      # capped at 0.30
cooldown = base, doubling per flip                      # capped at 15 min
dwell    = challenger must lead continuously for dwellMs
```

* `switchMargin` (default 0.06): challenger must beat the incumbent by this much.
* **Anti-flip ramp**: each recent flip raises the required margin by 50%, so a
  server pair that keeps trading the lead settles instead of oscillating. Capped
  so a genuinely broken incumbent can still be escaped.
* `dwellMs`: the challenger has to *have been* better since `betterSinceMs` — a
  one-sample spike cannot trigger a switch.
* **One override**: if the current server is `down`, all of this is ignored and
  we move immediately. Downtime is the case where staying is worse than the cost
  of switching, and it is the only one.

`autoSelect = off` (the user chose a server) disables the move but not the
measurement: ranking keeps running so the list stays informative, and the moment
`autoSelect` returns the decisions are already based on real history rather than
a cold start.

## What the UI shows, and why that is part of the design

Every row in the Servers screen opens a sheet with:

* the score and each component as a bar (so you can see *what* is carrying it);
* the reasons list, generated in `ranked_server.dart` as sentences, not numbers;
* the raw evidence: sample count, age of the newest sample, decayed ok/fail
  weights, consecutive failures, last error string;
* the effective mode, half-life, margin and dwell at the top of the Logs screen.

A ranker you cannot interrogate is a ranker you cannot trust when it is wrong,
and it will be wrong some days. Keeping `reasons` next to `components` in the
same model is also what makes bug reports here answerable: "it picked the 300 ms
server over the 40 ms one" plus the screenshot of the sheet is usually enough to
see that freshness or reliability was carrying it.

## Tuning

Defaults live in `RankingConfig` (`packages/naxlo_core/lib/src/config/ranking_config.dart`)
and every one of them is editable in Settings → Ranking. Rough guidance:

| You want | Change |
| --- | --- |
| Snappier reaction to a new best server | smaller `halfLifeMs`, smaller `switchMargin` |
| Never move during a video call | larger `dwellMs`, larger `switchMargin`, or pin |
| Prefer a link that survives peak hours | raise `reliability` and `stability`, lower `latency` |
| Test a newly added server quickly | raise `exploration` for a while, then put it back |
| Happ-like "lowest ping" behaviour | mode = `simple` |

Presets: `balanced`, `speed`, `stability` (just weight vectors — see
`RankingWeights.preset`).

## Honest limits

* Latency measured by the *prober* is TCP connect time to the server's port; it
  is not application round-trip time, and it says nothing about the second hop
  (server → destination), which is often the part that actually hurts. The
  `throughput` component is the only signal that touches the real path, and it is
  parsed from the engine's access log, so it lags and under-counts open flows.
* A server can be "best" for one destination and worst for another. Ranking is
  per-server, not per-destination, because the alternative (per-destination
  scoring) needs a routing table *and* a measurement loop per site — that is a
  bigger app.
* If the app is closed, nothing learns: there is no server-side measurement and
  no sharing of samples between installs. Deliberate — see
  [PRIVACY.md](PRIVACY.md).
