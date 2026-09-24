## 0.4.0

* `onEnded` callback on `maybeStartOnExit` and the new `startItems`: called
  once per started session with `DragOutEnd(dropped:)`, after `inProgress`
  has gone back to `false`. It marks the end of the OS drag session, not the
  end of the target's copy, so don't delete the dragged files right away.
* `DragOutItem.path` and `FlutterDragOut.startItems(items, onEnded:)`;
  `maybeStartOnExit` takes `items:` as an alternative to `paths:`.
* `FlutterDragOut.supportsPromises` (always `false` for now), reserved for
  file promises (files created after the drop), which later versions add.
* Fully backwards compatible: `paths:`, `start`, `inProgress` and
  `isSupported` keep their signatures and behaviour. Internally the method
  channel now carries a session ID, so a late end notification can't end a
  newer session.

## 0.3.0

* Linux implementation (GTK 3): `gtk_drag_begin_with_coordinates` with
  `text/uri-list` (files and folders), copy-only, no data for drops back into
  the app's own window, themed file icon as the drag icon, synthesized button
  release so the triggering Flutter drag ends cleanly. Works on X11 and
  Wayland (the drag reuses the latest motion event, whose serial Wayland
  requires).
* CI builds the example on Linux too.

## 0.2.0

* Windows implementation: OLE `DoDragDrop` with `CF_HDROP` (files and
  folders), copy-only, drops back onto the app's own window rejected, shell
  icon as the drag image, synthesized `WM_LBUTTONUP` so the triggering Flutter
  drag ends cleanly.
* CI builds the example on macOS and Windows.

## 0.1.0

* Initial release: macOS implementation.
* `FlutterDragOut.maybeStartOnExit` hands a Flutter `Draggable` over to a
  native `NSDraggingSession` once the pointer leaves the window.
* Files and directories, single or multiple. Copy-only outside the app; drops
  back into the app are rejected.
* Synthesizes the missing mouse-up so the triggering Flutter drag ends cleanly.
