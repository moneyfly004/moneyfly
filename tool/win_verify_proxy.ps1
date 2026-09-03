# Windows 真机验证：复现 SystemProxyManager 的 Dart 逻辑（无需 Flutter）
# 验证 1) InternetSetOptionW FFI 调用  2) reg 注册表读写  3) 保活重开场景
# 输出统一用 ASCII 标记，便于从 macOS 端解析。
$ErrorActionPreference = 'Continue'
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$port = 2080

function Get-ProxyEnable {
  try { (Get-ItemProperty -Path $reg -Name ProxyEnable -ErrorAction Stop).ProxyEnable } catch { $null }
}
function Get-ProxyServer {
  try { (Get-ItemProperty -Path $reg -Name ProxyServer -ErrorAction Stop).ProxyServer } catch { $null }
}

Write-Output "=== STEP 0: 保存原值 ==="
$origEnable = Get-ProxyEnable
$origServer = Get-ProxyServer
Write-Output ("ORIG_ENABLE=" + $origEnable)
Write-Output ("ORIG_SERVER=" + $origServer)

# ---- 验证 1：InternetSetOptionW（与 Dart FFI 完全相同的签名/常量）----
Write-Output "=== STEP 1: FFI InternetSetOptionW 调用 ==="
$sig = @'
[DllImport("wininet.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
try {
  $winInet = Add-Type -MemberDefinition $sig -Name 'WinInetVerify' -Namespace 'MF' -PassThru
  $INTERNET_OPTION_SETTINGS_CHANGED = 39
  $INTERNET_OPTION_REFRESH = 37
  $r1 = [MF.WinInetVerify]::InternetSetOption([IntPtr]::Zero, $INTERNET_OPTION_SETTINGS_CHANGED, [IntPtr]::Zero, 0)
  $err1 = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  $r2 = [MF.WinInetVerify]::InternetSetOption([IntPtr]::Zero, $INTERNET_OPTION_REFRESH, [IntPtr]::Zero, 0)
  $err2 = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  Write-Output ("FFI_SETTINGS_CHANGED_RESULT=" + $r1 + " lastErr=" + $err1)
  Write-Output ("FFI_REFRESH_RESULT=" + $r2 + " lastErr=" + $err2)
  if ($r1 -and $r2) { Write-Output "FFI_VERDICT=OK" } else { Write-Output "FFI_VERDICT=FAIL" }
} catch {
  Write-Output ("FFI_VERDICT=EXCEPTION: " + $_.Exception.Message)
}

# ---- 验证 2：apply（reg 写 3 个值）----
Write-Output "=== STEP 2: apply 设置代理 ==="
Set-ItemProperty -Path $reg -Name ProxyEnable -Value 1 -Type DWord
Set-ItemProperty -Path $reg -Name ProxyServer -Value ("127.0.0.1:" + $port) -Type String
Set-ItemProperty -Path $reg -Name ProxyOverride -Value '<local>' -Type String
$e = Get-ProxyEnable; $s = Get-ProxyServer
Write-Output ("AFTER_APPLY_ENABLE=" + $e)
Write-Output ("AFTER_APPLY_SERVER=" + $s)
if ($e -eq 1 -and $s -eq ("127.0.0.1:" + $port)) { Write-Output "APPLY_VERDICT=OK" } else { Write-Output "APPLY_VERDICT=FAIL" }

# ---- 验证 3：模拟系统把代理关掉（正是用户报告的现象）----
Write-Output "=== STEP 3: 模拟外部关闭代理 ==="
Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0 -Type DWord
$e = Get-ProxyEnable
Write-Output ("AFTER_EXTERNAL_OFF_ENABLE=" + $e)

# ---- 验证 4：保活探测（复现 _winProxyPointsTo）----
Write-Output "=== STEP 4: 保活探测是否发现掉线 ==="
$detectDown = ($e -ne 1)
Write-Output ("KEEPALIVE_DETECTED_DOWN=" + $detectDown)

# ---- 验证 5：reassert 强制重开（复现修复后的行为）----
Write-Output "=== STEP 5: reassert 重新打开 ==="
Set-ItemProperty -Path $reg -Name ProxyEnable -Value 1 -Type DWord
Set-ItemProperty -Path $reg -Name ProxyServer -Value ("127.0.0.1:" + $port) -Type String
$e = Get-ProxyEnable; $s = Get-ProxyServer
if ($e -eq 1 -and $s -eq ("127.0.0.1:" + $port)) { Write-Output "REASSERT_VERDICT=OK" } else { Write-Output "REASSERT_VERDICT=FAIL" }

# ---- STEP 6：恢复原值 ----
Write-Output "=== STEP 6: restore 恢复原值 ==="
if ($null -ne $origEnable) { Set-ItemProperty -Path $reg -Name ProxyEnable -Value $origEnable -Type DWord }
else { Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0 -Type DWord }
if ($null -ne $origServer) { Set-ItemProperty -Path $reg -Name ProxyServer -Value $origServer -Type String }
$e = Get-ProxyEnable
Write-Output ("AFTER_RESTORE_ENABLE=" + $e)
Write-Output "=== DONE ==="
