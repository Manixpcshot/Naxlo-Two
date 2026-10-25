import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:naxlo_core/naxlo_core.dart';

/// One fetched subscription, before it is merged into a profile.
class SubscriptionFetch {
  const SubscriptionFetch({required this.result, required this.headers, this.error = ''});

  final SubscriptionResult result;
  final Map<String, String> headers;
  final String error;

  bool get ok => error.isEmpty && result.nodes.isNotEmpty;
}

/// Pulls a subscription URL over HTTPS and decodes it.
///
/// `User-Agent` is not decoration: several panels gate on known client UAs, and
/// more importantly a distinctive UA makes a blocked-by-mistake subscription
/// debuggable from the server's access log instead of a support ticket that says
/// "it returns nothing".
class SubscriptionService {
  SubscriptionService({this.client, this.timeout = const Duration(seconds: 20)});

  final HttpClient? client;
  final Duration timeout;

  static const String userAgent = '$kNaxloAgent/$kNaxloVersion (+https://github.com/Manixpcshot/Naxlo-Two)';

  Future<SubscriptionFetch> fetch(String url) async {
    late final HttpClient http;
    var owns = false;
    try {
      final uri = Uri.parse(url.trim());
      if (uri.scheme != 'https' && uri.scheme != 'http') {
        return SubscriptionFetch(result: const SubscriptionResult(nodes: <ServerNode>[], errors: <String>[]), headers: const <String, String>{}, error: 'not a URL');
      }
      if (uri.scheme == 'http') {
        // Not a hard failure: some panels are still LAN-only, but the user is
        // about to send a subscription token (which is a credential) in clear
        // text, so say so once instead of silently.
        return SubscriptionFetch(
          result: const SubscriptionResult(nodes: <ServerNode>[], errors: <String>[]),
          headers: const <String, String>{},
          error: 'plain http refused: use https (the subscription URL is a bearer token)',
        );
      }
      http = client ?? (HttpClient()..connectionTimeout = timeout);
      owns = client == null;
      final request = await http.openUrl('GET', uri);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'text/plain, application/octet-stream, */*');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        return SubscriptionFetch(
          result: const SubscriptionResult(nodes: <ServerNode>[], errors: <String>[]),
          headers: const <String, String>{},
          error: 'HTTP ${response.statusCode}',
        );
      }
      final headers = <String, String>{};
      response.headers.forEach((name, values) => headers[name] = values.join(', '));
      final body = await response.transform(utf8.decoder).join();
      final result = SubscriptionParser.decode(body, headers: headers);
      return SubscriptionFetch(result: result, headers: headers);
    } on SocketException catch (e) {
      return SubscriptionFetch(
        result: const SubscriptionResult(nodes: <ServerNode>[], errors: <String>[]),
        headers: const <String, String>{},
        error: 'network: ${e.message}',
      );
    } on TimeoutException {
      return SubscriptionFetch(
        result: const SubscriptionResult(nodes: <ServerNode>[], errors: <String>[]),
        headers: const <String, String>{},
        error: 'timed out after ${timeout.inSeconds}s',
      );
    } on FormatException catch (e) {
      return SubscriptionFetch(
        result: const SubscriptionResult(nodes: <ServerNode>[], errors: <String>[]),
        headers: const <String, String>{},
        error: 'bad URL: ${e.message}',
      );
    } finally {
      if (owns) http.close(force: true);
    }
  }
}
