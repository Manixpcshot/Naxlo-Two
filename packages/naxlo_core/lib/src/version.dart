/// Kept in sync with `../../VERSION` by scripts/set_version.sh.
const String kNaxloVersion = "0.2.1";

/// Identifier used inside configs, logs and the update manifest.
const String kNaxloAppId = 'naxlo_two';
const String kNaxloAgent = 'NaxloTwo';

/// Where the in-app updater looks for the release manifest.
const String kDefaultManifestUrl =
    'https://raw.githubusercontent.com/Manixpcshot/Naxlo-Two/main/release';

/// Upstream engine releases used by scripts/fetch_engine.sh and CI.
const String kXrayReleasesApi = 'https://api.github.com/repos/XTLS/Xray-core/releases';
const String kSingBoxReleasesApi =
    'https://api.github.com/repos/SagerNet/sing-box/releases';
