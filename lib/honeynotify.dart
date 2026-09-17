import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const _storagePrefix = 'honeynotify.';
const _standardEvents = <String>{
  'received',
  'confirmed_delivered',
  'opened',
  'clicked',
  'dismissed',
};

enum HoneyNotifyPlatform { ios, android }

enum HoneyNotifyPermissionStatus {
  notDetermined,
  denied,
  authorized,
  provisional,
}

enum HoneyNotifyInterruptionLevel {
  passive,
  active,
  timeSensitive,
  critical,
}

class HoneyNotifyRegistrationOptions {
  const HoneyNotifyRegistrationOptions({
    this.externalUserId,
    this.identityToken,
    this.tags = const {},
    this.locale,
    this.timezone,
    this.appVersion,
    this.deviceModel,
    this.osVersion,
    this.includeCriticalAlerts = false,
  });

  final String? externalUserId;
  final String? identityToken;
  final Map<String, String> tags;
  final String? locale;
  final String? timezone;
  final String? appVersion;
  final String? deviceModel;
  final String? osVersion;
  final bool includeCriticalAlerts;

  HoneyNotifyRegistrationOptions withExternalUserId(String value) {
    return HoneyNotifyRegistrationOptions(
      externalUserId: value,
      identityToken: identityToken,
      tags: tags,
      locale: locale,
      timezone: timezone,
      appVersion: appVersion,
      deviceModel: deviceModel,
      osVersion: osVersion,
      includeCriticalAlerts: includeCriticalAlerts,
    );
  }
}

class HoneyNotifyNotification {
  const HoneyNotifyNotification({
    required this.id,
    required this.clickUrl,
    required this.imageUrl,
    required this.interruptionLevel,
    required this.channelId,
    required this.data,
  });

  final String? id;
  final String? clickUrl;
  final String? imageUrl;
  final HoneyNotifyInterruptionLevel interruptionLevel;
  final String channelId;
  final Map<String, dynamic> data;
}

class HoneyNotifyException implements Exception {
  const HoneyNotifyException(this.message, {this.status = 0});

  final String message;
  final int status;

  @override
  String toString() => status == 0
      ? 'HoneyNotifyException: $message'
      : 'HoneyNotifyException: $message ($status)';
}

abstract interface class HoneyNotifyPushAdapter {
  Future<HoneyNotifyPermissionStatus> requestPermission({
    bool includeCriticalAlerts = false,
  });

  Future<HoneyNotifyPermissionStatus> permissionStatus();

  Future<String?> providerToken();

  Stream<void> get onTokenRefresh;
}

abstract interface class HoneyNotifyStore {
  String? getString(String key);

  Future<bool> setString(String key, String value);

  Future<bool> remove(String key);
}

class FirebaseHoneyNotifyPushAdapter implements HoneyNotifyPushAdapter {
  FirebaseHoneyNotifyPushAdapter(
    this.platform, {
    FirebaseMessaging? messaging,
  }) : _messaging = messaging ?? FirebaseMessaging.instance;

  final HoneyNotifyPlatform platform;
  final FirebaseMessaging _messaging;

  @override
  Stream<void> get onTokenRefresh =>
      _messaging.onTokenRefresh.map<void>((_) {});

  @override
  Future<HoneyNotifyPermissionStatus> permissionStatus() async {
    return _permissionStatus(
        (await _messaging.getNotificationSettings()).authorizationStatus);
  }

  @override
  Future<String?> providerToken() {
    return platform == HoneyNotifyPlatform.ios
        ? _messaging.getAPNSToken()
        : _messaging.getToken();
  }

  @override
  Future<HoneyNotifyPermissionStatus> requestPermission({
    bool includeCriticalAlerts = false,
  }) async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      criticalAlert: includeCriticalAlerts,
    );
    return _permissionStatus(settings.authorizationStatus);
  }

  HoneyNotifyPermissionStatus _permissionStatus(AuthorizationStatus status) {
    return switch (status) {
      AuthorizationStatus.authorized => HoneyNotifyPermissionStatus.authorized,
      AuthorizationStatus.provisional =>
        HoneyNotifyPermissionStatus.provisional,
      AuthorizationStatus.notDetermined =>
        HoneyNotifyPermissionStatus.notDetermined,
      _ => HoneyNotifyPermissionStatus.denied,
    };
  }
}

class SharedPreferencesHoneyNotifyStore implements HoneyNotifyStore {
  SharedPreferencesHoneyNotifyStore(this._preferences);

  final SharedPreferences _preferences;

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<bool> remove(String key) => _preferences.remove(key);

  @override
  Future<bool> setString(String key, String value) =>
      _preferences.setString(key, value);
}

