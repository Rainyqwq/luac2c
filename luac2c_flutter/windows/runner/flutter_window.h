#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 原生拖拽通道：把拖进窗口的文件路径发给 Dart（不依赖第三方插件）
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      drop_channel_;

  // 文件对话框通道：Dart 请求打开原生对话框，原生把选中的路径回传
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      file_channel_;

  // 用系统公共项对话框（IFileOpenDialog）选文件。资源管理器用的就是它，
  // 天然跟随系统主题与 DPI，不需要自己拼 UI。
  // 选到的路径以 "picked" 推给 Dart；用户取消则推空列表。
  void ShowOpenDialog();

  // 打开资源管理器并选中 |path|。带 /select 才是 Windows 的习惯动作，
  // 只把目录打开的话用户还得自己找文件。
  void RevealInExplorer(const std::string& utf8_path);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
