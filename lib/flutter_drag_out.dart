/// Drag files out of a Flutter desktop app into Finder/Explorer.
///
/// Keep using Flutter's own `Draggable` for in-app drags. When the pointer
/// leaves the window during such a drag, [FlutterDragOut.maybeStartOnExit]
/// hands the drag over to a real OS drag session carrying the given file
/// paths, so the user can drop them into another application.
///
/// The plugin only *starts* drag sessions. It never registers a drop target,
/// so it coexists with drag-in packages such as `desktop_drop` and with
/// Flutter's `Draggable`/`DragTarget`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One item of a drag session.
sealed class DragOutItem {
  /// A file or directory that already exists at the absolute local [path].
  const factory DragOutItem.path(String path) = DragOutPath;

  /// A file or directory that [write] creates only after the drop (a file
  /// promise), so nothing has to exist on disk while the user drags.
  ///
  /// [name] is the name it gets at the destination (no path separators).
  /// Only available where [FlutterDragOut.supportsPromises] is `true`.
  const factory DragOutItem.promise({
    required String name,
    bool isDirectory,
    required Future<void> Function(DragOutWriteRequest request) write,
  }) = DragOutPromise;
}

/// A [DragOutItem] for a file or directory that already exists on disk.
final class DragOutPath implements DragOutItem {
  /// Creates an item for the absolute local [path].
  const DragOutPath(this.path);

  /// Absolute local path of the file or directory.
  final String path;

  @override
  bool operator ==(Object other) => other is DragOutPath && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'DragOutItem.path($path)';
}

/// A [DragOutItem] whose file or directory is created by [write] after the
/// drop.
final class DragOutPromise implements DragOutItem {
  /// Creates a promised item named [name].
  const DragOutPromise({required this.name, this.isDirectory = false, required this.write});

  /// Name of the file or directory at the destination.
  final String name;

  /// Whether [write] creates a directory rather than a file.
  final bool isDirectory;

  /// Creates the file or directory at [DragOutWriteRequest.targetPath].
  ///
  /// Throw to report failure; the target application is told the item could
  /// not be delivered.
  final Future<void> Function(DragOutWriteRequest request) write;

  @override
  String toString() => 'DragOutItem.promise($name${isDirectory ? '/' : ''})';
}

/// A request to fulfil one [DragOutPromise], passed to its `write`.
final class DragOutWriteRequest {
  DragOutWriteRequest._(this.targetPath, this.isFinalDestination, this._session);

  /// Create the promised file (or directory) at exactly this path. Its parent
  /// directory already exists.
  final String targetPath;

  /// `true` if [targetPath] is where the user dropped (macOS): an existing
  /// entry there is the user's own file, so handle a name clash carefully.
  /// `false` if it is a staging location the OS copies from afterwards.
  final bool isFinalDestination;

  final _Session _session;

  /// Whether the user cancelled the drop while it was being written. Check
  /// it between chunks of a long write and stop (e.g. by throwing).
  bool get isCancelled => _session.cancelled;

  @override
  String toString() => 'DragOutWriteRequest($targetPath, final: $isFinalDestination)';
}

/// How a drag session ended. Passed to `onEnded` exactly once per session
/// that started.
///
/// This is the moment the OS drag session ended, *not* the moment the target
/// finished reading the files: Finder and Explorer may copy asynchronously
/// after accepting the drop, and promised items may still be written after
/// it. Don't delete files right away in `onEnded`; clean up temporary files
/// later (e.g. on the next drag or at app exit).
final class DragOutEnd {
  /// Creates a session result.
  const DragOutEnd({required this.dropped});

  /// Whether another application accepted the drop. `false` if the user
  /// pressed Escape, released where nothing accepts files, or dropped back
  /// onto this app's window.
  final bool dropped;

  @override
  bool operator ==(Object other) => other is DragOutEnd && other.dropped == dropped;

  @override
  int get hashCode => dropped.hashCode;

  @override
  String toString() => 'DragOutEnd(dropped: $dropped)';
}

class _Session {
  _Session(this.id, this.onEnded, this.promises);

  final int id;
  final void Function(DragOutEnd end)? onEnded;

  /// Promised items by the ID sent to the native side; removed once their
  /// write starts.
  final Map<int, DragOutPromise> promises;

