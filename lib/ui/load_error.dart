import 'package:dio/dio.dart';

import '../l10n/l10n.dart';

/// The reason shown under 加载失败, worded like the original.
///
/// OBSERVED (2026-11-09, mock sites answering HTTP 500 with `{"error":"mock category failure"}`): the original shows
/// `HTTP 500：mock category failure`, i.e. the status code and the script's own message. The other texts come from
/// the original's zh strings: 连接 catpaw 服务超时，请稍后重试 / 无法连接 catpaw 服务，请确认本地服务已启动 /
/// catpaw 服务证书校验失败.
String describeLoadError(Object error, AppLocalizations l) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return l.catpawTimeoutError;
      case DioExceptionType.connectionError:
        return l.catpawUnreachable;
      case DioExceptionType.badCertificate:
        return l.catpawBadCertificate;
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode ?? 0;
        final message = _responseMessage(error.response);
        return message.isEmpty ? 'HTTP $code' : l.httpError(code, message);
      default:
        break;
    }
    return error.message ?? '${error.error ?? error}';
  }
  final text = '$error';
  return text.startsWith('Exception: ') ? text.substring('Exception: '.length) : text;
}

String _responseMessage(Response<dynamic>? res) {
  final data = res?.data;
  if (data is Map) {
    // fastify's error body `{statusCode, error: <reason phrase>, message}` (OBSERVED from catpaw, 2026-11-10): the
    // original shows the message, e.g. `HTTP 500：Request failed with status code 403`.
    final keys = data.containsKey('statusCode') ? const ['message', 'error', 'msg'] : const ['error', 'message', 'msg'];
    for (final key in keys) {
      final v = data[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
  }
  if (data is String && data.trim().isNotEmpty) {
    final text = data.trim();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
  return res?.statusMessage?.trim() ?? '';
}
