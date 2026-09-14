#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // ---- 单实例：同一会话内只允许一个进程 ----
  // 必须在创建任何窗口之前拦截：否则重复双击会产生多个窗口/多个托盘/多个内核，
  // 各自管理系统代理与内核，互相冲突（状态被别的进程覆盖）。
  // 已有一个实例 → 唤醒它的窗口（可能最小化到托盘），本进程立即退出。
  {
    HANDLE mutex =
        ::CreateMutexW(nullptr, FALSE, L"Local\\MoneyFly_SingleInstance");
    if (mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
      HWND hwnd = ::FindWindowW(nullptr, L"MoneyFly");
      if (hwnd != nullptr) {
        ::ShowWindow(hwnd, SW_RESTORE);
        ::SetForegroundWindow(hwnd);
      }
      return 0;
    }
    // mutex 句柄有意不关闭：进程存活期间持有命名互斥量，退出时系统自动释放，
    // 崩溃/被杀也不会残留「假锁」。
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // 竖版窗口（420×780），与手机端比例一致
  Win32Window::Size size(420, 780);
  const int screen_w = GetSystemMetrics(SM_CXSCREEN);
  const int screen_h = GetSystemMetrics(SM_CYSCREEN);
  Win32Window::Point origin((screen_w - size.width) / 2,
                            (screen_h - size.height) / 2);
  if (!window.Create(L"MoneyFly", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
