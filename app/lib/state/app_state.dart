import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:naxlo_core/naxlo_core.dart';
import 'package:path_provider/path_provider.dart';

import 'engine_locator.dart';
import 'engine_service.dart';
import 'log_buffer.dart';
import 'probe_service.dart';
import 'storage.dart';
import 'subscription_service.dart';
import 'system_proxy.dart';
import 'update_service.dart';

enum TunnelStatus { disconnected, connecting, connected, failed }

/// The single source of truth the UI reads.
///
/// Everything observable (profiles, ranker state, engine status) lives here and
/// mutates only through methods that also schedule a save and notify listeners.
/// Widgets never keep a `ServerMetrics` or spawn a process themselves — that is
/// what makes "window closed mid-connect" and "two profiles open at once"
/// reasoning problems instead of thread-dump problems.
class AppState extends ChangeNotifier {
  AppState({
    required this.store,
    required this.logs,
    required this.engine,
    required this.prober,
    required this.proxyController,
    required this.updater,
    required this.subscriptions,
    required this.supportDir,
  })  : bundle = const ProfileBundle(),
        _saver = AutoSaver(store: store);

  /// Test constructor: everything in-memory, nothing touches the disk or a
  /// process, so the ranking → selection → UI path is covered by `flutter test`.
  factory AppState.inMemory({String? initialJson, RuntimeSettings? settings, RankingConfig? ranking}) {
    final logs = LogBuffer();
    final dir = Directory.systemTemp.createTempSync('naxlo-two-test');
    final state = AppState(
      store: MemoryBundleStore(initialJson ?? ''),
      logs: logs,
      engine: EngineService(
        logs: logs,
        locator: EngineLocator(supportDir: dir),
        supportDir: dir,
      ),
      prober: ProbeService(),
      proxyController: SystemProxyController(),
      updater: UpdateService(platform: 'linux'),
      subscriptions: SubscriptionService(),
      supportDir: dir,
    );
    if (settings != null || ranking != null) {
      state.bundle = state.bundle.copyWith(
        settings: settings ?? state.bundle.settings,
        ranking: ranking ?? state.bundle.ranking,
      );
    }
    return state;
  }

  /// Real desktop/mobile construction. Async on purpose: `path_provider` has no
  /// sync API, and a temp-dir placeholder would have put user state somewhere the
  /// OS is free to wipe, so the support directory is awaited before the state
  /// object exists at all.
  static Future<AppState> createDesktop() async {
    final logs = LogBuffer();
    final base = await getApplicationSupportDirectory();
    final support = Directory('${base.path}${Platform.pathSeparator}NaxloTwo')..createSync(recursive: true);
    const store = FileBundleStore();
    return AppState(
      store: store,
      logs: logs,
      engine: EngineService(
        logs: logs,
        locator: EngineLocator(supportDir: support),
        supportDir: support,
        traffic: TrafficTally(),
      ),
      prober: ProbeService(),
      proxyController: SystemProxyController(),
      updater: UpdateService(platform: UpdateService.platformName()),
      subscriptions: SubscriptionService(),
      supportDir: support,
    );
  }

  final BundleStore store;
  final LogBuffer logs;
  final EngineService engine;
  final ProbeService prober;
  final SystemProxyController proxyController;
  final UpdateService updater;
  final SubscriptionService subscriptions;
  final Directory supportDir;
  final AutoSaver _saver;

  ProfileBundle bundle;
  TunnelStatus status = TunnelStatus.disconnected;
  String statusDetail = '';
  List<RankedServer> ranked = const <RankedServer>[];

  /// [ranked] with the incumbent's stickiness folded in. Only the selector reads
  /// this: see [_recomputeRanking] for why the two must not be one list.
  List<RankedServer> _rankedWithBias = const <RankedServer>[];
  UpdateDecision? updateAvailable;

  /// The verified installer on disk, once the user has asked for it. Kept on the
  /// state rather than in the widget so the banner survives a page switch, which
  /// is exactly when a download finishes.
  UpdateDownload? updateDownload;

