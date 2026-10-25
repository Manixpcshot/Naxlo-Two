/// Minimal semver with correct precedence rules (including pre-release and
/// build metadata), because the update check must never treat `1.10.0` as
/// older than `1.9.0` — a string compare would.
class Semver implements Comparable<Semver> {
  const Semver(this.major, this.minor, this.patch, {this.preRelease = '', this.build = ''});

  final int major;
  final int minor;
  final int patch;

  /// `rc.1` in `1.2.0-rc.1` (no leading hyphen here).
  final String preRelease;
  final String build;

  bool get isPreRelease => preRelease.isNotEmpty;

  static Semver? tryParse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    if (s.isEmpty) return null;
    var build = '';
    final plus = s.indexOf('+');
    if (plus >= 0) {
      build = s.substring(plus + 1);
      s = s.substring(0, plus);
    }
    var pre = '';
    final dash = s.indexOf('-');
    if (dash >= 0) {
      pre = s.substring(dash + 1);
      s = s.substring(0, dash);
    }
    final parts = s.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final nums = <int>[];
    for (final p in parts) {
      // Tolerate `1.2` (no patch) and stray suffixes like `1.2.3final`.
      final m = RegExp(r'^(\d+)').firstMatch(p);
      if (m == null) return null;
      nums.add(int.parse(m.group(1)!));
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return Semver(nums[0], nums[1], nums[2], preRelease: pre, build: build);
  }

  static int compare(String a, String b) {
    final x = tryParse(a);
    final y = tryParse(b);
    if (x == null || y == null) return 0;
    return x.compareTo(y);
  }

  @override
  int compareTo(Semver other) {
    final byMajor = major.compareTo(other.major);
    if (byMajor != 0) return byMajor;
    final byMinor = minor.compareTo(other.minor);
    if (byMinor != 0) return byMinor;
    final byPatch = patch.compareTo(other.patch);
    if (byPatch != 0) return byPatch;
    return _comparePreRelease(preRelease, other.preRelease);
  }

  /// Semver §11: a version without pre-release outranks one with it; then each
  /// dot-separated identifier compares numerically if both are numeric, else
  /// lexically; and a larger set of identifiers wins when the prefix is equal.
  static int _comparePreRelease(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 0;
    if (a.isEmpty) return 1;
    if (b.isEmpty) return -1;
    final as = a.split('.');
    final bs = b.split('.');
    final n = as.length < bs.length ? as.length : bs.length;
    for (var i = 0; i < n; i++) {
      final x = as[i];
      final y = bs[i];
      final xn = int.tryParse(x);
      final yn = int.tryParse(y);
      if (xn != null && yn != null) {
        final c = xn.compareTo(yn);
        if (c != 0) return c;
        continue;
      }
      if (xn != null) return -1; // numeric identifiers have lower precedence
      if (yn != null) return 1;
      final c = x.compareTo(y);
      if (c != 0) return c;
    }
    return as.length.compareTo(bs.length);
  }

  bool operator <(Object other) => other is Semver && compareTo(other) < 0;
  bool operator >(Object other) => other is Semver && compareTo(other) > 0;
  bool operator <=(Object other) => other is Semver && compareTo(other) <= 0;
  bool operator >=(Object other) => other is Semver && compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Semver &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch &&
      preRelease == other.preRelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  /// Bump one component, resetting the lower ones — what the auto-release
  /// workflow does on every merge to `main`.
  Semver next(String kind) {
    switch (kind) {
      case 'major':
        return Semver(major + 1, 0, 0);
      case 'minor':
        return Semver(major, minor + 1, 0);
      case 'prerelease':
        return Semver(major, minor, patch, preRelease: _bumpRc(preRelease));
      default:
        return Semver(major, minor, patch + 1);
    }
  }

  static String _bumpRc(String pre) {
    final m = RegExp(r'^rc\.(\d+)$').firstMatch(pre);
    if (m == null) return 'rc.1';
    return 'rc.${int.parse(m.group(1)!) + 1}';
  }

  @override
  String toString() {
    final base = '$major.$minor.$patch';
    final pre = preRelease.isEmpty ? '' : '-$preRelease';
    final b = build.isEmpty ? '' : '+$build';
    return '$base$pre$b';
  }
}
