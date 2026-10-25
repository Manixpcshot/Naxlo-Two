import 'dart:convert';

/// Compact JSON without the space after `:` / `,` that `jsonEncode` emits.
/// Engines do not care, but it makes the generated config diffable in tests
/// and in `git diff` when a profile is exported.
String encodeCompactJson(Map<String, Object?> value) {
  return _compact(json.encode(value));
}

String _compact(String s) {
  final out = StringBuffer();
  var inString = false;
  var escaped = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (inString) {
      out.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
      out.write(ch);
      continue;
    }
    if (ch == ':' || ch == ',') {
      out.write(ch);
      // swallow the single space json.encode inserts
      if (i + 1 < s.length && s[i + 1] == ' ') i++;
      continue;
    }
    out.write(ch);
  }
  return out.toString();
}

/// Reads a `Map<String, dynamic>`-ish value defensively: config blobs decoded
/// from user-supplied JSON can be missing keys or have the wrong type, and the
/// engine process must never crash on a typo in an imported file.
Map<String, Object?> asMap(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final e in value.entries) e.key.toString(): e.value,
    };
  }
  return <String, Object?>{};
}

List<Object?> asList(Object? value) {
  if (value is List) return value;
  return const <Object?>[];
}

String asString(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value is String) return value;
  return value.toString();
}

int asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

double asDouble(Object? value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? fallback;
  return fallback;
}

bool asBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final s = value.toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return fallback;
}

List<String> asStringList(Object? value) {
  if (value is List) {
    return <String>[for (final e in value) e.toString()];
  }
  return const <String>[];
}

/// Drops null and empty entries so generated configs stay readable.
Map<String, Object?> pruneNulls(Map<String, Object?> input) {
  final out = <String, Object?>{};
  input.forEach((key, value) {
    if (value == null) return;
    if (value is String && value.isEmpty) return;
    if (value is List && value.isEmpty) return;
    if (value is Map && value.isEmpty) return;
    out[key] = value;
  });
  return out;
}