  /// Bytes received over bytes expected, or -1 when the total is unknown, or null
  /// when no download is running. Never an indeterminate progress *animation*:
  /// the UI smoke test pumps this tree and settles it, and an infinite bar would
  /// never settle.
  double? updateDownloadProgress;
  bool _updating = false;
  int _rev = 0;
  bool _disposed = false;

  int uplinkBytes = 0;
  int downlinkBytes = 0;
  double throughputKbps = 0;
  Timer? _ticker;
  ProbeLoop? _loop;

  Profile? get profile => bundle.active;
  RuntimeSettings get settings => bundle.settings;
  RankingConfig get ranking => bundle.ranking;
  List<Profile> get profiles => bundle.profiles;
  Map<String, ServerMetrics> get metrics => bundle.metricsByServer;
  bool get isConnected => status == TunnelStatus.connected;
  bool get isBusy => status == TunnelStatus.connecting;
  int get revision => _rev;
  int get nodeCount => profile?.servers.length ?? 0;

  SelectionState get _selection => bundle.selectionByProfile[profile?.id ?? ''] ?? const SelectionState();

  Ranker get _ranker => Ranker(config: ranking);
  ServerSelector get _selector => ServerSelector(ranking);

  // ── lifecycle ─────────────────────────────────────────────────────────────

  Future<void> load() async {
    final raw = await store.read();
    final result = ProfileBundle.load(raw);
    var next = result.bundle.pruned(nowMs: _nowMs());
    if (next.activeProfileId.isEmpty && next.profiles.isNotEmpty) {
      next = next.copyWith(activeProfileId: next.profiles.first.id);
    }
    bundle = next;
    if (result.error.isNotEmpty) {
      logs.add('state file unreadable (${result.error}); started from empty state', level: LogLevel.error);
    }
    _touch();
    await _recomputeRanking();
    if (settings.checkForUpdates) unawaited(checkForUpdates(silent: true));
    if (settings.autoConnectOnLaunch && profile != null) unawaited(connect());
  }

  /// Restores the system proxy however we got here. A stale 127.0.0.1 proxy
  /// after quit breaks the internet for the user in a way they will blame on us.
  Future<void> shutdown() async {
    _ticker?.cancel();
    _loop?.dispose();
    await proxyController.restore();
    await engine.stop(silent: true);
    await _saver.flush();
    _disposed = true;
  }

  @override
  void dispose() {
    // First, before anything can await: `shutdown()` yields on the proxy and the
    // engine, and a callback landing in that window used to reach `_persist()` and
    // re-arm the autosave *after* disposal — a live Timer at the end of a widget test
    // and a write to a store that is going away in the app.
    _disposed = true;
    // Synchronously, and before `shutdown()` gets its first chance to yield: a
    // debounced autosave or a ticker still armed when the object dies is a leak in
    // a running app and a "Pending timers" failure in a widget test. `shutdown` is
    // async for the engine/proxy cleanup; these three cannot wait for it.
    _saver.cancelPending();
    _ticker?.cancel();
    _loop?.stop();
    unawaited(shutdown());
    super.dispose();
  }

  void _touch() {
    if (_disposed) return;
    _rev++;
    notifyListeners();
  }

  /// Force any debounced write to hit the store now. Used on quit and by
  /// tests that reload the bundle from disk-equivalent memory.
  Future<void> flush() => _saver.flush();

