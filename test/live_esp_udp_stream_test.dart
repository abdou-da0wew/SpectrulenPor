import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/services/wifi_udp_video_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real ESP32 UDP V2 stream and runtime controls',
    () async {
      final ip = Platform.environment['ESP32_TEST_IP'];
      if (ip == null || ip.isEmpty) {
        markTestSkipped('Set ESP32_TEST_IP to run against the physical board.');
        return;
      }
      final address = WifiUdpVideoService.parsePeerAddress(ip);
      expect(address, isNotNull);

      final service = WifiUdpVideoService(
        readinessTimeout: const Duration(seconds: 15),
        stalledTimeout: const Duration(seconds: 5),
      );
      addTearDown(service.dispose);

      await service.connect(espIp: address!);
      expect(service.isConnected, isTrue);
      expect(service.isStreaming, isFalse);

      final status = await service.requestStatus();
      expect(status, contains('wifi=connected'));
      expect(status, contains('ip='));

      await service.sendCommandAndWait(
        WifiUdpVideoService.cmdFlashOn,
        acknowledgment: r'$CMD:flash_on',
      );
      await service.sendCommandAndWait(
        WifiUdpVideoService.cmdFlashOff,
        acknowledgment: r'$CMD:flash_off',
      );

      final firstFrameFuture = service.frameStream.first;
      final firstStart = Stopwatch()..start();
      await service.start(espIp: address);
      final firstFrame = await firstFrameFuture.timeout(
        const Duration(seconds: 5),
      );
      expect(firstFrame.jpegBytes, isNotEmpty);
      expect(firstFrame.width, greaterThan(0));
      expect(firstFrame.height, greaterThan(0));

      final streamFrames = <({int bytes, int width, int height})>[
        (
          bytes: firstFrame.jpegBytes.length,
          width: firstFrame.width,
          height: firstFrame.height,
        ),
      ];
      final intervals = <int>[];
      var previous = firstStart.elapsedMilliseconds;
      for (var index = 0; index < 4; index++) {
        final frame = await service.frameStream.first.timeout(
          const Duration(seconds: 5),
        );
        final elapsed = firstStart.elapsedMilliseconds;
        intervals.add(elapsed - previous);
        previous = elapsed;
        streamFrames.add((
          bytes: frame.jpegBytes.length,
          width: frame.width,
          height: frame.height,
        ));
      }

      expect(service.isReady, isTrue);
      expect(service.isStreaming, isTrue);

      await service.pause();
      expect(service.isConnected, isTrue);
      expect(service.isStreaming, isFalse);

      final singleFrameFuture = service.frameStream.first;
      await service.sendCommandAndWait(
        WifiUdpVideoService.cmdSingleFrame,
        acknowledgment: r'$CMD:single_frame',
      );
      final singleFrame = await singleFrameFuture.timeout(
        const Duration(seconds: 5),
      );
      expect(singleFrame.jpegBytes, isNotEmpty);
      expect(service.isStreaming, isFalse);

      final resumedFrameFuture = service.frameStream.first;
      await service.start(espIp: address);
      final resumedFrame = await resumedFrameFuture.timeout(
        const Duration(seconds: 5),
      );
      expect(resumedFrame.jpegBytes, isNotEmpty);
      expect(service.isStreaming, isTrue);

      // Exercise the production receiver continuously, not just for a handful
      // of frames. This catches stalls, decode failures and sustained send or
      // reassembly problems on the real AP path.
      final soakClock = Stopwatch()..start();
      final soakFrames = <({int bytes, int width, int height, int atMs})>[];
      final soakSubscription = service.frameStream.listen((frame) {
        soakFrames.add((
          bytes: frame.jpegBytes.length,
          width: frame.width,
          height: frame.height,
          atMs: soakClock.elapsedMilliseconds,
        ));
      });
      await Future<void>.delayed(const Duration(seconds: 60));
      await service.pause();
      soakClock.stop();
      await soakSubscription.cancel();

      expect(soakFrames.length, greaterThanOrEqualTo(20));
      expect(soakFrames.every((frame) => frame.bytes > 1000), isTrue);
      expect(soakFrames.every((frame) => frame.width > 0 && frame.height > 0),
          isTrue);
      var maxGapMs = 0;
      for (var index = 1; index < soakFrames.length; index++) {
        final gap = soakFrames[index].atMs - soakFrames[index - 1].atMs;
        if (gap > maxGapMs) maxGapMs = gap;
      }
      expect(maxGapMs, lessThan(5000));
      expect(service.isConnected, isTrue);
      expect(service.isStreaming, isFalse);

      final finalStatus = await service.requestStatus();
      expect(finalStatus, contains('wifi=connected'));
      expect(service.isConnected, isTrue);

      // Recreate the UDP socket and peer registration, then prove the camera
      // can start again without rebooting the ESP32.
      await service.disconnect();
      expect(service.isActive, isFalse);
      await service.connect(espIp: address);
      expect(service.isConnected, isTrue);
      expect(await service.requestStatus(), contains('wifi=connected'));
      final reconnectFrameFuture = service.frameStream.first;
      await service.start(espIp: address);
      final reconnectFrame = await reconnectFrameFuture.timeout(
        const Duration(seconds: 5),
      );
      expect(reconnectFrame.jpegBytes, isNotEmpty);
      expect(service.isReady, isTrue);
      await service.pause();

      final totalBytes = soakFrames.fold<int>(
        0,
        (total, frame) => total + frame.bytes,
      );
      final seconds = soakClock.elapsedMilliseconds / 1000;
      final fps = soakFrames.length / seconds;
      final kibPerSecond = totalBytes / 1024 / seconds;

      // Keep the output useful for serial/log correlation without exposing
      // network credentials or image contents.
      // ignore: avoid_print
      print(
        'REAL_ESP_UDP_V2_OK ip=$ip '
        'frames=${streamFrames.length + 3 + soakFrames.length} '
        'soak_frames=${soakFrames.length} '
        'fps=${fps.toStringAsFixed(2)} '
        'KiBps=${kibPerSecond.toStringAsFixed(1)} '
        'max_gap_ms=$maxGapMs '
        'first=${firstFrame.width}x${firstFrame.height}/${firstFrame.jpegBytes.length} '
        'single=${singleFrame.width}x${singleFrame.height}/${singleFrame.jpegBytes.length} '
        'resumed=${resumedFrame.width}x${resumedFrame.height}/${resumedFrame.jpegBytes.length} '
        'reconnect=${reconnectFrame.width}x${reconnectFrame.height}/${reconnectFrame.jpegBytes.length} '
        'intervals_ms=$intervals',
      );

      await service.disconnect();
      expect(service.isActive, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 150)),
  );
}
