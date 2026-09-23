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
