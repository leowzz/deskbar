import 'dart:convert';
import 'package:desklet/connection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native TLS pinning, approval, encrypted restore, WSS and revocation',
    (tester) async {
      const invitation = String.fromEnvironment('DESKLET_INVITE');
      expect(
        invitation,
        isNotEmpty,
        reason: 'Start the Rust Android fixture first',
      );
      const native = MethodChannel('app.desklet/connection');
      await native.invokeMethod<void>('forget');
      final connection = Connection();
      await connection.start();
      addTearDown(connection.dispose);

      // A wrong pin must fail before sending the one-time secret.
      final uri = Uri.parse(invitation);
      final params = Map<String, List<String>>.from(uri.queryParametersAll);
      params['pin'] = ['sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='];
      await connection.pair(
        uri.replace(queryParameters: params).toString(),
        '连接测试屏幕',
      );
      expect(connection.hostName, isNull);
      expect(connection.error, contains('核验'));

      await connection.pair(invitation, '连接测试屏幕');
      Future<void> until(bool Function() predicate) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!predicate() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(predicate(), isTrue, reason: connection.error);
      }

      await until(() => connection.phase == ConnectionPhase.online);
      final stored = jsonDecode(
        (await native.invokeMethod<String>('restore'))!,
      );
      expect(stored['name'], 'Desklet 连接测试');
      await connection.setActive(false);
      await connection.setActive(true);
      await until(() => connection.phase == ConnectionPhase.online);
      await until(() => connection.phase == ConnectionPhase.unpaired);
      expect(await native.invokeMethod<String>('restore'), isNull);
      expect(connection.error, contains('移除'));
    },
  );
}
