#include "flutter_window.h"

#include <commdlg.h>
#include <shellapi.h>
#include <windows.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 建立与 Dart 侧的通道，供 WM_DROPFILES 回传文件路径
  drop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "luac2c/drop",
      &flutter::StandardMethodCodec::GetInstance());

  // 允许把文件拖进窗口
  DragAcceptFiles(GetHandle(), TRUE);

  // 注意：不用 SetNextFrameCallback 再 Show——玻璃着色器初始化异常时首帧
  // 永远不来，窗口会一直不显示（表现为"进程在但打不开"）。直接显示窗口，
  // 即使渲染慢也先让用户看到窗体。
  this->Show();
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  drop_channel_ = nullptr;

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DROPFILES: {
      // 拖入文件：把全部路径以列表发给 Dart（批量处理）
      HDROP drop = reinterpret_cast<HDROP>(wparam);
      UINT n = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      flutter::EncodableList list;
      for (UINT i = 0; i < n; ++i) {
        wchar_t path[MAX_PATH] = {0};
        if (DragQueryFileW(drop, i, path, MAX_PATH) > 0) {
          // 宽字符路径转 UTF-8（EncodableValue 只接受 std::string）
          int need = WideCharToMultiByte(CP_UTF8, 0, path, -1, nullptr, 0,
                                         nullptr, nullptr);
          if (need > 1) {
            std::string utf8(need - 1, '\0');
            WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8.data(), need,
                                nullptr, nullptr);
            list.push_back(flutter::EncodableValue(utf8));
          }
        }
      }
      DragFinish(drop);
      if (!list.empty() && drop_channel_) {
        drop_channel_->InvokeMethod(
            "dropped",
            std::make_unique<flutter::EncodableValue>(
                flutter::EncodableValue(list)));
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
