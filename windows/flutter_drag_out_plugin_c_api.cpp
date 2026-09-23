#include "include/flutter_drag_out/flutter_drag_out_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_drag_out_plugin.h"

void FlutterDragOutPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_drag_out::FlutterDragOutPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
