import 'package:dio/dio.dart';

import '../auth/auth_events.dart';
import '../auth/token_store.dart';
import '../models/json.dart';
import '../models/playback.dart';
import 'api_config.dart';

/// The one HTTP entry point for the backend.
///
/// - Tries each candidate host in order and moves on only when a host cannot
///   be reached; any HTTP response, including 4xx/5xx, is returned as it is.
/// - Adds the bearer token.
/// - Raises [Unauthorized] on 401 (after clearing the token) and
///   [AccountBlocked] on a 403 that says the account is expired or inactive.
class ApiClient {
  ApiClient({
    required this.config,
    required this.tokens,
    required this.events,
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 30),
                sendTimeout: const Duration(seconds: 30),
              ),
            );

  final ApiConfig config;
  final TokenStore tokens;
  final AuthEvents events;
  final Dio _dio;

  Future<Response<dynamic>> get(
    String path, {
    Map<String, Object?>? query,
    Map<String, String?>? headers,
  }) =>
      send('GET', path, query: query, headers: headers);

  Future<Response<dynamic>> post(String path, {Object? data}) =>
      send('POST', path, data: data);

  Future<Response<dynamic>> put(String path, {Object? data}) =>
      send('PUT', path, data: data);

  Future<Response<dynamic>> delete(String path) => send('DELETE', path);

  /// Throws [ApiException] only when no host could be reached.
  Future<Response<dynamic>> send(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? data,
    Map<String, String?>? headers,
  }) async {
    final token = await tokens.read();
    final requestHeaders = <String, String>{
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      if (headers != null)
        for (final entry in headers.entries)
          if (entry.value != null) entry.key: entry.value!,
    };
    final cleanQuery = <String, dynamic>{
      if (query != null)
        for (final entry in query.entries)
          if (entry.value != null) entry.key: entry.value,
    };

    DioException? lastError;
    for (final base in config.candidates) {
      try {
        final response = await _dio.request<dynamic>(
          '$base$path',
          data: data,
          queryParameters: cleanQuery.isEmpty ? null : cleanQuery,
          options: Options(
            method: method,
            headers: requestHeaders,
            validateStatus: (_) => true,
            responseType: ResponseType.json,
          ),
        );
        config.markWorking(base);
        await _raiseAccountEvents(response);
        return response;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        // Could not reach this host; try the next candidate.
        lastError = e;
      }
    }
    throw ApiException(
      "Can't reach ZipStreams. Check your internet connection."
      '${lastError?.message == null ? '' : ' (${lastError!.message})'}',
    );
  }

  Future<void> _raiseAccountEvents(Response<dynamic> response) async {
    final status = response.statusCode;
    if (status == 401) {
      await tokens.clear();
      events.emit(const Unauthorized());
    } else if (status == 403) {
      final body = asJson(response.data);
      final expired = asBool(body?['account_expired']) ?? false;
      final inactive = asBool(body?['account_inactive']) ?? false;
      if (expired || inactive) {
        events.emit(AccountBlocked(expired: expired, inactive: inactive));
      }
    }
  }
}

extension ResponseX on Response<dynamic> {
  bool get ok {
    final code = statusCode ?? 0;
    return code >= 200 && code < 300;
  }

  Json? get json => asJson(data);

  /// The backend's error text, from either the v2 shape
  /// `{"error": {"code", "message"}}` or the flat `{"error": "..."}`.
  String? get errorMessage {
    final error = json?['error'];
    if (error is String && error.isNotEmpty) return error;
    final nested = asJson(error);
    return asString(nested?['message']);
  }

  String? get errorCode => asString(asJson(json?['error'])?['code']);
}
