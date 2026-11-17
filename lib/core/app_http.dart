import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

bool _isLoopbackHost(String host) =>
    host == '127.0.0.1' || host == 'localhost' || host == '::1' || host == '[::1]';

/// Shared Dio builder with bounded timeouts and direct loopback routing (bypasses stale VPN/system HTTP proxies).
Dio createAppDio({
  String? baseUrl,
  Duration connectTimeout = const Duration(seconds: 10),
  Duration receiveTimeout = const Duration(seconds: 20),
  Duration sendTimeout = const Duration(seconds: 15),
  Map<String, dynamic>? headers,
  bool followRedirects = true,
  ValidateStatus? validateStatus,
}) {
  final dio = Dio(BaseOptions(
    baseUrl: baseUrl ?? '',
    connectTimeout: connectTimeout,
    receiveTimeout: receiveTimeout,
    sendTimeout: sendTimeout,
    headers: headers,
    followRedirects: followRedirects,
    validateStatus: validateStatus,
  ));
  if (dio.httpClientAdapter case final IOHttpClientAdapter adapter) {
    adapter.createHttpClient = () {
      final client = HttpClient();
      client.connectionTimeout = connectTimeout;
      client.findProxy = (uri) => _isLoopbackHost(uri.host) ? 'DIRECT' : HttpClient.findProxyFromEnvironment(uri);
      return client;
    };
  }
  return dio;
}
