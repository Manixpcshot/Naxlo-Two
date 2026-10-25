import '../json/json_utils.dart';

/// Stream transports. `raw`/`tcp` are the same thing under two names across
/// engines, so we normalize to [tcp] and let each config builder spell it.
enum Transport {
  tcp('tcp', 'TCP'),
  ws('ws', 'WebSocket'),
  grpc('grpc', 'gRPC'),
  httpUpgrade('httpupgrade', 'HTTPUpgrade'),
  xhttp('xhttp', 'XHTTP');

  const Transport(this.wireName, this.label);
  final String wireName;
  final String label;

  static Transport fromName(String? raw) {
    final s = asString(raw).trim().toLowerCase();
    switch (s) {
      case '':
      case 'tcp':
      case 'raw':
      case 'none':
        return Transport.tcp;
      case 'ws':
      case 'websocket':
        return Transport.ws;
      case 'grpc':
      case 'grpc+tls':
        return Transport.grpc;
      case 'httpupgrade':
        return Transport.httpUpgrade;
      case 'xhttp':
      case 'xhs':
        return Transport.xhttp;
    }
    return Transport.tcp;
  }

  bool get isGrpc => this == Transport.grpc;
  bool get usesPath => this == Transport.ws || this == Transport.httpUpgrade || this == Transport.xhttp;
}

/// Extra transport parameters (host/path/headers for ws, mode for xhttp, ...).
class TransportOptions {
  const TransportOptions({
    this.transport = Transport.tcp,
    this.host = '',
    this.path = '',
    this.headers = const <String, String>{},
    this.maxUploadSize = 0,
    this.maxConnectionReuse = 0,
    this.initialWindowsSize = 0,
    this.xhttpMode = 'auto',
    this.xhttpExtra = const <String, Object?>{},
    this.healthCheck = false,
  });

  final Transport transport;

  /// `Host` header / pseudo-authority for ws & httpupgrade.
  final String host;
  final String path;
  final Map<String, String> headers;

  /// gRPC multiplexing knobs (`streamSettings.grpcSettings`).
  final int maxUploadSize;
  final int maxConnectionReuse;
  final int initialWindowsSize;

  /// xhttp mode: auto | packet-over-stream | stream-one | stream-up.
  final String xhttpMode;
  final Map<String, Object?> xhttpExtra;

  /// Enable gRPC health check.
  final bool healthCheck;

  TransportOptions copyWith({
    Transport? transport,
    String? host,
    String? path,
    Map<String, String>? headers,
    int? maxUploadSize,
    int? maxConnectionReuse,
    String? xhttpMode,
  }) {
    return TransportOptions(
      transport: transport ?? this.transport,
      host: host ?? this.host,
      path: path ?? this.path,
      headers: headers ?? this.headers,
      maxUploadSize: maxUploadSize ?? this.maxUploadSize,
      maxConnectionReuse: maxConnectionReuse ?? this.maxConnectionReuse,
      initialWindowsSize: initialWindowsSize,
      xhttpMode: xhttpMode ?? this.xhttpMode,
      xhttpExtra: xhttpExtra,
      healthCheck: healthCheck,
    );
  }

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'transport': transport.wireName,
        'host': host,
        'path': path,
        if (headers.isNotEmpty) 'headers': Map<String, String>.from(headers),
        'maxUploadSize': maxUploadSize == 0 ? null : maxUploadSize,
        'maxConnectionReuse': maxConnectionReuse == 0 ? null : maxConnectionReuse,
        if (transport == Transport.xhttp) 'xhttpMode': xhttpMode,
        if (transport == Transport.xhttp && xhttpExtra.isNotEmpty)
          'xhttpExtra': Map<String, Object?>.from(xhttpExtra),
        if (transport.isGrpc) 'healthCheck': healthCheck,
      });

  static TransportOptions fromJson(Map<String, Object?> json) {
    final rawHeaders = json['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v.toString());
    }
    return TransportOptions(
      transport: Transport.fromName(asString(json['transport'])),
      host: asString(json['host']),
      path: asString(json['path']),
      headers: headers,
      maxUploadSize: asInt(json['maxUploadSize']),
      maxConnectionReuse: asInt(json['maxConnectionReuse']),
      initialWindowsSize: asInt(json['initialWindowsSize']),
      xhttpMode: asString(json['xhttpMode'], fallback: 'auto'),
      xhttpExtra: asMap(json['xhttpExtra']),
      healthCheck: asBool(json['healthCheck']),
    );
  }
}

/// TCP mux (h2 multiplexing in Xray terms). Kept as a small struct because both
/// engines expose different shapes and the defaults matter for throughput.
class MuxOptions {
  const MuxOptions({this.enabled = false, this.concurrency = 8, this.readBufferSize = 0});

  final bool enabled;
  final int concurrency;
  final int readBufferSize;

  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        'concurrency': concurrency,
        if (readBufferSize > 0) 'readBufferSize': readBufferSize,
      };

  static MuxOptions fromJson(Map<String, Object?> json) => MuxOptions(
        enabled: asBool(json['enabled']),
        concurrency: asInt(json['concurrency'], fallback: 8),
        readBufferSize: asInt(json['readBufferSize']),
      );

  static const MuxOptions disabled = MuxOptions();
}