  void _persist() {
    if (_disposed) return; // a disposed app must not arm a timer again
    _saver.schedule(bundle.copyWith(savedAtMs: _nowMs()).encode(pretty: false));
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  // ── ranking ───────────────────────────────────────────────────────────────

  Future<void> _recomputeRanking() async {
    final p = profile;
    if (p == null) {
      ranked = const <RankedServer>[];
      _rankedWithBias = const <RankedServer>[];
      return;
    }
    // Two lists, because they answer two questions. The UI answer is "which
    // server measures better"; the switch answer is "is anything better *enough*
    // to leave what we have". Folding the stickiness weight (0.4 of a 4.0 total,
    // i.e. +0.10 of score) into the shared list made a connected-but-unmeasured
    // node outrank a measured 30ms one in the list the user reads — hysteresis is
    // not a measurement, and it is also the selector's own job to hold off.
    final now = _nowMs();
    ranked = _ranker.rank(servers: p.servers, metrics: bundle.metricsByServer, nowMs: now);
    _rankedWithBias = _ranker.rank(
      servers: p.servers,
      metrics: bundle.metricsByServer,
      nowMs: now,
      currentServerId: _selection.currentServerId,
    );
  }

  /// Ingest measurements, re-rank, and let the selector decide whether to move
  /// traffic. The only place ranking state changes.
  void ingestSamples(List<ProbeOutcome> outcomes, {bool allowSwitch = true}) {
    if (outcomes.isEmpty) return;
    final p = profile;
    if (p == null) return;
    final now = _nowMs();
    final updated = Map<String, ServerMetrics>.from(bundle.metricsByServer);
    final samples = Map<String, List<SamplePoint>>.from(bundle.recentSamplesByServer);
    for (final o in outcomes) {
      final m = updated[o.serverId] ?? ServerMetrics();
      m.observe(o.sample, halfLifeMs: ranking.halfLifeMs);
      updated[o.serverId] = m;
      final history = <SamplePoint>[...?samples[o.serverId], o.sample];
      samples[o.serverId] = history.length > ranking.maxSamplesKept
          ? history.sublist(history.length - ranking.maxSamplesKept)
          : history;
    }
    bundle = bundle.copyWith(metricsByServer: updated, recentSamplesByServer: samples);

    ranked = _ranker.rank(servers: p.servers, metrics: updated, nowMs: now);
    _rankedWithBias = _ranker.rank(
      servers: p.servers,
      metrics: updated,
      nowMs: now,
      currentServerId: _selection.currentServerId,
    );

    // A manual pick is not a candidate for the anti-flap machinery to reason
    // about. Running `decide` anyway and applying its state used to replace
    // "you pinned this server" with "leader is only 1.8% ahead", i.e. the UI
    // explained a decision the user had made — and left the dwell timer armed for
    // a switch that autoSelect=false forbids.
    final manual = p.selectedServerId;
    if (manual.isNotEmpty) {
      if (_selection.currentServerId != manual) {
        bundle = bundle.copyWith(selectionByProfile: <String, SelectionState>{
          ...bundle.selectionByProfile,
          p.id: _selection.copyWith(currentServerId: manual),
        });
        _persist();
      }
      _touch();
      return;
    }

    final decision = _selector.decide(
      ranked: _rankedWithBias,
      state: _selection,
      nowMs: now,
      allowSwitch: allowSwitch && p.autoSelect,
    );
    final next = _selector.apply(_selection, decision, nowMs: now);
    bundle = bundle.copyWith(
      selectionByProfile: <String, SelectionState>{...bundle.selectionByProfile, p.id: next},
    );
    logs.add('selection: ${decision.reason}', source: 'ranker');
    _persist();
    _touch();

    if (decision.changed && isConnected && decision.serverId.isNotEmpty) {
      final target = p.byId(decision.serverId);
      // The selector runs after every probe round; only a *different* node that
      // is not already the active one justifies paying for a reconnect.
      if (target != null && engine.activeNode?.id != target.id) {
        unawaited(_switchTo(p, target));
      }
    }
  }

  Future<void> _switchTo(Profile p, ServerNode node) async {
    status = TunnelStatus.connecting;
    statusDetail = 'switching to ${node.displayName}';
    _touch();
    final r = await engine.start(profile: p, node: node, settings: settings);
    status = r.ok ? TunnelStatus.connected : TunnelStatus.failed;
    statusDetail = r.ok ? node.displayName : r.message;
    if (r.ok) {
      _startTicker();
      unawaited(reconcileProbing());
    } else {
      await _handleEngineDeath();
    }
    _touch();
  }

  // ── connection ────────────────────────────────────────────────────────────

  Future<void> connect() async {
    final p = profile;
    if (p == null) {
      status = TunnelStatus.failed;
      statusDetail = 'no profile — import some links first';
      _touch();
      return;
    }
    final node = await _resolveActiveNode(p);
    if (node == null) {
      status = TunnelStatus.failed;
      statusDetail = 'no eligible node in "${p.name}"';
      _touch();
      return;
    }

    status = TunnelStatus.connecting;
    statusDetail = 'starting ${p.engine.cliName} → ${node.displayName}';
    _touch();

    final result = await engine.start(profile: p, node: node, settings: settings);
    if (!result.ok) {
      status = TunnelStatus.failed;
      statusDetail = result.message;
      await _handleEngineDeath();
      _touch();
      return;
    }

    if (settings.proxyMode.touchesSystem) {
      final failures = await proxyController.apply(settings, enable: true);
      if (failures.isNotEmpty) {
        logs.add('system proxy partly failed: ${failures.join(' | ')}', level: LogLevel.warn);
        statusDetail = '${node.displayName} · proxy partly failed: ${failures.first}';
      }
    }

    status = TunnelStatus.connected;
    _startTicker();
    await reconcileProbing();
    _touch();
  }

  Future<void> disconnect() async {
    _ticker?.cancel();
    _loop?.stop();
    if (settings.proxyMode.touchesSystem) {
      await proxyController.apply(settings, enable: false);
    }
    await engine.stop();
    status = TunnelStatus.disconnected;
    statusDetail = '';
    uplinkBytes = 0;
    downlinkBytes = 0;
    throughputKbps = 0;
    _touch();
  }

  /// Kill switch: if the engine died, make sure nothing keeps pretending the
  /// tunnel is up — clear the system proxy so the OS stops pointing at a dead port.
  Future<void> _handleEngineDeath() async {
    if (!settings.killSwitch) return;
    if (settings.proxyMode.touchesSystem) {
      await proxyController.apply(settings, enable: false);
      logs.add('kill switch: system proxy cleared after engine failure', level: LogLevel.warn);
    }
  }

  /// Explicit pin wins; otherwise ask the ranker/selector for #1.
  Future<ServerNode?> _resolveActiveNode(Profile p) async {
    final manual = p.selected;
    if (manual != null) {
      bundle = bundle.copyWith(
        selectionByProfile: <String, SelectionState>{
          ...bundle.selectionByProfile,
          p.id: _selection.copyWith(currentServerId: manual.id),
        },
      );
      return manual;
    }
    await _recomputeRanking();
    final forSwitch = _rankedWithBias.isEmpty ? ranked : _rankedWithBias;
    final decision = _selector.decide(ranked: forSwitch, state: _selection, nowMs: _nowMs());
    var id = decision.serverId;
    if (id.isEmpty) {
      final candidates = _ranker.candidates(forSwitch);
      id = candidates.isEmpty ? '' : candidates.first.serverId;
    }
    if (id.isEmpty) return null;
    final node = p.byId(id);
    if (node == null) return null;
    bundle = bundle.copyWith(
      selectionByProfile: <String, SelectionState>{
        ...bundle.selectionByProfile,
        p.id: _selection.copyWith(currentServerId: id, switchedAtMs: _nowMs()),
      },
    );
    return node;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      uplinkBytes = engine.traffic.totalUp;
      downlinkBytes = engine.traffic.totalDown;
      throughputKbps = engine.traffic.sample();
      _touch();
    });
  }

  /// Start or stop the background loop to match the current settings. Named for
  /// what it does: the loop exists only while the tunnel is up and probing is on.
  Future<void> reconcileProbing() async {
    final shouldRun = isConnected && settings.probeWhileConnected;
    if (!shouldRun) {
      _loop?.stop();
      return;
    }
    final loop = _loop ??= ProbeLoop(
      prober: prober,
      currentServerId: () => _selection.currentServerId,
      onSamples: (o) => ingestSamples(o),
    );
    loop.configure(ranking);
    loop.start();
  }

  Future<void> probeAll() async {
    final p = profile;
    if (p == null) return;
    statusDetail = 'measuring ${p.candidates.length} nodes';
    _touch();
    final outcomes = await prober.probeMany(p.candidates, ranking);
    ingestSamples(outcomes, allowSwitch: false);
    statusDetail = '';
    _touch();
  }

  Future<void> probeOne(String serverId) async {
    final p = profile;
    final node = p?.byId(serverId);
    if (node == null) return;
    final outcome = await prober.probe(node, ranking);
    ingestSamples(<ProbeOutcome>[outcome], allowSwitch: false);
  }

  // ── profiles & nodes ──────────────────────────────────────────────────────

  Future<void> selectServer(String serverId) async {
    final p = profile;
    if (p == null) return;
    bundle = bundle.copyWith(
      profiles: <Profile>[
        for (final x in bundle.profiles) x.id == p.id ? x.copyWith(selectedServerId: serverId) : x,
      ],
      selectionByProfile: <String, SelectionState>{
        ...bundle.selectionByProfile,
        p.id: SelectionState(
          currentServerId: serverId,
          switchedAtMs: _nowMs(),
          // The status card reads this line, so it has to say who decided. Leaving
          // it blank made the next probe round's "leader is 1.8% ahead" the reason
          // for a connection the *user* chose.
          lastReason: 'pinned by the user; the ranker will not move you',
        ),
      },
    );
    _persist();
    await _recomputeRanking();
    if (isConnected) await connect();
    _touch();
  }

  Future<void> unpin() async {
    final p = profile;
    if (p == null) return;
    bundle = bundle.copyWith(
      profiles: <Profile>[
        for (final x in bundle.profiles) x.id == p.id ? x.copyWith(selectedServerId: '') : x,
      ],
      selectionByProfile: <String, SelectionState>{
        ...bundle.selectionByProfile,
        p.id: _selection.copyWith(lastReason: 'released to automatic selection'),
      },
    );
    _persist();
    await _recomputeRanking();
    _touch();
  }

  Future<void> setAutoSelect(bool value) async {
    final p = profile;
    if (p == null) return;
    bundle = bundle.copyWith(
      profiles: <Profile>[
        for (final x in bundle.profiles) x.id == p.id ? x.copyWith(autoSelect: value) : x,
      ],
    );
    _persist();
    _touch();
  }

  Future<void> setServerEnabled(String serverId, bool value) async {
    _mapServer(serverId, (s) => s.copyWith(enabled: value));
    await _recomputeRanking();
    _persist();
    _touch();
  }

  Future<void> setServerWeight(String serverId, int weight) async {
    _mapServer(serverId, (s) => s.copyWith(weight: weight.clamp(-100, 100)));
    await _recomputeRanking();
    _persist();
    _touch();
  }

  void _mapServer(String serverId, ServerNode Function(ServerNode) transform) {
    final p = profile;
    if (p == null) return;
    bundle = bundle.copyWith(
      profiles: <Profile>[
        for (final x in bundle.profiles)
          x.id == p.id
              ? x.copyWith(servers: <ServerNode>[
                  for (final s in x.servers) s.id == serverId ? transform(s) : s,
                ])
              : x,
      ],
    );
  }

  Future<Profile> addProfile(String name) async {
    final now = _nowMs();
    final p = Profile(
      id: 'p$now',
      name: name.isEmpty ? 'Profile ${bundle.profiles.length + 1}' : name,
      createdAt: now,
      updatedAt: now,
    );
    bundle = bundle.copyWith(profiles: <Profile>[...bundle.profiles, p], activeProfileId: p.id);
    _persist();
    await _recomputeRanking();
    _touch();
    return p;
  }

  Future<void> activateProfile(String id) async {
    if (bundle.activeProfileId == id) return;
    if (isConnected) await disconnect();
    bundle = bundle.copyWith(activeProfileId: id);
    _persist();
    await _recomputeRanking();
    _touch();
  }

  Future<void> deleteProfile(String id) async {
    final remaining = <Profile>[for (final p in bundle.profiles) if (p.id != id) p];
    final alive = <String>{for (final p in remaining) for (final s in p.servers) s.id};
    if (bundle.activeProfileId == id && isConnected) await disconnect();
    bundle = ProfileBundle(
      schemaVersion: ProfileBundle.kSchemaVersion,
      profiles: remaining,
      activeProfileId: bundle.activeProfileId == id
          ? (remaining.isEmpty ? '' : remaining.first.id)
          : bundle.activeProfileId,
      metricsByServer: <String, ServerMetrics>{
        for (final e in bundle.metricsByServer.entries)
          if (alive.contains(e.key)) e.key: e.value,
      },
      selectionByProfile: <String, SelectionState>{
        for (final e in bundle.selectionByProfile.entries)
          if (e.key != id) e.key: e.value,
      },
      recentSamplesByServer: <String, List<SamplePoint>>{
        for (final e in bundle.recentSamplesByServer.entries)
          if (alive.contains(e.key)) e.key: e.value,
      },
      settings: bundle.settings,
      ranking: bundle.ranking,
      savedAtMs: _nowMs(),
    );
    _persist();
    await _recomputeRanking();
    _touch();
  }

  Future<void> replaceProfile(Profile updated) async {
    bundle = bundle.copyWith(
      profiles: <Profile>[
        for (final p in bundle.profiles) p.id == updated.id ? updated : p,
      ],
    );
    _persist();
    await _recomputeRanking();
    _touch();
  }

  Future<ImportReport> importLinks(String blob, {String? intoProfileId}) async {
    final parsed = ShareLinkParser.parseMany(blob);
    return _importNodes(parsed.nodes, errors: parsed.errors, intoProfileId: intoProfileId, title: '');
  }

  Future<ImportReport> _importNodes(
    List<ServerNode> nodes, {
    required List<String> errors,
    required String? intoProfileId,
    required String title,
  }) async {
    if (nodes.isEmpty) return ImportReport(imported: 0, errors: errors);
    var targetId = intoProfileId ?? bundle.activeProfileId;
    Profile? target;
    for (final p in bundle.profiles) {
      if (p.id == targetId) target = p;
    }
    if (target == null) {
      target = await addProfile(title.isEmpty ? 'Imported' : title);
      targetId = target.id;
    }
    final merged = SubscriptionMerger.merge(existing: target.servers, incoming: nodes);
    // ids key everything downstream (metricsByServer, rankingExplain, selector
    // state, the per-row pending switch), so two rows sharing one id would double
    // count a server in the ranking and leave one row unreachable in the UI. The
    // merger is not supposed to produce that; the guard costs one pass.
    final seenIds = <String>{};
    final servers = <ServerNode>[
      for (final n in merged.servers)
        if (seenIds.add(n.id)) n,
    ];
    await replaceProfile(target.copyWith(servers: servers, updatedAt: _nowMs()));
    return ImportReport(
      imported: merged.added.length,
      total: merged.servers.length,
      removed: merged.removed.length,
      renamed: merged.servers.length - merged.added.length,
      errors: errors,
    );
  }

  Future<void> addServer(Profile p, ServerNode node) =>
      replaceProfile(p.copyWith(servers: <ServerNode>[...p.servers, node], updatedAt: _nowMs()));

  Future<void> removeServer(Profile p, String serverId) async {
    await replaceProfile(p.copyWith(
      servers: <ServerNode>[for (final s in p.servers) if (s.id != serverId) s],
      selectedServerId: p.selectedServerId == serverId ? '' : p.selectedServerId,
      updatedAt: _nowMs(),
    ));
    bundle = bundle.copyWith(
      metricsByServer: <String, ServerMetrics>{
        ...bundle.metricsByServer
      }..remove(serverId),
    );
    _persist();
    _touch();
  }

  Future<ImportReport> refreshSubscription({bool force = false}) async {
    final p = profile;
    final src = p?.subscription;
    if (p == null || src == null || src.url.isEmpty) {
      return const ImportReport(imported: 0, errors: <String>['this profile has no subscription URL']);
    }
    if (!force && src.isTooEarly(_nowMs())) {
      return const ImportReport(imported: 0, errors: <String>['the provider asked us not to refresh yet']);
    }
    final fetch = await subscriptions.fetch(src.url);
    if (!fetch.ok) {
      return ImportReport(imported: 0, errors: <String>[fetch.error.isEmpty ? 'no nodes returned' : fetch.error]);
    }
    final merged = SubscriptionMerger.merge(existing: p.servers, incoming: fetch.result.nodes);
    final info = fetch.result.updateInfo;
    await replaceProfile(p.copyWith(
      servers: merged.servers,
      subscription: src.copyWith(
        lastFetchAtMs: _nowMs(),
        nodeCount: merged.servers.length,
        title: fetch.result.title.isEmpty ? src.title : fetch.result.title,
        bytesUsed: info == null ? src.bytesUsed : info.usedBytes,
        bytesQuota: info == null ? src.bytesQuota : info.total,
        expiresAtMs: info == null || info.expire == 0 ? src.expiresAtMs : info.expire * 1000,
      ),
      updatedAt: _nowMs(),
    ));
    // Providers rotate nodes under the same remark; prune history only for the
    // ones that disappeared, otherwise a refresh silently resets the ranker.
    final keep = merged.retainedHistoryIds;
    bundle = bundle.copyWith(
      metricsByServer: <String, ServerMetrics>{
        for (final e in bundle.metricsByServer.entries)
          if (keep.contains(e.key)) e.key: e.value,
      },
    );
    _persist();
    await _recomputeRanking();
    return ImportReport(
      imported: merged.added.length,
      total: merged.servers.length,
      removed: merged.removed.length,
      errors: fetch.result.errors,
    );
  }

  Future<void> attachSubscription(String url, {String? title}) async {
    final p = profile;
    if (p == null) return;
    await replaceProfile(p.copyWith(
      subscription: SubscriptionSource(url: url.trim(), title: title ?? ''),
      updatedAt: _nowMs(),
    ));
  }

  // ── settings / tuning ─────────────────────────────────────────────────────

  Future<void> updateSettings(RuntimeSettings next) async {
    bundle = bundle.copyWith(settings: next);
    _persist();
    _touch();
    if (isConnected) await proxyController.apply(next, enable: next.proxyMode.touchesSystem);
    await reconcileProbing();
  }

  Future<void> updateRanking(RankingConfig next) async {
    bundle = bundle.copyWith(ranking: next);
    _persist();
    await _recomputeRanking();
    _loop?.configure(next);
    _touch();
  }

  Future<void> applyWeightsPreset(String name) => updateRanking(ranking.copyWith(weights: RankingWeights.preset(name)));

  ThemeMode get themeMode {
    switch (settings.themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
      case 'black':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  bool get wantBlackTheme => settings.themeMode == 'black';

  // ── updates ───────────────────────────────────────────────────────────────

  /// Ask GitHub (and the repo's `release` manifest) what the newest release is.
  ///
  /// A re-entrancy guard, because this is reachable from the banner, the settings
  /// switch and app start — and two concurrent checks means two `_touch()`
  /// completions racing to write [updateAvailable], where the loser can leave a
  /// stale decision on screen pointing at a version that was superseded a second
  /// later.
  Future<void> checkForUpdates({bool silent = false}) async {
    if (_updating) return;
    _updating = true;
    try {
      final decision = await updater.check(
        channel: settings.updateChannel,
        includePrerelease: settings.allowPrereleaseUpdates,
        // `manifestUrl` is a persisted setting that nothing used to read, so
        // "serve your own manifest" was documentation rather than behaviour. An
        // empty value keeps the default GitHub raw URL; with an override set the
        // Releases API is skipped, because a private mirror *is* the policy and
        // pointing the updater at a second, different source would be surprising.
        overrideUrl: settings.manifestUrl.isEmpty ? null : settings.manifestUrl,
      );
      updateAvailable = decision.action == UpdateAction.none ? null : decision;
      // A fresh answer invalidates an installer downloaded for the previous one:
      // offering "install 0.3.0" under a heading that now says 0.4.0 is how a
      // user ends up running the wrong binary.
      updateDownload = null;
      if (!silent && decision.action == UpdateAction.none) statusDetail = decision.reason;
    } finally {
      _updating = false;
      _touch();
    }
  }

  String get updateSource => updater.lastSource;

  /// `downloadUrl` is empty for a decision that only *announces* a version (a
  /// prerelease with prereleases off, or a platform the manifest gives no asset
  /// for), so the banner needs to know which of the three states it is in.
  bool get updateDownloadable => (updateAvailable?.downloadUrl ?? '').isNotEmpty;

  void dismissUpdate() {
    updateAvailable = null;
    updateDownload = null;
    updateDownloadProgress = null;
    _touch();
  }

  /// Fetch the verified installer. Progress is written at most per whole percent,
  /// because `onProgress` fires per socket chunk and calling `_touch()` on each
  /// would rebuild the whole shell thousands of times for one 40 MB download.
  Future<void> downloadUpdate() async {
    final decision = updateAvailable;
    if (decision == null || decision.downloadUrl.isEmpty || updateDownloadProgress != null) return;
    updateDownloadProgress = -1;
    _touch();
    var lastPercent = -1;
    var lastTick = DateTime.fromMillisecondsSinceEpoch(0);
    final result = await updater.download(
      decision,
      onProgress: (received, total) {
        final now = DateTime.now();
        final percent = total > 0 ? (received * 100 ~/ total) : -1;
        final fresh = now.difference(lastTick).inMilliseconds > 120;
        if (percent != lastPercent || fresh) {
          lastPercent = percent;
          lastTick = now;
          updateDownloadProgress = total > 0 ? received / total : -1;
          _touch();
        }
      },
    );
    updateDownloadProgress = null;
    updateDownload = result;
    statusDetail = result.message;
    _touch();
  }

  /// Hand the verified file to the platform installer. Returns true when the
  /// process actually started, which on Windows is the signal to close this app
  /// so the installer can replace the binaries it is holding open.
  Future<bool> installUpdate() async {
    final downloaded = updateDownload;
    if (downloaded == null || !downloaded.installable) return false;
    final result = await UpdateService.launchInstaller(File(downloaded.path));
    statusDetail = result.message;
    _touch();
    return result.started;
  }

  /// Install, and take the app out of the installer's way.
  ///
  /// Windows is the only platform that needs the exit: the installer replaces
  /// `naxlo_two.exe`, which this process has open, and Inno's
  /// `CloseApplications=yes` would otherwise end the app on its own with no
  /// chance to flush. So the debounced autosave is written *before* `exit`, and
  /// `exit` is reached only when the process really started — a failed launch
  /// must leave the app running with the error on screen, not kill a working
  /// tunnel for nothing.
  Future<void> installUpdateAndRestart() async {
    if (!await installUpdate()) return;
    if (!Platform.isWindows) return;
    await flush();
    exit(0);
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  RankedServer? rankOf(String serverId) {
    for (final r in ranked) {
      if (r.serverId == serverId) return r;
    }
    return null;
  }

  ServerMetrics? metricsOf(String serverId) => bundle.metricsByServer[serverId];

  String get activeServerId => _selection.currentServerId;

  String get selectionReason => _selection.lastReason;

  /// Debug/insight dump used by the Logs screen's "copy ranking state" action.
  List<String> get rankingExplain => ranked.isEmpty
      ? const <String>[]
      : <String>[
          'mode=${ranking.mode.wireName} halfLife=${ranking.halfLifeMs}ms '
              'margin=${ranking.switchMargin} dwell=${ranking.dwellMs}ms',
          for (final r in ranked.take(8)) '#${r.rank} ${r.serverId} ${r.scorePercentLabel} ${r.summary}',
        ];
}

class ImportReport {
  const ImportReport({
    required this.imported,
    this.total = 0,
    this.removed = 0,
    this.renamed = 0,
    this.errors = const <String>[],
  });

  final int imported;
  final int total;
  final int removed;
  final int renamed;
  final List<String> errors;

  String get summary {
    final parts = <String>['+$imported new'];
    if (renamed > 0) parts.add('$renamed kept history');
    if (removed > 0) parts.add('-$removed gone');
    if (total > 0) parts.add('= $total nodes');
    if (errors.isNotEmpty) parts.add('${errors.length} skipped');
    return parts.join(', ');
  }
}
