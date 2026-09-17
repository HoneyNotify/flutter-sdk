# HoneyNotify Flutter SDK

The Flutter SDK registers APNs tokens on iOS and FCM tokens on Android, maintains HoneyNotify device identity through token changes, parses notification data, and reports lifecycle or custom events.

## Requirements

- Flutter 3.19 or later
- iOS 15 or later, or Android API 26 or later
- `firebase_core` configured for each target application
- Native APNs and Firebase Cloud Messaging setup
- A restricted HoneyNotify public client key (`ps_public_...`)

## Install

```yaml
dependencies:
  firebase_core: ^4.0.0
  honeynotify:
    git:
      url: https://github.com/HoneyNotify/flutter-sdk.git
```

Run `flutterfire configure`, initialise Firebase before creating the SDK, enable Push Notifications and Remote notifications for iOS, and follow Firebase's Android notification setup.

## Register

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:honeynotify/honeynotify.dart';

await Firebase.initializeApp();

final honeyNotify = HoneyNotify(
  clientKey: 'ps_public_your_key',
);

final deviceId = await honeyNotify.requestPermissionAndRegister(
  options: HoneyNotifyRegistrationOptions(
    externalUserId: account?.id,
    identityToken: tokenFromYourBackend,
    tags: {'plan': account?.plan ?? 'visitor'},
  ),
);

final tokenRefresh = honeyNotify.startTokenRefreshListener(
  identityTokenProvider: (_) => fetchIdentityTokenFromYourBackend(),
  onError: (error, stackTrace) => logPushError(error, stackTrace),
);
```

Cancel `tokenRefresh` when the application-owned integration is disposed. On iOS, the SDK deliberately registers the APNs token returned by Firebase rather than treating the Firebase transport token as an APNs destination. If verified identity is required, its provider must obtain a fresh short-lived token from your authenticated backend; never generate or permanently store the signing token in Dart.

## Receive and open

```dart
FirebaseMessaging.onMessage.listen((message) async {
  await honeyNotify.trackReceived(message.data);
  final notification = honeyNotify.notificationFromRemoteMessage(message);
  // Render or route notification.clickUrl in your app.
});

FirebaseMessaging.onMessageOpenedApp.listen((message) {
  honeyNotify.trackOpened(message.data);
});
```

Background handlers must be top-level functions. Initialise Firebase there before using Firebase services, and avoid reporting the same receipt from more than one callback.

Use `identify(externalUserId, options: ...)` after login, `track(name, ...)` for lifecycle or custom events, and `logout()` before clearing the application session when the device should stop receiving notifications for that user.

Critical Alerts on iOS still require Apple's entitlement and explicit permission. Android notification importance remains under the user's channel settings. Never include a notification-send key in the application.

## Test

```bash
flutter test
```
