#include "include/flutter_drag_out/flutter_drag_out_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>

// Starts native GTK drag sessions carrying `text/uri-list` so files can be
// dragged out of the Flutter app into file managers and other applications.
//
// It never registers a drop target: in-app drags stay with Flutter's own
// `Draggable`, and drag-in stays with whatever the app already uses.

#define FLUTTER_DRAG_OUT_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_drag_out_plugin_get_type(), \
                              FlutterDragOutPlugin))

struct _FlutterDragOutPlugin {
  GObject parent_instance;

  FlMethodChannel* channel;

  // The GtkEventBox inside FlView that receives Flutter's pointer events.
  // It is also the drag source widget. Weak pointer.
  GtkWidget* event_box;

  // Copy of the latest button-press/motion event on |event_box|.
  // gtk_drag_begin needs the triggering event (Wayland needs its serial).
  GdkEvent* last_event;

  // State of the drag started by this plugin, if any.
  GdkDragContext* drag_context;
  gchar** uris;
  gboolean drag_failed;
  // Dart's ID of the running session, echoed back in `dragEnded`. Null for
  // the pre-0.4.0 arguments.
  FlValue* session;
};

G_DEFINE_TYPE(FlutterDragOutPlugin, flutter_drag_out_plugin, g_object_get_type())

static void clear_drag(FlutterDragOutPlugin* self) {
  self->drag_context = nullptr;
  g_clear_pointer(&self->uris, g_strfreev);
  self->drag_failed = FALSE;
  g_clear_pointer(&self->session, fl_value_unref);
}

static void notify_drag_ended(FlutterDragOutPlugin* self, FlValue* session,
                              gboolean dropped) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(
      args, "session",
      session != nullptr ? fl_value_ref(session) : fl_value_new_null());
  fl_value_set_string_take(args, "dropped", fl_value_new_bool(dropped));
  fl_method_channel_invoke_method(self->channel, "dragEnded", args, nullptr,
                                  nullptr, nullptr);
}

// GtkWidget::event runs before the specific button/motion handlers, which
// FlView connects first and which stop emission. Only records; never handles.
static gboolean event_cb(GtkWidget* widget, GdkEvent* event,
                         gpointer user_data) {
  FlutterDragOutPlugin* self = FLUTTER_DRAG_OUT_PLUGIN(user_data);
  const GdkEventType type = gdk_event_get_event_type(event);
  if (type == GDK_BUTTON_PRESS || type == GDK_MOTION_NOTIFY) {
    g_clear_pointer(&self->last_event, gdk_event_free);
    self->last_event = gdk_event_copy(event);
  }
  return FALSE;
}

// |uris| is set only while this plugin's drag runs. |drag_context| is still
// null during drag-begin, which GTK emits from inside gtk_drag_begin.
static gboolean is_ours(FlutterDragOutPlugin* self, GdkDragContext* context) {
  return self->uris != nullptr &&
         (self->drag_context == nullptr || context == self->drag_context);
}

// Shows the first item's themed file icon under the cursor.
static void drag_begin_cb(GtkWidget* widget, GdkDragContext* context,
                          gpointer user_data) {
  FlutterDragOutPlugin* self = FLUTTER_DRAG_OUT_PLUGIN(user_data);
  if (!is_ours(self, context) || self->uris == nullptr ||
      self->uris[0] == nullptr) {
    return;
  }
  g_autoptr(GFile) file = g_file_new_for_uri(self->uris[0]);
  g_autoptr(GFileInfo) info =
      g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_ICON,
                        G_FILE_QUERY_INFO_NONE, nullptr, nullptr);
  GIcon* icon = info != nullptr ? g_file_info_get_icon(info) : nullptr;
  if (icon != nullptr) {
    gtk_drag_set_icon_gicon(context, icon, 16, 16);
  }
}

static gboolean is_own_window(GtkWidget* widget, GdkWindow* window) {
  GdkWindow* own = gtk_widget_get_window(widget);
  return window != nullptr && own != nullptr &&
         gdk_window_get_toplevel(window) == gdk_window_get_toplevel(own);
}

static void drag_data_get_cb(GtkWidget* widget, GdkDragContext* context,
                             GtkSelectionData* selection_data, guint info,
                             guint time, gpointer user_data) {
  FlutterDragOutPlugin* self = FLUTTER_DRAG_OUT_PLUGIN(user_data);
  if (!is_ours(self, context) || self->uris == nullptr) return;
  // Drops back into this app get no data: in-app moves belong to the app's
  // own Flutter drag.
  if (is_own_window(widget, gdk_drag_context_get_dest_window(context))) {
    return;
  }
  gtk_selection_data_set_uris(selection_data, self->uris);
}

