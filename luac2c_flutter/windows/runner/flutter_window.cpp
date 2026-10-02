#include "flutter_window.h"

#include <shellapi.h>
#include <shobjidl.h>
#include <windows.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

// 宽字符 → UTF-8。EncodableValue 只收 std::string。
std::string WideToUtf8(const wchar_t* w) {
  if (w == nullptr || *w == L'\0') return std::string();
  int need = ::WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr,
                                   nullptr);
  if (need <= 1) return std::string();
  std::string utf8(static_cast<size_t>(need - 1), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w, -1, utf8.data(), need, nullptr, nullptr);
  return utf8;
}

// UTF-8 → 宽字符（调用方负责 SysFreeString / CoTaskMemFree 的配对）
wchar_t* Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return nullptr;
  int need = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (need <= 1) return nullptr;
  auto* buf = static_cast<wchar_t*>(::CoTaskMemAlloc(sizeof(wchar_t) *
                                                     static_cast<size_t>(need)));
  if (buf == nullptr) return nullptr;
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, buf, need);
  return buf;
}

}  // namespace

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

  // 文件对话框通道。原先 Dart 侧是拉起 powershell.exe + WinForms 的
  // OpenFileDialog，那条路有两个硬伤：
  //   1) powershell 进程没有 PerMonitorV2 感知，系统按 96 DPI 渲染对话框再
  //      位图放大，高分屏上必然发虚；
  //   2) 对话框的父窗口是 powershell 的控制台，容易被主窗口压住，
  //      还会闪一个黑框，返回值还得穿过管道做编码往返。
  // 换成 IFileOpenDialog 后这些都不存在了：同一个进程、同一个 HWND 当父窗口、
  // 宽字符路径直接取。
  file_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "luac2c/file",
      &flutter::StandardMethodCodec::GetInstance());
  file_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "pick") {
          ShowOpenDialog();
        } else if (call.method_name() == "reveal") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            auto it = args->find(flutter::EncodableValue("path"));
            if (it != args->end()) {
              const auto* p = std::get_if<std::string>(&it->second);
              if (p != nullptr) RevealInExplorer(*p);
            }
          }
        }
        // 通道只做单向触发：结果通过 "picked" 推回给 Dart，这里立即回一个
        // 空结果，别让 Dart 侧的 invoke 悬着。
        result->Success();
      });

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
  file_channel_ = nullptr;

  Win32Window::OnDestroy();
}

void FlutterWindow::ShowOpenDialog() {
  flutter::EncodableList picked;

  // IFileOpenDialog 是 COM 接口，必须 Release。CoInitializeEx 已在 wWinMain
  // 里以 STA 做过，这里直接创建即可。
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || dialog == nullptr) {
    if (file_channel_) {
      file_channel_->InvokeMethod(
          "picked", std::make_unique<flutter::EncodableValue>(
                        flutter::EncodableValue(picked)));
    }
    return;
  }

  DWORD options = 0;
  dialog->GetOptions(&options);
  // 多选 + 只认真实存在的文件 + 强制文件系统（挡掉"新建文件夹"那类虚拟项）
  dialog->SetOptions(options | FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST |
                     FOS_PATHMUSTEXIST | FOS_FORCEFILESYSTEM |
                     FOS_NOCHANGEDIR);

  // 文件类型筛选。给 .lua 和 .luac 各一段，最后一段"所有文件"。
  struct FilterSpec {
    const wchar_t* name;
    const wchar_t* pattern;
  };
  const FilterSpec filters[] = {
      {L"Lua 源文件", L"*.lua;*.luac"},
      {L"字节码文件", L"*.luac"},
      {L"所有文件", L"*.*"},
  };
  COMDLG_FILTERSPEC specs[3];
  for (size_t i = 0; i < 3; ++i) {
    specs[i].pszName = filters[i].name;
    specs[i].pszSpec = filters[i].pattern;
  }
  dialog->SetFileTypes(3, specs);

  // 标题写清楚要干什么：这里是"选要翻译的源文件"，不是笼统的"打开"
  dialog->SetTitle(L"选择要翻译的 Lua 源文件");

  // 默认扩展名：文件名框里没写后缀时用它补上
  dialog->SetDefaultExtension(L"lua");

  // 以主窗口为父：模态、置顶、跟随 DPI
  hr = dialog->Show(GetHandle());
  if (SUCCEEDED(hr)) {
    IShellItemArray* items = nullptr;
    if (SUCCEEDED(dialog->GetResults(&items)) && items != nullptr) {
      DWORD count = 0;
      items->GetCount(&count);
      for (DWORD i = 0; i < count; ++i) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(items->GetItemAt(i, &item)) && item != nullptr) {
          wchar_t* path = nullptr;
          if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) &&
              path != nullptr) {
            std::string utf8 = WideToUtf8(path);
            if (!utf8.empty()) {
              picked.push_back(flutter::EncodableValue(utf8));
            }
            ::CoTaskMemFree(path);
          }
          item->Release();
        }
      }
      items->Release();
    }
  }
  dialog->Release();

  if (file_channel_) {
    file_channel_->InvokeMethod(
        "picked", std::make_unique<flutter::EncodableValue>(
                      flutter::EncodableValue(picked)));
  }
}

void FlutterWindow::RevealInExplorer(const std::string& utf8_path) {
  wchar_t* wide = Utf8ToWide(utf8_path);
  if (wide == nullptr) return;
  // /select 让资源管理器定位到文件本身并高亮——这才是"打开输出目录"
  // 在 Windows 下的实际语义。只 explorer <dir> 的话用户还得自己翻。
  std::wstring select_arg = L"/select,";
  select_arg += wide;
  ::CoTaskMemFree(wide);
  ::ShellExecuteW(nullptr, L"explorer.exe", select_arg.c_str(), nullptr, nullptr,
                   SW_SHOWNORMAL);
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
