import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

  Future<void> sendDragEndedFor(int session, {required bool dropped}) => messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall('dragEnded', {'session': session, 'dropped': dropped})),
    (_) {},
  );

  const viewSize = Size(800, 600);

  group('on a supported platform', () {
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
      expect(calls.single.arguments, {
        'session': 1,
        'items': [
          {'type': 'path', 'path': '/tmp/a.txt'},
          {'type': 'path', 'path': '/tmp/dir'},
        ],
      });
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

    test('keeps the drag in the app when a remote item is mixed in', () async {
      // The daylight-commander pattern: only all-local selections leave.
      final locations = [Uri.file('/tmp/a.txt'), Uri.parse('sftp://host/b.txt')];
      FlutterDragOut.maybeStartOnExit(
        const Offset(-5, 300),
        viewSize: viewSize,
        paths: () => locations.any((l) => l.scheme != 'file') ? null : [for (final l in locations) l.toFilePath()],
      );
      await pumpEventQueue();
      expect(calls, isEmpty);
      expect(FlutterDragOut.inProgress, isFalse);
    });

    test('starts a drag with items and numbers sessions', () async {
      expect(await FlutterDragOut.startItems([const DragOutItem.path('/tmp/a.txt')]), isTrue);
      await sendDragEndedFor(1, dropped: true);
      FlutterDragOut.maybeStartOnExit(
        const Offset(-5, 300),
        viewSize: viewSize,
        items: () => [const DragOutItem.path('/tmp/b.txt')],
      );
      await pumpEventQueue();
      expect(calls, hasLength(2));
      expect(calls.last.arguments, {
        'session': 2,
        'items': [
          {'type': 'path', 'path': '/tmp/b.txt'},
        ],
      });
    });

    test('calls onEnded once with the result, after inProgress clears', () async {
      final ends = <DragOutEnd>[];
      bool? inProgressDuringCallback;
      await FlutterDragOut.startItems(
        [const DragOutItem.path('/tmp/a.txt')],
        onEnded: (end) {
          inProgressDuringCallback = FlutterDragOut.inProgress;
          ends.add(end);
        },
      );
      expect(ends, isEmpty);

      await sendDragEndedFor(1, dropped: true);
      await sendDragEndedFor(1, dropped: false); // Duplicate: ignored.
      expect(ends, [const DragOutEnd(dropped: true)]);
      expect(inProgressDuringCallback, isFalse);
    });

    test('passes onEnded through maybeStartOnExit', () async {
      final ends = <DragOutEnd>[];
      FlutterDragOut.maybeStartOnExit(
        const Offset(-5, 300),
        viewSize: viewSize,
        paths: () => ['/tmp/a.txt'],
        onEnded: ends.add,
      );
      await pumpEventQueue();
      await sendDragEndedFor(1, dropped: false);
      expect(ends, [const DragOutEnd(dropped: false)]);
    });

    test('accepts the pre-0.4.0 bare bool dragEnded', () async {
      final ends = <DragOutEnd>[];
      await FlutterDragOut.startItems([const DragOutItem.path('/tmp/a.txt')], onEnded: ends.add);
      await sendDragEnded();
      expect(ends, [const DragOutEnd(dropped: true)]);
      expect(FlutterDragOut.inProgress, isFalse);
    });

    test('ignores dragEnded from another session', () async {
      final ends = <DragOutEnd>[];
      await FlutterDragOut.startItems([const DragOutItem.path('/tmp/a.txt')], onEnded: ends.add);
      await sendDragEndedFor(7, dropped: true);
      expect(ends, isEmpty);
      expect(FlutterDragOut.inProgress, isTrue);
    });

    test('does not call onEnded when the session did not start', () async {
      nativeResult = false;
      final ends = <DragOutEnd>[];
      expect(await FlutterDragOut.startItems([const DragOutItem.path('/tmp/a.txt')], onEnded: ends.add), isFalse);
      await sendDragEndedFor(1, dropped: false);
      expect(ends, isEmpty);
    });

    test('reports a throwing onEnded without breaking the session state', () async {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);

      await FlutterDragOut.startItems([const DragOutItem.path('/tmp/a.txt')], onEnded: (_) => throw StateError('boom'));
      await sendDragEndedFor(1, dropped: true);
      expect(errors.single.exception, isA<StateError>());
      expect(FlutterDragOut.inProgress, isFalse);
    });

    test('supports promises on macOS only', () {
      expect(FlutterDragOut.supportsPromises, Platform.isMacOS);
    });

    Future<Object?> sendWritePromise(int session, int id, String targetPath) async {
      ByteData? reply;
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('writePromise', {'session': session, 'id': id, 'targetPath': targetPath, 'final': true}),
        ),
        (data) => reply = data,
      );
      try {
        return channel.codec.decodeEnvelope(reply!);
      } on PlatformException catch (e) {
        return e;
      }
    }

    test('rejects promise names that are not plain file names', () {
      for (final name in ['', '.', '..', 'a/b', r'a\b']) {
        expect(
          () => FlutterDragOut.startItems([DragOutItem.promise(name: name, write: (_) async {})]),
          throwsArgumentError,
          reason: name,
        );
      }
      expect(calls, isEmpty);
    });

    group('promises', () {
      test('are refused where unsupported', () async {
        final started = await FlutterDragOut.startItems([DragOutItem.promise(name: 'a.txt', write: (_) async {})]);
        expect(started, isFalse);
        expect(calls, isEmpty);
        expect(FlutterDragOut.inProgress, isFalse);
      }, skip: Platform.isMacOS);

      test('are sent with IDs next to paths', () async {
        await FlutterDragOut.startItems([
          const DragOutItem.path('/tmp/a.txt'),
          DragOutItem.promise(name: 'b.txt', write: (_) async {}),
          DragOutItem.promise(name: 'dir', isDirectory: true, write: (_) async {}),
        ]);
        expect(calls.single.arguments, {
          'session': 1,
          'items': [
            {'type': 'path', 'path': '/tmp/a.txt'},
            {'type': 'promise', 'id': 0, 'name': 'b.txt', 'directory': false},
            {'type': 'promise', 'id': 1, 'name': 'dir', 'directory': true},
          ],
        });
      }, skip: !Platform.isMacOS);

      test('are written on request, also after the session ended', () async {
        final requests = <DragOutWriteRequest>[];
        await FlutterDragOut.startItems([
          DragOutItem.promise(name: 'a.txt', write: (r) async => requests.add(r)),
          DragOutItem.promise(name: 'b.txt', write: (r) async => requests.add(r)),
        ]);
        // On macOS the target asks for the files after the drop ended the session.
        await sendDragEndedFor(1, dropped: true);
        expect(FlutterDragOut.inProgress, isFalse);

        expect(await sendWritePromise(1, 1, '/dest/b.txt'), isNull);
        expect(await sendWritePromise(1, 0, '/dest/a.txt'), isNull);
        expect([for (final r in requests) r.targetPath], ['/dest/b.txt', '/dest/a.txt']);
        expect(requests.first.isFinalDestination, isTrue);
        expect(requests.first.isCancelled, isFalse);
      }, skip: !Platform.isMacOS);

      test('report a failed write back to the native side', () async {
        await FlutterDragOut.startItems([
          DragOutItem.promise(name: 'a.txt', write: (_) async => throw const FileSystemException('disk full')),
        ]);
        final reply = await sendWritePromise(1, 0, '/dest/a.txt');
        expect(reply, isA<PlatformException>().having((e) => e.code, 'code', 'write_failed'));
      }, skip: !Platform.isMacOS);

      test('are written at most once, and not after an unaccepted drop', () async {
        var writes = 0;
        await FlutterDragOut.startItems([DragOutItem.promise(name: 'a.txt', write: (_) async => writes++)]);
        expect(await sendWritePromise(1, 0, '/dest/a.txt'), isNull);
        expect(await sendWritePromise(1, 0, '/dest/a.txt'), isA<PlatformException>());
        expect(writes, 1);

        await sendDragEndedFor(1, dropped: true);
        await FlutterDragOut.startItems([DragOutItem.promise(name: 'b.txt', write: (_) async => writes++)]);
        await sendDragEndedFor(2, dropped: false);
        expect(
          await sendWritePromise(2, 0, '/dest/b.txt'),
          isA<PlatformException>().having((e) => e.code, 'code', 'unknown_promise'),
        );
        expect(writes, 1);
      }, skip: !Platform.isMacOS);

      test('see cancellation through isCancelled', () async {
        DragOutWriteRequest? request;
        final release = Completer<void>();
        await FlutterDragOut.startItems([
          DragOutItem.promise(
            name: 'a.txt',
            write: (r) async {
              request = r;
              await release.future;
            },
          ),
        ]);
        final reply = sendWritePromise(1, 0, '/dest/a.txt');
        await pumpEventQueue();
        expect(request!.isCancelled, isFalse);

        await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('cancelPromises', {'session': 1})),
          (_) {},
        );
        expect(request!.isCancelled, isTrue);
        release.complete();
        expect(await reply, isNull);
      }, skip: !Platform.isMacOS);
    });
  }, skip: !(Platform.isMacOS || Platform.isWindows || Platform.isLinux));
}
