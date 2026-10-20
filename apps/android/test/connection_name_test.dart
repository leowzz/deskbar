import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deskbar/connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.deskbar/connection');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'automatic pairing uses the model and explicit names remain unchanged',
    () async {
      final names = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'deviceName') return 'Xiaomi 14 Ultra';
        if (call.method == 'pair') names.add(call.arguments['name'] as String);
        return null;
      });
      final connection = Connection();
      await connection.pair('invitation');
      await connection.pair('invitation', '桌面副屏');
      expect(names, ['Xiaomi 14 Ultra', '桌面副屏']);
      connection.dispose();
    },
  );

  test('model lookup failure falls back without blocking pairing', () async {
    String? name;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceName') {
        throw PlatformException(code: 'unavailable');
      }
      if (call.method == 'pair') name = call.arguments['name'] as String;
      return null;
    });
    final connection = Connection();
    await connection.pair('invitation');
    expect(name, 'Android 工作台');
    connection.dispose();
  });

  test('cancel during model lookup never starts pairing', () async {
    final model = Completer<String>();
    var paired = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceName') return model.future;
      if (call.method == 'pair') paired = true;
      return null;
    });
    final connection = Connection();
    final pairing = connection.pair('invitation');
    await connection.cancel();
    model.complete('Pixel 9');
    await pairing;
    expect(paired, isFalse);
    connection.dispose();
  });
}
