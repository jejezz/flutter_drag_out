import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_drag_out/flutter_drag_out.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_drag_out');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late bool nativeResult;

  setUp(() {
    FlutterDragOut.debugReset();
    calls = [];
    nativeResult = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return nativeResult;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> sendDragEnded() => messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(const MethodCall('dragEnded', true)),
    (_) {},
  );

  const viewSize = Size(800, 600);

  group('on macOS', () {
    test('does nothing while the pointer is inside the window', () {
      FlutterDragOut.maybeStartOnExit(
        const Offset(400, 300),
        viewSize: viewSize,
        paths: () => fail('paths must not be evaluated inside the window'),
      );
      expect(calls, isEmpty);
    });

    test('starts a drag with the paths once the pointer leaves', () async {
      FlutterDragOut.maybeStartOnExit(
        const Offset(-5, 300),
        viewSize: viewSize,
        paths: () => ['/tmp/a.txt', '/tmp/dir'],
      );
      await pumpEventQueue();
      expect(calls.single.method, 'startDrag');
      expect(calls.single.arguments, ['/tmp/a.txt', '/tmp/dir']);
      expect(FlutterDragOut.inProgress, isTrue);
    });

    test('starts only once per drag until the session ends', () async {
      for (var i = 0; i < 3; i++) {
        FlutterDragOut.maybeStartOnExit(
          Offset(900.0 + i, 300),
          viewSize: viewSize,
          paths: () => ['/tmp/a.txt'],
        );
      }
      await pumpEventQueue();
      expect(calls, hasLength(1));

      await sendDragEnded();
      expect(FlutterDragOut.inProgress, isFalse);

      FlutterDragOut.maybeStartOnExit(
        const Offset(900, 300),
        viewSize: viewSize,
        paths: () => ['/tmp/b.txt'],
      );
      await pumpEventQueue();
      expect(calls, hasLength(2));
    });

    test('keeps the drag in the app when paths is null or empty', () async {
      FlutterDragOut.maybeStartOnExit(
        const Offset(-1, -1),
        viewSize: viewSize,
        paths: () => null,
      );
      FlutterDragOut.maybeStartOnExit(
        const Offset(-1, -1),
        viewSize: viewSize,
        paths: () => [],
      );
      await pumpEventQueue();
      expect(calls, isEmpty);
    });

    test('clears inProgress when the native side refuses to start', () async {
      nativeResult = false;
      expect(await FlutterDragOut.start(['/tmp/a.txt']), isFalse);
      expect(FlutterDragOut.inProgress, isFalse);
    });
  }, skip: !Platform.isMacOS);
}
