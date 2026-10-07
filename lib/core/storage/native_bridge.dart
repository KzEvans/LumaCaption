import 'package:flutter/services.dart';

class NativeBridge {
  static const channel = MethodChannel('lumacaption/native');
  static const events = EventChannel('lumacaption/audio');
  Future<T?> call<T>(String method, [Map<String, dynamic>? args]) =>
      channel.invokeMethod<T>(method, args);
  Stream<dynamic> get stream => events.receiveBroadcastStream();
  Future<String?> secret(String account) =>
      call<String>('secrets.read', {'account': account});
  Future<void> saveSecret(String account, String value) =>
      call<void>('secrets.write', {'account': account, 'value': value});
}
