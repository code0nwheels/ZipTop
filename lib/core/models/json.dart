import 'dart:convert';

/// Lenient readers for backend JSON. Every field is treated as optional, as in
/// the Android client: a missing or mistyped value becomes null or empty.
typedef Json = Map<String, dynamic>;

Json? asJson(Object? value) {
  if (value is Map) {
    return value.map((key, v) => MapEntry(key.toString(), v));
  }
  if (value is String && value.isNotEmpty) {
    try {
      return asJson(jsonDecode(value));
    } catch (_) {
      return null;
    }
  }
  return null;
}

String? asString(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool? asBool(Object? value) => value is bool ? value : null;

List<String> asStringList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (asString(item) != null) asString(item)!,
  ];
}

List<T> asList<T>(Object? value, T? Function(Json json) parse) {
  if (value is! List) return const [];
  final out = <T>[];
  for (final item in value) {
    final json = asJson(item);
    if (json == null) continue;
    final parsed = parse(json);
    if (parsed != null) out.add(parsed);
  }
  return out;
}

Map<String, T> asMapOf<T>(Object? value, T? Function(Object? v) parse) {
  if (value is! Map) return const {};
  final out = <String, T>{};
  value.forEach((key, v) {
    final parsed = parse(v);
    if (parsed != null) out[key.toString()] = parsed;
  });
  return out;
}

/// ISO-8601 with offset, e.g. `2026-09-14T15:00:00+00:00`.
DateTime? asTime(Object? value) {
  final text = asString(value);
  if (text == null || text.isEmpty) return null;
  return DateTime.tryParse(text);
}
