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

/// How a drag session ended. Passed to `onEnded` exactly once per session
/// that started.
///
/// This is the moment the OS drag session ended, *not* the moment the target
/// finished reading the files: Finder and Explorer may copy asynchronously
/// after accepting the drop. Don't delete files right away in `onEnded`;
/// clean up temporary files later (e.g. on the next drag or at app exit).
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
  _Session(this.id, this.onEnded);

  final int id;
  final void Function(DragOutEnd end)? onEnded;
}

/// Entry point of the plugin. All members are static.
abstract final class FlutterDragOut {
  static const _channel = MethodChannel('flutter_drag_out');

  static bool _handlerInstalled = false;
  static bool _inProgress = false;
  static int _nextSessionId = 1;
  static _Session? _session;

  /// Whether this platform has a native implementation.
  ///
  /// On other platforms every call is a no-op that returns `false`.
  static bool get isSupported => !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// Whether this platform can drag items whose files are created only after
  /// the drop (file promises).
  ///
  /// Always `false` for now; reserved so apps can already branch on it.
  static bool get supportsPromises => false;

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
  /// exactly once, after [inProgress] has gone back to `false`.
  static Future<bool> startItems(List<DragOutItem> items, {void Function(DragOutEnd end)? onEnded}) async {
    if (!isSupported || _inProgress || items.isEmpty) return false;
    _installHandler();
    _inProgress = true;
    // Registered before the call: the end notification must find it even if
    // it were delivered before the call's own result.
    final session = _session = _Session(_nextSessionId++, onEnded);
    final arguments = {
      'session': session.id,
      'items': [
        for (final item in items)
          switch (item) {
            DragOutPath(:final path) => {'type': 'path', 'path': path},
          },
      ],
    };
    bool started;
    try {
      started = await _channel.invokeMethod<bool>('startDrag', arguments) ?? false;
    } on PlatformException {
      started = false;
    } on MissingPluginException {
      started = false;
    }
    if (!started && identical(_session, session)) {
      _session = null;
      _inProgress = false;
    }
    return started;
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
      if (call.method == 'dragEnded') _handleDragEnded(call.arguments);
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

  /// Resets internal state. For tests only.
  @visibleForTesting
  static void debugReset() {
    _inProgress = false;
    _handlerInstalled = false;
    _session = null;
    _nextSessionId = 1;
  }
}
