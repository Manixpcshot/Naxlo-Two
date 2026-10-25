// gen_samples.dart — write one config per (engine × protocol) to a directory.
//
//   dart run tool/gen_samples.dart build/engine-samples
//
// This exists because a wrong JSON key in a config builder is not a Dart error:
// `xray run` just refuses the file, on the user's machine, at connect time. The
// generator produces real output from the real builders, and
// scripts/verify-engine-config.sh pipes every file through `xray test` /
// `sing-box check`. If a builder starts emitting a field an engine rejects, that
// pair fails in CI instead of in a support thread.
//
// Keys and addresses are fake but well-formed; nothing here can connect to
// anything.
import 'dart:io';

import 'package:naxlo_core/naxlo_core.dart';

void main(List<String> args) {
  final outDir = Directory(args.isEmpty ? 'build/engine-samples' : args[0]);
  outDir.createSync(recursive: true);

  var written = 0;
  var warned = 0;

  void emit(String label, EngineKind engine, GeneratedConfig cfg) {
    final name = '${engine == EngineKind.xray ? 'xray' : 'singbox'}-$label.json';
    File('${outDir.path}/$name').writeAsStringSync('${cfg.json}\n');
    written++;
    if (cfg.warnings.isNotEmpty) {
      warned++;
      stdout.writeln('  $name: ${cfg.warnings.join(' | ')}');
    }
  }

  Profile profile(List<ServerNode> nodes, EngineKind engine, RoutingConfig routing) => Profile(
        id: 'sample',
        name: 'samples',
        servers: nodes,
        engine: engine,
        routing: routing,
      );

  // Two routing shapes on purpose: `proxyAll` emits no rules, `bypassLan` emits
  // the private-range set, and both have to survive the engine's parser.
  const proxyAll = RoutingConfig(preset: RoutingPreset.proxyAll);
  const lanBypass = RoutingConfig(preset: RoutingPreset.bypassLan);

  for (final engine in EngineKind.values) {
    // Deliberately no `engine:` here: which core to run is a per-profile choice
    // (`Profile.engine`), because two profiles on one machine can use different
    // engines. Ports and inbounds are app-wide.
    final settings = RuntimeSettings(
      listenAddress: '127.0.0.1',
      socksPort: 10808,
      httpPort: 10809,
      proxyMode: ProxyMode.systemProxy,
    );

    final vlessReality = ServerNode(
      id: 'n-vless-reality',
      name: 'VLESS Reality',
      address: 'reality.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      userId: '4b2f0d1e-6f1a-4c3e-9b5e-2a1c7d8e9f01',
      tls: const TlsOptions(
        security: SecurityLayer.reality,
        serverName: 'www.microsoft.com',
        // 43 base64url chars, which is what a real X25519 public key encodes to.
        // `xray test` parses this, so a truncated key here fails CI instead of
        // shipping a sample that only looks well-formed.
        publicKey: 'rwQj9d7FVzLq2dsca4-XCYvA1d_m6kPwHwrBT577CW0',
        shortId: '6ba85179',
        fingerprint: 'chrome',
      ),
      transportOptions: const TransportOptions(transport: Transport.tcp),
    );

    final vlessWsTls = ServerNode(
      id: 'n-vless-ws',
      name: 'VLESS WS+TLS',
      address: 'ws.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      userId: '9c0a1b2c-3d4e-5f60-7182-93a4b5c6d7e8',
      tls: const TlsOptions(
        security: SecurityLayer.tls,
        serverName: 'ws.example.com',
        alpn: <String>['h2', 'http/1.1'],
        fingerprint: 'firefox',
      ),
      transportOptions: const TransportOptions(
        transport: Transport.ws,
        path: '/ray',
        headers: <String, String>{'Host': 'ws.example.com'},
      ),
    );

    final vmessCipher = ServerNode(
      id: 'n-vmess',
      name: 'VMess AES-GCM',
      address: 'vmess.example.com',
      port: 12346,
      protocol: ProxyProtocol.vmess,
      userId: '7d1c2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f',
      alterId: 0,
      cipher: VmessCipher.aes128Gcm,
      tls: const TlsOptions(security: SecurityLayer.tls, serverName: 'vmess.example.com'),
      transportOptions: const TransportOptions(transport: Transport.ws, path: '/vmess'),
      mux: const MuxOptions(enabled: true, concurrency: 8),
    );

    final trojanNode = ServerNode(
      id: 'n-trojan',
      name: 'Trojan TLS',
      address: 'trojan.example.com',
      port: 8443,
      protocol: ProxyProtocol.trojan,
      password: '0123456789abcdef0123456789abcdef',
      tls: const TlsOptions(
        security: SecurityLayer.tls,
        serverName: 'trojan.example.com',
        alpn: <String>['h2', 'http/1.1'],
      ),
    );

    final ssNode = ServerNode(
      id: 'n-ss',
      name: 'Shadowsocks AEAD',
      address: 'ss.example.com',
      port: 8443,
      protocol: ProxyProtocol.shadowsocks,
      // The SS cipher travels in `userId` (see ShareLinkParser._parseShadowsocks)
      // so the editor, both builders and the exporter read it from one place.
      userId: 'aes-256-gcm',
      password: 'y6GwZ0pV0mUdEe3kQ4rTfA==',
      transportOptions: const TransportOptions(transport: Transport.tcp),
    );

    final socksNode = ServerNode(
      id: 'n-socks',
      name: 'SOCKS5 upstream',
      address: 'socks.example.com',
      port: 1070,
      protocol: ProxyProtocol.socks,
      userId: 'user',
      password: 'pass',
    );

    final nodes = <ServerNode>[vlessReality, vlessWsTls, vmessCipher, trojanNode, ssNode, socksNode];
    final p = profile(nodes, engine, lanBypass);

    for (final node in nodes) {
      emit(
        node.id.substring(2).replaceAll('_', '-'),
        engine,
        engine == EngineKind.xray
            ? XrayConfigBuilder(p, node, settings).build()
            : SingBoxConfigBuilder(p, node, settings).build(),
      );
    }

    // Routing preset variant: proxy-all must still produce a valid file.
    emit(
      'routing-proxyall',
      engine,
      engine == EngineKind.xray
          ? XrayConfigBuilder(profile(nodes, engine, proxyAll), vlessWsTls, settings).build()
          : SingBoxConfigBuilder(profile(nodes, engine, proxyAll), vlessWsTls, settings).build(),
    );

    // TUN shape only exists for sing-box, and only passes `check` if the
    // privileges block is present, so this is the file that catches a bad stack
    // name more than any unit test can.
    if (engine == EngineKind.singBox) {
      emit(
        'tun',
        engine,
        SingBoxConfigBuilder(
          p,
          vlessReality,
          const RuntimeSettings(
            proxyMode: ProxyMode.tun,
            isPrivileged: true,
            mtu: 1500,
            enableSocksInbound: false,
            enableHttpInbound: false,
          ),
        ).build(),
      );
    }
  }

  stdout.writeln(
    'gen_samples: $written config(s) in ${outDir.path}'
    '${warned == 0 ? '' : ' ($warned with builder warnings)'}',
  );
}