  /// Writes that started and have not finished yet.
  int writing = 0;
  bool cancelled = false;

  /// Whether nothing is left to write or being written.
  bool get isSettled => promises.isEmpty && writing == 0;
}

/// Entry point of the plugin. All members are static.
abstract final class FlutterDragOut {
  static const _channel = MethodChannel('flutter_drag_out');

  static bool _handlerInstalled = false;
  static bool _inProgress = false;
  static int _nextSessionId = 1;

  /// The session whose OS drag is running.
  static _Session? _session;

  /// Sessions that still have promises to write or being written, by ID. On
  /// macOS the target asks for them after the drag session ended.
  static final _sessionsWithPromises = <int, _Session>{};

  /// Whether this platform has a native implementation.
  ///
  /// On other platforms every call is a no-op that returns `false`.
  static bool get isSupported => !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// Whether this platform supports [DragOutItem.promise] (macOS for now).
  ///
  /// Where it is `false`, [startItems] refuses items with promises, so fall
  /// back to paths prepared in advance.
  static bool get supportsPromises => !kIsWeb && Platform.isMacOS;

  /// Whether a drag session started by this plugin is still running.
  ///
  /// Useful to ignore the app's own files if the user drags them back into
  /// the window and a drag-in handler (e.g. `desktop_drop`) reports them.
  static bool get inProgress => _inProgress;

  /// Starts an OS drag session carrying [paths] (absolute local paths of files
  /// and/or directories).
  ///
  /// Same as [startItems] with a [DragOutItem.path] per path and no
  /// `onEnded` callback.
  static Future<bool> start(List<String> paths) => startItems([for (final path in paths) DragOutItem.path(path)]);

  /// Starts an OS drag session carrying [items].
  ///
  /// Must be called while the left mouse button is held down, i.e. from a
  /// drag update. Only the copy operation is offered to other applications,
  /// and drops back into this app are rejected. As soon as the session
  /// starts, the plugin sends Flutter a synthetic mouse-up so the Flutter
  /// drag that triggered it ends (it is cancelled, since the pointer is
  /// outside the window).
  ///
  /// Returns `true` if the session started. Only then is [onEnded] called,
  /// exactly once, after [inProgress] has gone back to `false`. Returns
  /// `false` without starting if [items] contains a [DragOutItem.promise]
  /// and [supportsPromises] is `false`.
  ///
  /// Throws an [ArgumentError] if a promise's name is empty, `.`, `..` or
  /// contains a path separator.
  static Future<bool> startItems(List<DragOutItem> items, {void Function(DragOutEnd end)? onEnded}) async {
    for (final item in items) {
      if (item is DragOutPromise) _checkPromiseName(item.name);
    }
    if (!isSupported || _inProgress || items.isEmpty) return false;
    final hasPromises = items.any((item) => item is DragOutPromise);
    if (hasPromises && !supportsPromises) return false;
    _installHandler();
    _inProgress = true;

    final promises = <int, DragOutPromise>{};
    final wireItems = <Map<String, Object>>[];
    for (final item in items) {
      switch (item) {
        case DragOutPath(:final path):
          wireItems.add({'type': 'path', 'path': path});
        case DragOutPromise(:final name, :final isDirectory):
          final id = promises.length;
          promises[id] = item;
          wireItems.add({'type': 'promise', 'id': id, 'name': name, 'directory': isDirectory});
      }
    }
    // Registered before the call: the end notification must find it even if
    // it were delivered before the call's own result.
    final session = _session = _Session(_nextSessionId++, onEnded, promises);
    if (hasPromises) _sessionsWithPromises[session.id] = session;

    bool started;
    try {
      started = await _channel.invokeMethod<bool>('startDrag', {'session': session.id, 'items': wireItems}) ?? false;
    } on PlatformException {
      started = false;
    } on MissingPluginException {
      started = false;
    }
    if (!started) {
      _sessionsWithPromises.remove(session.id);
      if (identical(_session, session)) {
        _session = null;
        _inProgress = false;
      }
    }
    return started;
  }

