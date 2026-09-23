#ifndef FLUTTER_PLUGIN_FLUTTER_DRAG_OUT_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_DRAG_OUT_PLUGIN_H_

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <string>
#include <vector>

namespace flutter_drag_out {

// Starts native OLE drag sessions (DoDragDrop) carrying CF_HDROP so files can
// be dragged out of the Flutter app into Explorer and other applications.
//
// It never registers a drop target: in-app drags stay with Flutter's own
// `Draggable`, and drag-in stays with whatever the app already uses (e.g.
// desktop_drop's IDropTarget).
class FlutterDragOutPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  FlutterDragOutPlugin(
      flutter::PluginRegistrarWindows* registrar,
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel);

  virtual ~FlutterDragOutPlugin();

  // Disallow copy and assign.
  FlutterDragOutPlugin(const FlutterDragOutPlugin&) = delete;
  FlutterDragOutPlugin& operator=(const FlutterDragOutPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Window procedure of |message_window_|. The drag is started from a posted
  // message rather than from inside the method call handler, so the modal
  // OLE loop never runs nested in the engine's own message dispatch.
  static LRESULT CALLBACK MessageWindowProc(HWND hwnd, UINT message,
                                            WPARAM wparam, LPARAM lparam);

  // Runs the modal OLE drag loop for |pending_paths_|.
  void RunDrag();

  void NotifyDragEnded(bool dropped);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND message_window_ = nullptr;
  bool ole_initialized_ = false;
  bool drag_queued_ = false;
  std::vector<std::wstring> pending_paths_;
};

}  // namespace flutter_drag_out

#endif  // FLUTTER_PLUGIN_FLUTTER_DRAG_OUT_PLUGIN_H_
