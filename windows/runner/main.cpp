#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <stdio.h>
#include <string>
#include <wchar.h>

#include "flutter_window.h"
#include "utils.h"

// ---- 启动诊断日志 ----
// 为什么需要：Windows 客户报「装完打不开、没有窗口」时，进程往往还在任务管理器里，
// 而 Flutter 的 Dart 日志要等引擎起来才会写 —— 恰恰是引擎/首帧没起来时最需要日志。
// 这里在原生入口记几条关键事实，客服拿到 %LOCALAPPDATA%\MoneyFly\boot.log 就能定性：
//   mutex-exists / window-created / frame-first / fallback-shown / create-failed
static void BootLog(const wchar_t* msg) {
  wchar_t dir[MAX_PATH] = {0};
  DWORD n = ::GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    ::GetTempPathW(MAX_PATH, dir);
  } else {
    ::CreateDirectoryW((std::wstring(dir) + L"\MoneyFly").c_str(), nullptr);
    wcscat_s(dir, L"\MoneyFly");
  }
  std::wstring path = std::wstring(dir) + L"\boot.log";
  HANDLE f = ::CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME st;
  ::GetLocalTime(&st);
  wchar_t line[512] = {0};
  swprintf_s(line, L"[%04d-%02d-%02d %02d:%02d:%02d] %s\r\n", st.wYear,
             st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, msg);
  DWORD written = 0;
  ::WriteFile(f, line, (DWORD)(wcslen(line) * sizeof(wchar_t)), &written, nullptr);
  ::CloseHandle(f);
}

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
      // 已有实例：唤醒它的窗口（可能被最小化到托盘或被我方 hide() 隐藏）。
      // 旧实现只 FindWindow 一次就退出：若那一刻对方窗口还没创建出来（开机自启
      // 与用户双击几乎同时），或者因权限/消息过滤没被唤醒，客户看到的就是
      // 「双击图标毫无反应」—— 现在重试几秒，仍找不到就明确弹一句提示。
      HWND hwnd = nullptr;
      for (int i = 0; i < 20 && hwnd == nullptr; ++i) {
        hwnd = ::FindWindowW(nullptr, L"MoneyFly");
        if (hwnd == nullptr) ::Sleep(250);
      }
      if (hwnd != nullptr) {
        ::ShowWindow(hwnd, SW_SHOWNORMAL);
        ::ShowWindow(hwnd, SW_RESTORE);
        ::SetForegroundWindow(hwnd);
        BootLog(L"second-instance: existing window restored");
      } else {
        BootLog(L"second-instance: mutex held but window not found");
        ::MessageBoxW(nullptr,
                      L"MoneyFly 已在运行，但没能把它的窗口调到前台。\n\n"
                      L"请检查任务栏右下角的托盘区（可能在「隐藏的图标」里），"
                      L"双击 MoneyFly 图标即可显示窗口；若托盘里也没有，"
                      L"请在任务管理器结束 moneyfly.exe 后重新打开。",
                      L"MoneyFly", MB_OK | MB_ICONINFORMATION);
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
    BootLog(L"window create failed");
    ::MessageBoxW(nullptr,
                  L"MoneyFly 启动失败：无法创建窗口。\n\n"
                  L"常见原因：显卡驱动异常 / 远程桌面会话 / 安全软件拦截。\n"
                  L"诊断日志：%LOCALAPPDATA%\\MoneyFly\\boot.log",
                  L"MoneyFly", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  BootLog(L"window created");

  // ---- 首帧兜底：保证「一定有窗口」 ----
  // Flutter 的 Windows 模板只在**第一帧渲染完成**后才 Show 窗口
  // （flutter_window.cpp 的 SetNextFrameCallback → Show()）。因此只要首帧出不来
  // —— 老显卡/驱动、远程桌面、虚拟机、或 Dart 侧 runApp 之前被卡住 ——
  // 客户看到的就是「装完了但没有任何窗口」，而进程还活着。这里 3 秒后强制显示，
  // 让用户至少能看到界面（也便于判断是渲染问题还是启动卡住）。
  constexpr UINT_PTR kFallbackShowTimer = 0x4D46;
  HWND hwnd = window.GetHandle();
  if (hwnd != nullptr) {
    ::SetTimer(hwnd, kFallbackShowTimer, 3000, nullptr);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    if (msg.message == WM_TIMER && msg.wParam == kFallbackShowTimer) {
      ::KillTimer(msg.hwnd, kFallbackShowTimer);
      if (!::IsWindowVisible(msg.hwnd)) {
        BootLog(L"first frame late/missing: fallback show");
        ::ShowWindow(msg.hwnd, SW_SHOWNORMAL);
      } else {
        BootLog(L"first frame ok (window shown by Flutter)");
      }
      continue;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