static gboolean drag_failed_cb(GtkWidget* widget, GdkDragContext* context,
                               GtkDragResult result, gpointer user_data) {
  FlutterDragOutPlugin* self = FLUTTER_DRAG_OUT_PLUGIN(user_data);
  if (!is_ours(self, context)) return FALSE;
  self->drag_failed = TRUE;
  // The "starting position" is a row Flutter drew, which GTK knows nothing
  // about, so skip the snap-back animation.
  return TRUE;
}

static void drag_end_cb(GtkWidget* widget, GdkDragContext* context,
                        gpointer user_data) {
  FlutterDragOutPlugin* self = FLUTTER_DRAG_OUT_PLUGIN(user_data);
  if (!is_ours(self, context)) return;
  const gboolean dropped = !self->drag_failed;
  g_autoptr(FlValue) session =
      self->session != nullptr ? fl_value_ref(self->session) : nullptr;
  clear_drag(self);
  notify_drag_ended(self, session, dropped);
}

// From now on GTK's drag grab consumes the button release, so Flutter would
// never see it and would keep its drag (and pointer) "down" forever.
// Synthesize the release now at the current, outside-the-window position: no
// DragTarget is there, so the Flutter drag that triggered this is simply
// cancelled.
static void send_synthetic_release(FlutterDragOutPlugin* self) {
  GdkEvent* source = self->last_event;
  GdkEvent* release = gdk_event_new(GDK_BUTTON_RELEASE);
  release->button.window =
      GDK_WINDOW(g_object_ref(gdk_event_get_window(source)));
  release->button.send_event = TRUE;
  release->button.time = gdk_event_get_time(source);
  gdouble x = 0.0, y = 0.0;
  gdk_event_get_coords(source, &x, &y);
  release->button.x = x;
  release->button.y = y;
  gdouble x_root = 0.0, y_root = 0.0;
  gdk_event_get_root_coords(source, &x_root, &y_root);
  release->button.x_root = x_root;
  release->button.y_root = y_root;
  release->button.button = GDK_BUTTON_PRIMARY;
  release->button.state = GDK_BUTTON1_MASK;
  gdk_event_set_device(release, gdk_event_get_device(source));
  gdk_event_set_source_device(release, gdk_event_get_source_device(source));
  gtk_widget_event(self->event_box, release);
  gdk_event_free(release);
}

// Accepts {session, items: [{type: "path", path}]}, or the pre-0.4.0 bare
// list of paths (|session| stays null). Fails for anything else, including
// item types this version does not know. |paths| borrows from |args|.
static gboolean parse_start_drag(FlValue* args, FlValue** session,
                                 GPtrArray* paths) {
  *session = nullptr;
  if (args == nullptr) return FALSE;
  if (fl_value_get_type(args) == FL_VALUE_TYPE_LIST) {
    const size_t length = fl_value_get_length(args);
    for (size_t i = 0; i < length; i++) {
      FlValue* value = fl_value_get_list_value(args, i);
      if (fl_value_get_type(value) != FL_VALUE_TYPE_STRING) continue;
      g_ptr_array_add(paths, const_cast<gchar*>(fl_value_get_string(value)));
    }
    return TRUE;
  }
  if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return FALSE;
  FlValue* items = fl_value_lookup_string(args, "items");
  if (items == nullptr || fl_value_get_type(items) != FL_VALUE_TYPE_LIST) {
    return FALSE;
  }
  const size_t length = fl_value_get_length(items);
  for (size_t i = 0; i < length; i++) {
    FlValue* item = fl_value_get_list_value(items, i);
    if (fl_value_get_type(item) != FL_VALUE_TYPE_MAP) return FALSE;
    FlValue* type = fl_value_lookup_string(item, "type");
    FlValue* path = fl_value_lookup_string(item, "path");
    if (type == nullptr || fl_value_get_type(type) != FL_VALUE_TYPE_STRING ||
        strcmp(fl_value_get_string(type), "path") != 0 || path == nullptr ||
        fl_value_get_type(path) != FL_VALUE_TYPE_STRING) {
      return FALSE;
    }
    g_ptr_array_add(paths, const_cast<gchar*>(fl_value_get_string(path)));
  }
  *session = fl_value_lookup_string(args, "session");
  return TRUE;
}