  static void _checkPromiseName(String name) {
    if (name.isEmpty || name == '.' || name == '..' || name.contains('/') || name.contains(r'\')) {
      throw ArgumentError.value(name, 'name', 'must be a plain file name');
    }
  }

  /// Call from `Draggable.onDragUpdate`. Starts a native drag session once
  /// [globalPosition] leaves the window (`Offset.zero & viewSize`, where
  /// [viewSize] is typically `MediaQuery.sizeOf(context)`).
  ///
  /// Pass exactly one of [paths] and [items]. It is only evaluated when the
  /// pointer is outside; return `null` or an empty list to keep the drag
  /// inside the app (for example when the dragged items have no local path).
  ///
  /// [onEnded] is called once when the session started by this call ends.
  ///
  /// ```dart
  /// Draggable<MyPayload>(
  ///   onDragUpdate: (details) => FlutterDragOut.maybeStartOnExit(
  ///     details.globalPosition,
  ///     viewSize: MediaQuery.sizeOf(context),
  ///     paths: () => selectedFiles.map((f) => f.path).toList(),
  ///   ),
  ///   ...
  /// )
  /// ```
  static void maybeStartOnExit(
    Offset globalPosition, {
    required Size viewSize,
    List<String>? Function()? paths,
    List<DragOutItem>? Function()? items,
    void Function(DragOutEnd end)? onEnded,
  }) {
    assert((paths == null) != (items == null), 'Pass exactly one of paths and items.');
    if (!isSupported || _inProgress) return;
    if ((Offset.zero & viewSize).contains(globalPosition)) return;
    final list = items != null ? items() : paths?.call()?.map(DragOutItem.path).toList();
    if (list == null || list.isEmpty) return;
    startItems(list, onEnded: onEnded);
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'dragEnded':
          _handleDragEnded(call.arguments);
        case 'writePromise':
          await _handleWritePromise(call.arguments);
        case 'cancelPromises':
          _handleCancelPromises(call.arguments);
      }
      return null;
    });
  }

  static void _handleDragEnded(Object? arguments) {
    // Before 0.4.0 the native side sent a bare `dropped` bool.
    final (Object? sessionId, bool dropped) = switch (arguments) {
      {'session': final Object? id, 'dropped': final bool dropped} => (id, dropped),
      final bool dropped => (null, dropped),
      _ => (null, false),
    };
    final session = _session;
    // A late message from an earlier session must not end the current one.
    if (session == null || (sessionId != null && sessionId != session.id)) return;
    _session = null;
    _inProgress = false;
    // Nothing will be written for a session that was not dropped.
    if (!dropped) session.promises.clear();
    if (session.isSettled) _sessionsWithPromises.remove(session.id);
    final onEnded = session.onEnded;
    if (onEnded == null) return;
    try {
      onEnded(DragOutEnd(dropped: dropped));
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'flutter_drag_out',
          context: ErrorDescription('while calling onEnded'),
        ),
      );
    }
  }

  static Future<void> _handleWritePromise(Object? arguments) async {
    if (arguments case {
      'session': final int sessionId,
      'id': final int id,
      'targetPath': final String targetPath,
      'final': final bool isFinal,
    }) {
      final session = _sessionsWithPromises[sessionId];
      final promise = session?.promises.remove(id);
      if (session == null || promise == null) {
        throw PlatformException(code: 'unknown_promise', message: 'No pending promise $id in session $sessionId');
      }
      session.writing++;
      try {
        await promise.write(DragOutWriteRequest._(targetPath, isFinal, session));
      } catch (error) {
        // Expected failures (e.g. the app gave up after isCancelled) are the
        // app's to report; the target application is told it failed.
        throw PlatformException(code: 'write_failed', message: '$error');
      } finally {
        session.writing--;
        if (session.isSettled) _sessionsWithPromises.remove(sessionId);
      }
      return;
    }
    throw PlatformException(code: 'bad_args', message: 'Expected {session, id, targetPath, final}');
  }

  static void _handleCancelPromises(Object? arguments) {
    if (arguments case {'session': final int sessionId}) {
      _sessionsWithPromises[sessionId]?.cancelled = true;
    }
  }

  /// Resets internal state. For tests only.
  @visibleForTesting
  static void debugReset() {
    _inProgress = false;
    _handlerInstalled = false;
    _session = null;
    _sessionsWithPromises.clear();
    _nextSessionId = 1;
  }
}
