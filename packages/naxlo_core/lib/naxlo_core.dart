/// Pure-Dart core of Naxlo Two.
///
/// Everything in here is engine-agnostic and Flutter-free: it turns user
/// intent (profiles, servers, routing rules) into the JSON that Xray-core or
/// sing-box consumes, and turns network observations into a ranked server
/// choice. Process supervision and the UI live in `app/`.
library;

export 'src/config/ranking_config.dart';
export 'src/config/runtime_settings.dart';
export 'src/geo/geo.dart';
export 'src/json/json_utils.dart';
export 'src/models/dns_config.dart';
export 'src/models/engine_kind.dart';
export 'src/models/profile.dart';
export 'src/models/proxy_protocol.dart';
export 'src/models/routing.dart';
export 'src/models/security.dart';
export 'src/models/server_node.dart';
export 'src/models/transport.dart';
export 'src/ranking/metrics.dart';
export 'src/ranking/ranked_server.dart';
export 'src/ranking/ranker.dart';
export 'src/ranking/sample_point.dart';
export 'src/ranking/selection.dart';
export 'src/ranking/thompson.dart';
export 'src/sharelink/share_link.dart';
export 'src/singbox/singbox_config.dart';
export 'src/store/profile_bundle.dart';
export 'src/subscription/subscription.dart';
export 'src/update/github_releases.dart';
export 'src/update/release_manifest.dart';
export 'src/update/semver.dart';
export 'src/util/net_addr.dart';
export 'src/version.dart';
export 'src/xray/xray_config.dart';