#include "flutter_drag_out_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace flutter_drag_out {

namespace {

constexpr wchar_t kMessageWindowClass[] = L"FlutterDragOutMessageWindow";
constexpr UINT kStartDragMessage = WM_APP + 0x0D0;

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int length = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), length);
  return wide;
}

// The OLE drag loop's feedback: drop on button release, cancel on Escape.
class DropSource : public IDropSource {
 public:
  // |own_window| is this app's top-level window. Drops back onto it are
  // rejected: in-app moves belong to the app's own Flutter drag.
  explicit DropSource(HWND own_window) : own_window_(own_window) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** object) override {
    if (riid == IID_IUnknown || riid == IID_IDropSource) {
      *object = static_cast<IDropSource*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return ::InterlockedIncrement(&ref_count_);
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = ::InterlockedDecrement(&ref_count_);
    if (count == 0) delete this;
    return count;
  }

  HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape_pressed,
                                              DWORD key_state) override {
    if (escape_pressed) return DRAGDROP_S_CANCEL;
    if (!(key_state & MK_LBUTTON)) {
      return IsOverOwnWindow() ? DRAGDROP_S_CANCEL : DRAGDROP_S_DROP;
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD effect) override {
    return DRAGDROP_S_USEDEFAULTCURSORS;
  }

 private:
  bool IsOverOwnWindow() const {
    if (!own_window_) return false;
    POINT point;
    if (!::GetCursorPos(&point)) return false;
    const HWND target = ::WindowFromPoint(point);
    return target && ::GetAncestor(target, GA_ROOT) == own_window_;
  }

  LONG ref_count_ = 1;
  HWND own_window_;
};

// CF_HDROP payload: a DROPFILES header followed by a double-null-terminated
// list of wide paths.
HGLOBAL CreateHDrop(const std::vector<std::wstring>& paths) {
  size_t chars = 1;  // Final terminator.
  for (const auto& path : paths) chars += path.size() + 1;
  HGLOBAL handle =
      ::GlobalAlloc(GHND, sizeof(DROPFILES) + chars * sizeof(wchar_t));
  if (!handle) return nullptr;
  auto* drop_files = static_cast<DROPFILES*>(::GlobalLock(handle));
  drop_files->pFiles = sizeof(DROPFILES);
  drop_files->fWide = TRUE;
  auto* cursor = reinterpret_cast<wchar_t*>(
      reinterpret_cast<BYTE*>(drop_files) + sizeof(DROPFILES));
  for (const auto& path : paths) {
    std::memcpy(cursor, path.c_str(), (path.size() + 1) * sizeof(wchar_t));
    cursor += path.size() + 1;
  }
  *cursor = L'\0';
  ::GlobalUnlock(handle);
  return handle;
}

// Hands |handle| over to |data_object|, which then owns it.
bool SetHGlobal(IDataObject* data_object, CLIPFORMAT format, HGLOBAL handle) {
  if (!handle) return false;
  FORMATETC format_etc = {format, nullptr, DVASPECT_CONTENT, -1,
                          TYMED_HGLOBAL};
  STGMEDIUM medium = {};
  medium.tymed = TYMED_HGLOBAL;
  medium.hGlobal = handle;
  if (FAILED(data_object->SetData(&format_etc, &medium, TRUE))) {
    ::GlobalFree(handle);
    return false;
  }
  return true;
}

// Shows the first item's shell icon under the cursor. Best effort: without it
// Windows still shows the regular drag cursor.
void SetDragImage(IDataObject* data_object, const std::wstring& path) {
  IDragSourceHelper* helper = nullptr;
  if (FAILED(::CoCreateInstance(CLSID_DragDropHelper, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&helper)))) {
    return;
  }
  SHFILEINFOW file_info = {};
  if (!::SHGetFileInfoW(path.c_str(), 0, &file_info, sizeof(file_info),
                        SHGFI_ICON | SHGFI_LARGEICON) ||
      !file_info.hIcon) {
    helper->Release();
    return;
  }

  const int size = ::GetSystemMetrics(SM_CXICON);
  BITMAPINFO bitmap_info = {};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = size;
  bitmap_info.bmiHeader.biHeight = -size;  // Top-down.
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  HDC screen_dc = ::GetDC(nullptr);
  HDC memory_dc = ::CreateCompatibleDC(screen_dc);
  void* bits = nullptr;
  HBITMAP bitmap = ::CreateDIBSection(screen_dc, &bitmap_info, DIB_RGB_COLORS,
                                      &bits, nullptr, 0);
  if (bitmap) {
    HGDIOBJ previous = ::SelectObject(memory_dc, bitmap);
    ::DrawIconEx(memory_dc, 0, 0, file_info.hIcon, size, size, 0, nullptr,
                 DI_NORMAL);
    ::SelectObject(memory_dc, previous);
  }
  ::DeleteDC(memory_dc);
  ::ReleaseDC(nullptr, screen_dc);
  ::DestroyIcon(file_info.hIcon);

  if (bitmap) {
    SHDRAGIMAGE image = {};
    image.sizeDragImage = {size, size};
    image.ptOffset = {size / 2, size / 2};
    image.hbmpDragImage = bitmap;
    image.crColorKey = CLR_NONE;
    // On success the helper owns the bitmap.
    if (FAILED(helper->InitializeFromBitmap(&image, data_object))) {
      ::DeleteObject(bitmap);
    }
  }
  helper->Release();
}