class HoneyNotify {
  HoneyNotify({
    required this.clientKey,
    this.baseUrl = 'https://api.honeynotify.com',
    HoneyNotifyPlatform? platform,
    HoneyNotifyPushAdapter? pushAdapter,
    Future<HoneyNotifyStore> Function()? storeFactory,
    http.Client? httpClient,
  })  : platform = platform ?? _currentPlatform(),
        _pushAdapter = pushAdapter ??
            FirebaseHoneyNotifyPushAdapter(platform ?? _currentPlatform()),
        _storeFactory = storeFactory ?? _defaultStore,
        _httpClient = httpClient ?? http.Client() {
    if (!clientKey.startsWith('ps_public_')) {
      throw const HoneyNotifyException(
        'A HoneyNotify public client key beginning ps_public_ is required',
      );
    }
  }

  final String clientKey;
  final String baseUrl;
  final HoneyNotifyPlatform platform;
  final HoneyNotifyPushAdapter _pushAdapter;
  final Future<HoneyNotifyStore> Function() _storeFactory;
  final http.Client _httpClient;

  Future<String?> requestPermissionAndRegister({
    HoneyNotifyRegistrationOptions options =
        const HoneyNotifyRegistrationOptions(),
  }) async {
    final status = await _pushAdapter.requestPermission(
      includeCriticalAlerts: options.includeCriticalAlerts,
    );
    if (status != HoneyNotifyPermissionStatus.authorized &&
        status != HoneyNotifyPermissionStatus.provisional) {
      return null;
    }
    return registerCurrentToken(options: options);
  }

  Future<String> registerCurrentToken({
    HoneyNotifyRegistrationOptions options =
        const HoneyNotifyRegistrationOptions(),
  }) async {
    final token = await _pushAdapter.providerToken();
    if (token == null || token.isEmpty) {
      final provider = platform == HoneyNotifyPlatform.ios ? 'APNs' : 'FCM';
      throw HoneyNotifyException(
        'No $provider token is available; complete native Firebase setup and retry',
      );
    }
    return registerToken(token, options: options);
  }

  Future<String> registerToken(
    String token, {
    HoneyNotifyRegistrationOptions options =
        const HoneyNotifyRegistrationOptions(),
  }) async {
    final payload = <String, dynamic>{
      'platform': platform.name,
      'push_token': token,
      'tags': options.tags,
    };
    _putIfPresent(payload, 'external_user_id', options.externalUserId);
    _putIfPresent(payload, 'identity_token', options.identityToken);
    _putIfPresent(payload, 'locale', options.locale);
    _putIfPresent(payload, 'timezone', options.timezone);
    _putIfPresent(payload, 'app_version', options.appVersion);
    _putIfPresent(payload, 'device_model', options.deviceModel);
    _putIfPresent(payload, 'os_version', options.osVersion);

    final response = await _request('/v1/devices/register', 'POST', payload);
    final deviceId = response['device_id'];
    if (deviceId is! String || deviceId.isEmpty) {
      throw const HoneyNotifyException(
        'HoneyNotify returned an invalid registration response',
      );
    }

    final store = await _storeFactory();
    await Future.wait([
      store.setString('${_storagePrefix}deviceId', deviceId),
      store.setString('${_storagePrefix}pushToken', token),
      store.setString('${_storagePrefix}tags', jsonEncode(options.tags)),
      if (options.externalUserId == null)
        store.remove('${_storagePrefix}externalUserId')
      else
        store.setString(
          '${_storagePrefix}externalUserId',
          options.externalUserId!,
        ),
    ]);
    return deviceId;
  }

