/// The tunnel engine a profile runs on. Naxlo Two speaks to both, so the UI
/// can offer a choice per profile instead of hard-wiring one core.
enum EngineKind {
  xray('xray', 'Xray-core', 'MPL-2.0 · https://github.com/XTLS/Xray-core'),
  singBox('sing-box', 'sing-box', 'GPL-3.0 · https://github.com/SagerNet/sing-box');

  const EngineKind(this.cliName, this.label, this.licenseNotice);

  /// Name used in config `log` blocks, file names and CLI args.
  final String cliName;
  final String label;
  final String licenseNotice;

  static EngineKind fromName(String? value) {
    for (final e in EngineKind.values) {
      if (e.cliName == value || e.name == value) return e;
    }
    return EngineKind.xray;
  }

  Map<String, Object?> toJson() => <String, Object?>{'engine': cliName};

  /// CLI shape used by the supervisor: `xray run -c cfg.json` vs
  /// `sing-box run -c cfg.json`.
  List<String> runArgs(String configPath) {
    switch (this) {
      case EngineKind.xray:
        return <String>['run', '-config', configPath];
      case EngineKind.singBox:
        return <String>['run', '-c', configPath];
    }
  }

  /// `check`/`test` sub-command so a bad config never reaches the socket.
  List<String> verifyArgs(String configPath) {
    switch (this) {
      case EngineKind.xray:
        return <String>['test', '-config', configPath];
      case EngineKind.singBox:
        return <String>['check', '-c', configPath];
    }
  }
}