// Accepts {session, items: [{type: "path", path}]}, or the pre-0.4.0 bare
// list of paths (|session| stays null). Fails for anything else, including
// item types this version does not know.
bool ParseStartDrag(const flutter::EncodableValue* arguments,
                    flutter::EncodableValue* session,
                    std::vector<std::string>* paths) {
  if (!arguments) return false;
  if (const auto* list = std::get_if<flutter::EncodableList>(arguments)) {
    for (const auto& value : *list) {
      if (const auto* path = std::get_if<std::string>(&value)) {
        paths->push_back(*path);
      }
    }
    return true;
  }
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (!map) return false;
  const auto items_it = map->find(flutter::EncodableValue("items"));
  if (items_it == map->end()) return false;
  const auto* items = std::get_if<flutter::EncodableList>(&items_it->second);
  if (!items) return false;
  for (const auto& value : *items) {
    const auto* item = std::get_if<flutter::EncodableMap>(&value);
    if (!item) return false;
    const auto type_it = item->find(flutter::EncodableValue("type"));
    const auto path_it = item->find(flutter::EncodableValue("path"));
    if (type_it == item->end() || path_it == item->end()) return false;
    const auto* type = std::get_if<std::string>(&type_it->second);
    const auto* path = std::get_if<std::string>(&path_it->second);
    if (!type || *type != "path" || !path) return false;
    paths->push_back(*path);
  }
  const auto session_it = map->find(flutter::EncodableValue("session"));
  if (session_it != map->end()) *session = session_it->second;
  return true;
}

bool IsPrimaryButtonDown() {
  const int button = ::GetSystemMetrics(SM_SWAPBUTTON) ? VK_RBUTTON : VK_LBUTTON;
  return (::GetAsyncKeyState(button) & 0x8000) != 0;
}

}  // namespace

// static
void FlutterDragOutPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_drag_out",
          &flutter::StandardMethodCodec::GetInstance());
  auto plugin =
      std::make_unique<FlutterDragOutPlugin>(registrar, std::move(channel));
  registrar->AddPlugin(std::move(plugin));
}

FlutterDragOutPlugin::FlutterDragOutPlugin(
    flutter::PluginRegistrarWindows* registrar,
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel)
    : registrar_(registrar), channel_(std::move(channel)) {
  // DoDragDrop needs OLE on this (STA) thread. Another component may already
  // have initialized it; that is fine as long as every success is balanced.
  ole_initialized_ = SUCCEEDED(::OleInitialize(nullptr));

  const HINSTANCE instance = ::GetModuleHandleW(nullptr);
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = MessageWindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kMessageWindowClass;
  ::RegisterClassW(&window_class);  // Fails harmlessly if already registered.
  message_window_ = ::CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0,
                                      0, HWND_MESSAGE, nullptr, instance,
                                      nullptr);
  if (message_window_) {
    ::SetWindowLongPtrW(message_window_, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(this));
  }

  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

FlutterDragOutPlugin::~FlutterDragOutPlugin() {
  if (message_window_) ::DestroyWindow(message_window_);
  if (ole_initialized_) ::OleUninitialize();
}

void FlutterDragOutPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() != "startDrag") {
    result->NotImplemented();
    return;
  }
  flutter::EncodableValue session;
  std::vector<std::string> utf8_paths;
  if (!ParseStartDrag(method_call.arguments(), &session, &utf8_paths)) {
    result->Error("bad_args", "Expected {session, items}");
    return;
  }

  std::vector<std::wstring> paths;
  for (const auto& path : utf8_paths) {
    if (path.empty()) continue;
    std::wstring wide = Utf8ToWide(path);
    for (auto& ch : wide) {
      if (ch == L'/') ch = L'\\';
    }
    paths.push_back(std::move(wide));
  }

  if (paths.empty() || drag_queued_ || !message_window_ || !ole_initialized_ ||
      !IsPrimaryButtonDown()) {
    result->Success(flutter::EncodableValue(false));
    return;
  }

  pending_paths_ = std::move(paths);
  pending_session_ = std::move(session);
  drag_queued_ = true;
  ::PostMessageW(message_window_, kStartDragMessage, 0, 0);
  result->Success(flutter::EncodableValue(true));
}

// static
LRESULT CALLBACK FlutterDragOutPlugin::MessageWindowProc(HWND hwnd,
                                                         UINT message,
                                                         WPARAM wparam,
                                                         LPARAM lparam) {
  if (message == kStartDragMessage) {
    auto* plugin = reinterpret_cast<FlutterDragOutPlugin*>(
        ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (plugin) plugin->RunDrag();
    return 0;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

void FlutterDragOutPlugin::RunDrag() {
  drag_queued_ = false;
  std::vector<std::wstring> paths = std::move(pending_paths_);
  pending_paths_.clear();
  const flutter::EncodableValue session = std::move(pending_session_);
  pending_session_ = flutter::EncodableValue();

  // The button may have been released while the message was queued; a drag
  // started now would drop immediately wherever the pointer happens to be.
  if (paths.empty() || !IsPrimaryButtonDown()) {
    NotifyDragEnded(session, false);
    return;
  }

  // An empty shell data object accepts arbitrary formats through SetData,
  // including the ones IDragSourceHelper stores for the drag image.
  IDataObject* data_object = nullptr;
  if (FAILED(::SHCreateDataObject(nullptr, 0, nullptr, nullptr,
                                  IID_PPV_ARGS(&data_object)))) {
    NotifyDragEnded(session, false);
    return;
  }
  if (!SetHGlobal(data_object, CF_HDROP, CreateHDrop(paths))) {
    data_object->Release();
    NotifyDragEnded(session, false);
    return;
  }

  // Ask targets such as Explorer to copy rather than move by default.
  HGLOBAL preferred = ::GlobalAlloc(GHND, sizeof(DWORD));
  if (preferred) {
    *static_cast<DWORD*>(::GlobalLock(preferred)) = DROPEFFECT_COPY;
    ::GlobalUnlock(preferred);
    SetHGlobal(data_object,
               static_cast<CLIPFORMAT>(
                   ::RegisterClipboardFormatW(CFSTR_PREFERREDDROPEFFECT)),
               preferred);
  }
  SetDragImage(data_object, paths.front());

  HWND view = nullptr;
  if (auto* flutter_view = registrar_->GetView()) {
    view = flutter_view->GetNativeWindow();
  }

  // From here on the OLE drag loop consumes the button release, so Flutter
  // would never see it and would keep its drag (and pointer) "down" forever.
  // Synthesize the release now at the current, outside-the-window position:
  // no DragTarget is there, so the Flutter drag that triggered this is simply
  // cancelled. This also releases the capture Flutter took on button down.
  if (view) {
    POINT point;
    ::GetCursorPos(&point);
    ::ScreenToClient(view, &point);
    ::SendMessageW(view, WM_LBUTTONUP, 0, MAKELPARAM(point.x, point.y));
  }

  auto* drop_source = new DropSource(view ? ::GetAncestor(view, GA_ROOT)
                                          : nullptr);
  DWORD effect = DROPEFFECT_NONE;
  // Copy only: allowing move would let e.g. Explorer relocate the original
  // behind the app's back.
  const HRESULT hr =
      ::DoDragDrop(data_object, drop_source, DROPEFFECT_COPY, &effect);
  drop_source->Release();
  data_object->Release();

  NotifyDragEnded(session,
                  hr == DRAGDROP_S_DROP && effect != DROPEFFECT_NONE);
}

void FlutterDragOutPlugin::NotifyDragEnded(
    const flutter::EncodableValue& session, bool dropped) {
  channel_->InvokeMethod(
      "dragEnded",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("session"), session},
          {flutter::EncodableValue("dropped"),
           flutter::EncodableValue(dropped)},
      }));
}

}  // namespace flutter_drag_out