  StreamSubscription<void> startTokenRefreshListener({
    Future<String?> Function(String externalUserId)? identityTokenProvider,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    return _pushAdapter.onTokenRefresh.listen((_) async {
      try {
        final store = await _storeFactory();
        final token = await _pushAdapter.providerToken();
        if (token == null || token.isEmpty) return;
        final externalUserId =
            store.getString('${_storagePrefix}externalUserId');
        final identityToken =
            externalUserId != null && identityTokenProvider != null
                ? await identityTokenProvider(externalUserId)
                : null;
        await registerToken(
          token,
          options: HoneyNotifyRegistrationOptions(
            externalUserId: externalUserId,
            identityToken: identityToken,
            tags: _decodeTags(store.getString('${_storagePrefix}tags')),
          ),
        );
      } catch (error, stackTrace) {
        onError?.call(error, stackTrace);
      }
    });
  }

  Future<String> identify(
    String externalUserId, {
    HoneyNotifyRegistrationOptions options =
        const HoneyNotifyRegistrationOptions(),
  }) async {
    if (externalUserId.isEmpty) {
      throw const HoneyNotifyException('externalUserId is required');
    }
    final store = await _storeFactory();
    final token = store.getString('${_storagePrefix}pushToken');
    if (token == null || token.isEmpty) {
      throw const HoneyNotifyException('No push token is registered');
    }
    return registerToken(
      token,
      options: options.withExternalUserId(externalUserId),
    );
  }

  Future<void> logout() async {
    final store = await _storeFactory();
    final deviceId = store.getString('${_storagePrefix}deviceId');
    if (deviceId != null) {
      await _request(
        '/v1/devices/${Uri.encodeComponent(deviceId)}',
        'DELETE',
        null,
      );
    }
    await Future.wait([
      store.remove('${_storagePrefix}deviceId'),
      store.remove('${_storagePrefix}pushToken'),
      store.remove('${_storagePrefix}externalUserId'),
      store.remove('${_storagePrefix}tags'),
    ]);
  }

  Future<void> track(
    String event, {
    String? notificationId,
    Map<String, String> metadata = const {},
    DateTime? occurredAt,
  }) async {
    if (event.isEmpty) {
      throw const HoneyNotifyException('event is required');
    }
    final store = await _storeFactory();
    final payload = <String, dynamic>{
      'event_type': _standardEvents.contains(event) ? event : 'custom',
      'occurred_at': (occurredAt ?? DateTime.now().toUtc()).toIso8601String(),
      'metadata': metadata,
    };
    if (!_standardEvents.contains(event)) payload['event_name'] = event;
    _putIfPresent(payload, 'notification_id', notificationId);
    _putIfPresent(
      payload,
      'device_id',
      store.getString('${_storagePrefix}deviceId'),
    );
    await _request('/v1/events', 'POST', payload);
  }

  HoneyNotifyNotification notificationFrom(Map<String, dynamic> data) {
    final wireLevel = data['honeynotify_interruption_level'];
    final level = switch (wireLevel) {
      'passive' => HoneyNotifyInterruptionLevel.passive,
      'time_sensitive' => HoneyNotifyInterruptionLevel.timeSensitive,
      'critical' => HoneyNotifyInterruptionLevel.critical,
      _ => HoneyNotifyInterruptionLevel.active,
    };
    final defaultChannel = switch (level) {
      HoneyNotifyInterruptionLevel.passive => 'honeynotify_passive',
      HoneyNotifyInterruptionLevel.active => 'honeynotify_active',
      HoneyNotifyInterruptionLevel.timeSensitive =>
        'honeynotify_time_sensitive',
      HoneyNotifyInterruptionLevel.critical => 'honeynotify_critical',
    };
    return HoneyNotifyNotification(
      id: data['honeynotify_notification_id'] as String?,
      clickUrl: data['honeynotify_click_url'] as String?,
      imageUrl: data['honeynotify_image_url'] as String?,
      interruptionLevel: level,
      channelId:
          data['honeynotify_android_channel_id'] as String? ?? defaultChannel,
      data: data,
    );
  }

  HoneyNotifyNotification notificationFromRemoteMessage(
    RemoteMessage message,
  ) =>
      notificationFrom(message.data);

  Future<void> trackReceived(Map<String, dynamic> data) {
    return track('received', notificationId: notificationFrom(data).id);
  }

  Future<void> trackOpened(
    Map<String, dynamic> data, {
    String? actionId,
  }) {
    return track(
      actionId == null ? 'opened' : 'clicked',
      notificationId: notificationFrom(data).id,
      metadata: actionId == null ? const {} : {'action_id': actionId},
    );
  }

  Future<HoneyNotifyPermissionStatus> permissionStatus() =>
      _pushAdapter.permissionStatus();

  void close() => _httpClient.close();

  Future<Map<String, dynamic>> _request(
    String path,
    String method,
    Map<String, dynamic>? body,
  ) async {
    http.Response? response;
    Map<String, dynamic> responseBody = const {};
    final uri = Uri.parse('${baseUrl.replaceFirst(RegExp(r'/$'), '')}$path');
    for (var attempt = 0; attempt < 3; attempt++) {
      final headers = {
        'Authorization': 'Bearer $clientKey',
        'Content-Type': 'application/json',
      };
      response = method == 'DELETE'
          ? await _httpClient.delete(uri, headers: headers)
          : await _httpClient.post(
              uri,
              headers: headers,
              body: jsonEncode(body),
            );
      responseBody = _decodeObject(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return responseBody;
      }
      if (response.statusCode != 429 && response.statusCode < 500) break;
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
    final error = responseBody['error'];
    final message = error is Map<String, dynamic> && error['message'] is String
        ? error['message'] as String
        : 'HoneyNotify request failed';
    throw HoneyNotifyException(message, status: response?.statusCode ?? 0);
  }

  static Future<HoneyNotifyStore> _defaultStore() async {
    return SharedPreferencesHoneyNotifyStore(
      await SharedPreferences.getInstance(),
    );
  }

  static HoneyNotifyPlatform _currentPlatform() {
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => HoneyNotifyPlatform.ios,
      TargetPlatform.android => HoneyNotifyPlatform.android,
      _ => throw const HoneyNotifyException(
          'The Flutter SDK supports iOS and Android only',
        ),
    };
  }
}

void _putIfPresent(Map<String, dynamic> payload, String key, String? value) {
  if (value != null && value.isNotEmpty) payload[key] = value;
}

Map<String, dynamic> _decodeObject(String? value) {
  if (value == null || value.isEmpty) return const {};
  try {
    final decoded = jsonDecode(value);
    return decoded is Map<String, dynamic> ? decoded : const {};
  } on FormatException {
    return const {};
  }
}

Map<String, String> _decodeTags(String? value) {
  return _decodeObject(value).map(
    (key, dynamic item) => MapEntry(key, item.toString()),
  );
}
