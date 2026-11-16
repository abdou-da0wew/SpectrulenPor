import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_glass_app/l10n/app_localizations.dart';
import 'package:smart_glass_app/l10n/app_localizations_ar.dart';
import 'package:smart_glass_app/l10n/app_localizations_en.dart';
import 'package:smart_glass_app/models/recognition_state.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';
import 'package:smart_glass_app/services/wifi_udp_video_service.dart';
import 'package:smart_glass_app/widgets/glasses_setup_card.dart';

import '../support/glasses_fakes.dart';

Finder field(String key) => find.byKey(ValueKey(key));

Future<void> pumpCard(
  WidgetTester tester,
  RecognitionState state, {
  String locale = 'en',
  double width = 360,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: state,
    child: MaterialApp(
      locale: Locale(locale),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const Scaffold(
          body: Align(
        alignment: Alignment.topCenter,
        child: GlassesSetupCard(),
      )),
    ),
  ));
}

Future<void> enterField(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(field(key));
  await tester.pump();
  await tester.enterText(field(key), text);
  await tester.pump();
}

Future<void> tapControl(WidgetTester tester, String key) async {
  await tester.ensureVisible(field(key));
  await tester.pump();
  await tester.tap(field(key));
  await tester.pump();
}

void main() {
  testWidgets('SSID and password changes reactively enable only valid setup',
      (tester) async {
    final ble = FakeSetupBle();
    addTearDown(ble.service.dispose);
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    await pumpCard(tester, state);
    expect(tester.widget<FilledButton>(field('glasses-setup-start')).onPressed,
        isNull);
    await enterField(tester, 'glasses-ssid', 'Lab');
    expect(tester.widget<FilledButton>(field('glasses-setup-start')).onPressed,
        isNotNull);
    await enterField(tester, 'glasses-password', 'short');
    expect(tester.widget<FilledButton>(field('glasses-setup-start')).onPressed,
        isNull);
    await enterField(tester, 'glasses-password', 'password1');
    expect(tester.widget<FilledButton>(field('glasses-setup-start')).onPressed,
        isNotNull);
    final password = tester.widget<TextField>(field('glasses-password'));
    expect(password.obscureText, isTrue);
    expect(password.enableSuggestions, isFalse);
    expect(password.autocorrect, isFalse);
    expect(ble.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending setup disables fields and clears password immediately',
      (tester) async {
    final ble = FakeSetupBle();
    addTearDown(ble.service.dispose);
    final release = Completer<void>();
    ble.onWrite = (bytes) async {
      if (bytes.first == BluetoothCameraService.cmdBlePair) {
        await release.future;
        ble.feed('${BluetoothCameraService.pairedAck}\n');
      } else if (bytes.first == BluetoothCameraService.cmdWifiConfigPut) {
        ble.confirmProfile();
      } else if (bytes.first == BluetoothCameraService.cmdReboot) {
        ble.feed('${BluetoothCameraService.rebootAck}\n');
        ble.service.debugDisconnectSession();
      }
    };
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    await pumpCard(tester, state);
    await enterField(tester, 'glasses-ssid', 'Lab');
    await enterField(tester, 'glasses-password', 'password1');
    await tapControl(tester, 'glasses-setup-start');
    expect(state.setupStage, GlassesSetupStage.pairing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<TextField>(field('glasses-password')).controller!.text,
        isEmpty);
    expect(tester.widget<TextField>(field('glasses-ssid')).enabled, isFalse);
    expect(tester.widget<TextField>(field('glasses-ip')).enabled, isFalse);
    expect(tester.widget<FilledButton>(field('glasses-setup-start')).onPressed,
        isNull);
    expect(ble.writes, hasLength(1));
    release.complete();
    await tester.pumpAndSettle();
    expect(state.setupStage, GlassesSetupStage.awaitingIp);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text(AppLocalizationsEn().setupAwaitingIp), findsOneWidget);
    expect(state.prefs.getKeys().map(state.prefs.get),
        isNot(contains('password1')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Arabic timeout shows a localized safe failure and an explicit retry',
      (tester) async {
    final ble = FakeSetupBle(timeout: const Duration(milliseconds: 50));
    addTearDown(ble.service.dispose);
    ble.onWrite = (_) => ble.feed('\$CMD:paired_extra\n');
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    await pumpCard(tester, state, locale: 'ar');
    await enterField(tester, 'glasses-ssid', 'Lab');
    await enterField(tester, 'glasses-password', 'password1');
    await tapControl(tester, 'glasses-setup-start');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    final l = AppLocalizationsAr();
    expect(find.text(l.setupErrorAckTimeout), findsOneWidget);
    expect(find.text(AppLocalizationsEn().setupErrorAckTimeout), findsNothing);
    expect(state.configurationUncertain, isFalse);
    expect(tester.widget<FilledButton>(field('glasses-setup-start')).onPressed,
        isNotNull);
    expect(tester.widget<TextField>(field('glasses-password')).controller!.text,
        isEmpty);
    expect(Directionality.of(tester.element(field('glasses-ssid'))),
        TextDirection.rtl);
    expect(ble.writes, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'uncertain profile hides resubmission but leaves manual IP recovery',
      (tester) async {
    final ble = FakeSetupBle(timeout: const Duration(milliseconds: 50));
    addTearDown(ble.service.dispose);
    ble.onWrite = (bytes) {
      if (bytes.first == BluetoothCameraService.cmdBlePair) {
        ble.feed('${BluetoothCameraService.pairedAck}\n');
      } else if (bytes.first == BluetoothCameraService.cmdWifiConfigPut) {
        ble.feed('${BluetoothCameraService.provisionedAck}\n');
      }
    };
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    await pumpCard(tester, state);
    await enterField(tester, 'glasses-ssid', 'Lab');
    await tapControl(tester, 'glasses-setup-start');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.text(AppLocalizationsEn().setupRecoveryHint), findsOneWidget);
    expect(field('glasses-setup-start'), findsNothing);
    expect(field('glasses-password'), findsNothing);
    expect(field('glasses-ip'), findsOneWidget);
    expect(state.configurationUncertain, isTrue);
    expect(ble.writes.map((bytes) => bytes.first), [0x0A, 0x07]);
  });

  testWidgets(
      'manual IP needs decoded video; WiFi controls pause and disable BLE-only actions',
      (tester) async {
    final socket = FakeDatagramSocket();
    final udp = WifiUdpVideoService(
        socketFactory: () async => socket, frameDecoder: decodeFixtureJpeg);
    final ble = FakeSetupBle();
    ble.service.debugDisconnectSession();
    addTearDown(ble.service.dispose);
    final state = await setupState(ble: ble.service, udp: udp, prefs: const {
      'glasses_wifi_configured': true,
      'glasses_mac': FakeSetupBle.mac,
      'glasses_hostname': BluetoothCameraService.expectedHostname,
    });
    addTearDown(state.dispose);
    await pumpCard(tester, state);
    expect(tester.widget<FilledButton>(field('glasses-udp-start')).onPressed,
        isNull);
    await enterField(tester, 'glasses-ip', 'spectrulenpor-esp32.local');
    expect(tester.widget<FilledButton>(field('glasses-udp-start')).onPressed,
        isNull);
    await enterField(tester, 'glasses-ip', '192.0.2.10');
    expect(tester.widget<FilledButton>(field('glasses-udp-start')).onPressed,
        isNotNull);
    await tapControl(tester, 'glasses-udp-start');
    expect(state.setupStage, GlassesSetupStage.waitingForFrame);
    expect(state.wifiConnected, isFalse);
    expect(
        tester
            .widget<OutlinedButton>(field('glasses-video-single-frame'))
            .onPressed,
        isNull);
    for (final data in packetize(testJpeg())) {
      socket.feed(data);
    }
    await tester.pumpAndSettle();
    expect(state.wifiConnected, isTrue);
    expect(find.text(AppLocalizationsEn().wifiConnected), findsOneWidget);
    for (final key in [
      'glasses-ble-status',
      'glasses-ble-restart',
      'glasses-ble-standby'
    ]) {
      expect(tester.widget<OutlinedButton>(field(key)).onPressed, isNull);
    }
    expect(find.text(AppLocalizationsEn().wifiOnlyControlsUnavailable),
        findsOneWidget);
    await tapControl(tester, 'glasses-video-pause-resume');
    expect(find.text(AppLocalizationsEn().videoPaused), findsOneWidget);
    expect(udp.isStreaming, isFalse);
    expect(socket.closed, isFalse);
    await tapControl(tester, 'glasses-video-single-frame');
    expect(socket.sent.last.bytes, [0x02]);
    for (final data in packetize(testJpeg())) {
      socket.feed(data);
    }
    await tester.pumpAndSettle();
    expect(udp.isStreaming, isFalse);
    await tapControl(tester, 'glasses-video-stop');
    await tester.pumpAndSettle();
    expect(state.wifiConnected, isFalse);
    expect(socket.closed, isTrue);
    expect(ble.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow Arabic setup remains scrollable with enlarged text',
      (tester) async {
    final ble = FakeSetupBle();
    ble.service.debugDisconnectSession();
    addTearDown(ble.service.dispose);
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    await pumpCard(tester, state, locale: 'ar', width: 240, textScale: 1.6);
    expect(tester.getSize(find.byType(GlassesSetupCard)).height,
        lessThanOrEqualTo(232));
    expect(tester.takeException(), isNull);
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text(AppLocalizationsAr().wifiOnlyControlsUnavailable),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'removing the card while pairing never writes through disposed controllers',
      (tester) async {
    final ble = FakeSetupBle();
    addTearDown(ble.service.dispose);
    final release = Completer<void>();
    ble.onWrite = (bytes) async {
      await release.future;
      ble.feed('${BluetoothCameraService.pairedAck}\n');
    };
    final state = await setupState(ble: ble.service);
    await pumpCard(tester, state);
    await enterField(tester, 'glasses-ssid', 'Lab');
    await tapControl(tester, 'glasses-setup-start');
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    release.complete();
    await tester.pump();
    expect(ble.writes, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
