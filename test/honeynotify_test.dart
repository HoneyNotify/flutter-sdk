import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeynotify/honeynotify.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakePushAdapter implements HoneyNotifyPushAdapter {
  FakePushAdapter({this.token = 'apns-token'});

  final String token;
  final refreshController = StreamController<void>.broadcast();

  @override
  Stream<void> get onTokenRefresh => refreshController.stream;

  @override
  Future<HoneyNotifyPermissionStatus> permissionStatus() async =>
      HoneyNotifyPermissionStatus.authorized;

  @override
  Future<String?> providerToken() async => token;

  @override
  Future<HoneyNotifyPermissionStatus> requestPermission({
    bool includeCriticalAlerts = false,
  }) async =>
      HoneyNotifyPermissionStatus.authorized;
}

class FakeStore implements HoneyNotifyStore {
  final values = <String, String>{};

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> remove(String key) async => values.remove(key) != null;

  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return true;
  }
}

void main() {
  test('registers the native provider token and stores the device ID',
      () async {
    final store = FakeStore();
    late Map<String, dynamic> requestBody;
    final client = MockClient((request) async {
      requestBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('{"device_id":"device-1"}', 200);
    });
    final honeyNotify = HoneyNotify(
      clientKey: 'ps_public_test',
      platform: HoneyNotifyPlatform.ios,
      pushAdapter: FakePushAdapter(),
      storeFactory: () async => store,
      httpClient: client,
    );

    final id = await honeyNotify.requestPermissionAndRegister(
      options: const HoneyNotifyRegistrationOptions(
        externalUserId: 'customer-1',
        tags: {'plan': 'pro'},
      ),
    );
    expect(id, 'device-1');
    expect(requestBody['platform'], 'ios');
    expect(requestBody['push_token'], 'apns-token');
    expect(store.values['honeynotify.deviceId'], 'device-1');
  });

  test('maps custom events and includes the stored device ID', () async {
    final store = FakeStore()..values['honeynotify.deviceId'] = 'device-2';
    late Map<String, dynamic> requestBody;
    final honeyNotify = HoneyNotify(
      clientKey: 'ps_public_test',
      platform: HoneyNotifyPlatform.android,
      pushAdapter: FakePushAdapter(token: 'fcm-token'),
      storeFactory: () async => store,
      httpClient: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      }),
    );
    await honeyNotify.track(
      'checkout.completed',
      metadata: const {'order_id': '42'},
    );
    expect(requestBody['event_type'], 'custom');
    expect(requestBody['event_name'], 'checkout.completed');
    expect(requestBody['device_id'], 'device-2');
  });

  test('normalizes unknown interruption levels', () {
    final honeyNotify = HoneyNotify(
      clientKey: 'ps_public_test',
      platform: HoneyNotifyPlatform.android,
      pushAdapter: FakePushAdapter(),
      storeFactory: () async => FakeStore(),
    );
    final notification = honeyNotify.notificationFrom({
      'honeynotify_notification_id': 'notification-1',
      'honeynotify_interruption_level': 'unknown',
    });
    expect(notification.id, 'notification-1');
    expect(notification.interruptionLevel, HoneyNotifyInterruptionLevel.active);
    expect(notification.channelId, 'honeynotify_active');
  });

  test('refreshes identified devices with a fresh identity token', () async {
    final push = FakePushAdapter();
    final store = FakeStore()
      ..values['honeynotify.externalUserId'] = 'customer-7'
      ..values['honeynotify.tags'] = '{"plan":"pro"}';
    final refreshed = Completer<void>();
    late Map<String, dynamic> requestBody;
    final honeyNotify = HoneyNotify(
      clientKey: 'ps_public_test',
      platform: HoneyNotifyPlatform.ios,
      pushAdapter: push,
      storeFactory: () async => store,
      httpClient: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        refreshed.complete();
        return http.Response('{"device_id":"device-7"}', 200);
      }),
    );
    final subscription = honeyNotify.startTokenRefreshListener(
      identityTokenProvider: (externalUserId) async =>
          'token-for-$externalUserId',
      onError: (error, stackTrace) =>
          refreshed.completeError(error, stackTrace),
    );
    push.refreshController.add(null);
    await refreshed.future;
    expect(requestBody['external_user_id'], 'customer-7');
    expect(requestBody['identity_token'], 'token-for-customer-7');
    expect(requestBody['tags'], {'plan': 'pro'});
    await subscription.cancel();
    await push.refreshController.close();
  });
}
