/// API failures contain application-written messages, never raw service payloads.
class TranslationFailure implements Exception {
  const TranslationFailure(this.code, this.message, {this.retryable = false});
  final String code;
  final String message;
  final bool retryable;

  factory TranslationFailure.fromStatus(int status) => switch (status) {
    401 => const TranslationFailure(
      'authentication',
      'API Key 无效或已过期，请检查密钥及所属地域。',
    ),
    403 => const TranslationFailure(
      'permission',
      '服务拒绝访问，请检查 Workspace、地域及模型权限。',
    ),
    404 => const TranslationFailure(
      'endpoint',
      '接口或模型不存在，请检查完整 Endpoint 与模型 ID。',
    ),
    429 => const TranslationFailure(
      'rate_limit',
      '请求限流或额度不足，请检查额度并稍后重试。',
      retryable: true,
    ),
    >= 500 => const TranslationFailure(
      'service',
      '翻译服务暂时不可用，请稍后重试。',
      retryable: true,
    ),
    _ => TranslationFailure(
      'http_$status',
      '翻译请求被拒绝（HTTP $status），请检查模型和语言设置。',
    ),
  };

  factory TranslationFailure.fromService(Object? code) {
    // Only classify provider text; never return it because it can echo secrets,
    // transcript content, headers, or endpoint query strings.
    final value = code is String ? code.toLowerCase() : '';
    if (value.contains('key') || value.contains('auth')) {
      return TranslationFailure.fromStatus(401);
    }
    if (value.contains('quota') || value.contains('balance')) {
      return const TranslationFailure('quota', '翻译服务额度不足，请检查账户计费状态。');
    }
    if (value.contains('rate') || value.contains('throttl')) {
      return TranslationFailure.fromStatus(429);
    }
    if (value.contains('region') ||
        value.contains('workspace') ||
        value.contains('permission')) {
      return TranslationFailure.fromStatus(403);
    }
    return const TranslationFailure('protocol', '服务返回错误，请检查地域、模型和会话参数。');
  }

  @override
  String toString() => message;
}

class TranslationEvent {
  const TranslationEvent({
    required this.generation,
    required this.segmentId,
    required this.revision,
    required this.text,
    this.stash = '',
    required this.isFinal,
    this.original,
    this.audioStart,
    this.audioEnd,
    this.isSource = false,
    this.interrupted = false,
    this.engine = 'qwen3.8-livetranslate-flash-realtime',
  });
  final int generation;
  final String segmentId;
  final int revision;
  final String text;
  final String stash;
  final bool isFinal;
  final String? original;
  final Duration? audioStart;
  final Duration? audioEnd;
  final bool isSource;
  final bool interrupted;
  final String engine;
  String get displayText => '$text$stash';
}

enum RealtimeState {
  idle,
  connecting,
  configuring,
  ready,
  finishing,
  finished,
  canceled,
  failed,
}

/// Endpoints are never logged, as their query parameters can contain secrets.
Uri validateTranslationEndpoint(
  String value, {
  required bool webSocket,
  bool allowLocalInsecure = false,
  String workspaceId = '',
}) {
  var expanded = value.trim();
  if (expanded.contains('{WorkspaceId}')) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$').hasMatch(workspaceId)) {
      throw const TranslationFailure('workspace', '请先填写有效的 Workspace ID。');
    }
    expanded = expanded.replaceAll('{WorkspaceId}', workspaceId);
  }
  if (expanded.contains('{') ||
      expanded.contains('}') ||
      expanded.contains('%7B') ||
      expanded.contains('%7D')) {
    throw const TranslationFailure('endpoint', 'Endpoint 仍包含未填写的占位符。');
  }
  final uri = Uri.tryParse(expanded);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const TranslationFailure('endpoint', '请输入有效且不含用户名或密码的完整 Endpoint。');
  }
  final secure = webSocket ? 'wss' : 'https';
  final insecure = webSocket ? 'ws' : 'http';
  final local = const [
    'localhost',
    '127.0.0.1',
    '::1',
    '[::1]',
  ].contains(uri.host);
  if (uri.scheme != secure &&
      !(allowLocalInsecure && local && uri.scheme == insecure)) {
    throw TranslationFailure('tls', 'Endpoint 必须使用 $secure，明文连接仅限显式启用的本机开发服务。');
  }
  return uri;
}

void configureProxy(dynamic client, String? proxy) {
  if (proxy == null || proxy.trim().isEmpty) return;
  final uri = Uri.tryParse(proxy);
  if (uri == null ||
      uri.scheme != 'http' ||
      uri.host.isEmpty ||
      !uri.hasPort ||
      uri.userInfo.isNotEmpty) {
    throw const TranslationFailure('proxy', '代理请使用 http://主机:端口，不接受嵌入的凭据。');
  }
  client.findProxy = (Uri _) => 'PROXY ${uri.host}:${uri.port}';
}