static FlMethodResponse* start_drag(FlutterDragOutPlugin* self,
                                    FlValue* args) {
  FlValue* session = nullptr;
  g_autoptr(GPtrArray) paths = g_ptr_array_new();
  if (!parse_start_drag(args, &session, paths)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad_args", "Expected {session, items}", nullptr));
  }

  GdkModifierType state = static_cast<GdkModifierType>(0);
  if (self->event_box == nullptr || self->uris != nullptr ||
      self->last_event == nullptr ||
      gdk_event_get_event_type(self->last_event) != GDK_MOTION_NOTIFY ||
      !gdk_event_get_state(self->last_event, &state) ||
      !(state & GDK_BUTTON1_MASK)) {
    g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }

  GPtrArray* uris = g_ptr_array_new();
  for (guint i = 0; i < paths->len; i++) {
    gchar* uri = g_filename_to_uri(
        static_cast<const gchar*>(g_ptr_array_index(paths, i)), nullptr,
        nullptr);
    if (uri != nullptr) g_ptr_array_add(uris, uri);
  }
  const guint count = uris->len;
  g_ptr_array_add(uris, nullptr);
  gchar** uri_list = reinterpret_cast<gchar**>(g_ptr_array_free(uris, FALSE));
  if (count == 0) {
    g_strfreev(uri_list);
    g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }
  self->uris = uri_list;
  self->session =
      session != nullptr && fl_value_get_type(session) != FL_VALUE_TYPE_NULL
          ? fl_value_ref(session)
          : nullptr;

  GtkTargetList* targets = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add_uri_targets(targets, 0);
  // Copy only: allowing move would let e.g. a file manager relocate the
  // original behind the app's back.
  self->drag_context = gtk_drag_begin_with_coordinates(
      self->event_box, targets, GDK_ACTION_COPY, GDK_BUTTON_PRIMARY,
      self->last_event, -1, -1);
  gtk_target_list_unref(targets);

  if (self->drag_context == nullptr) {
    clear_drag(self);
    g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }

  send_synthetic_release(self);
  g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void flutter_drag_out_plugin_handle_method_call(
    FlutterDragOutPlugin* self, FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  if (strcmp(method, "startDrag") == 0) {
    response = start_drag(self, fl_method_call_get_args(method_call));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void flutter_drag_out_plugin_dispose(GObject* object) {
  FlutterDragOutPlugin* self = FLUTTER_DRAG_OUT_PLUGIN(object);
  if (self->event_box != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(self->event_box),
                                 reinterpret_cast<gpointer*>(&self->event_box));
    self->event_box = nullptr;
  }
  g_clear_pointer(&self->last_event, gdk_event_free);
  clear_drag(self);
  g_clear_object(&self->channel);
  G_OBJECT_CLASS(flutter_drag_out_plugin_parent_class)->dispose(object);
}

static void flutter_drag_out_plugin_class_init(
    FlutterDragOutPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_drag_out_plugin_dispose;
}

static void flutter_drag_out_plugin_init(FlutterDragOutPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  FlutterDragOutPlugin* plugin = FLUTTER_DRAG_OUT_PLUGIN(user_data);
  flutter_drag_out_plugin_handle_method_call(plugin, method_call);
}

// FlView keeps its pointer handling on a private GtkEventBox child.
static GtkWidget* find_event_box(FlView* view) {
  if (view == nullptr) return nullptr;
  GtkWidget* found = nullptr;
  GList* children = gtk_container_get_children(GTK_CONTAINER(view));
  for (GList* child = children; child != nullptr; child = child->next) {
    if (GTK_IS_EVENT_BOX(child->data)) {
      found = GTK_WIDGET(child->data);
      break;
    }
  }
  g_list_free(children);
  return found;
}

void flutter_drag_out_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlutterDragOutPlugin* plugin = FLUTTER_DRAG_OUT_PLUGIN(
      g_object_new(flutter_drag_out_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "flutter_drag_out", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  plugin->event_box = find_event_box(fl_plugin_registrar_get_view(registrar));
  if (plugin->event_box != nullptr) {
    g_object_add_weak_pointer(G_OBJECT(plugin->event_box),
                              reinterpret_cast<gpointer*>(&plugin->event_box));
    const GConnectFlags flags = static_cast<GConnectFlags>(0);
    g_signal_connect_object(plugin->event_box, "event", G_CALLBACK(event_cb),
                            plugin, flags);
    g_signal_connect_object(plugin->event_box, "drag-begin",
                            G_CALLBACK(drag_begin_cb), plugin, flags);
    g_signal_connect_object(plugin->event_box, "drag-data-get",
                            G_CALLBACK(drag_data_get_cb), plugin, flags);
    g_signal_connect_object(plugin->event_box, "drag-failed",
                            G_CALLBACK(drag_failed_cb), plugin, flags);
    g_signal_connect_object(plugin->event_box, "drag-end",
                            G_CALLBACK(drag_end_cb), plugin, flags);
  } else {
    g_warning("flutter_drag_out: Flutter view event box not found; "
              "drag-out is disabled.");
  }

  g_object_unref(plugin);
}
