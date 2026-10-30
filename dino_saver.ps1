#requires -version 5
<#
  动态屏保（Windows 伪 Kiosk）—— 主程序
  - 全屏置顶、遮住桌面，后台程序照常运行
  - 阻止显示器息屏 / 系统休眠
  - 右下角「关闭」按钮，需输入密码才放行；Alt+F4 / Esc 一律不放行
  - 画面本身由 skins\*.ps1 提供（小恐龙 / 字母雨 / 三星系统），启动时弹窗选
  - 运行期间接管系统声音（静音），退出还原

  用法： dino_saver.ps1                启动（先弹皮肤选择窗）
         dino_saver.ps1 -Skin matrix   直接用指定皮肤，不弹窗（dino/matrix/orbit/random）
         dino_saver.ps1 -NoPicker      用上次的选择直接启动
         dino_saver.ps1 -TestRun 10    预览 10 秒后自动正常退出（不用输密码）
         dino_saver.ps1 -SetPassword   设置密码
         dino_saver.ps1 -RestoreGestures  只还原触控板手势
#>
param(
    [switch]$SetPassword,
    [switch]$RestoreGestures,
    [string]$Skin,
    [switch]$NoPicker,
    [int]$TestRun = 0          # >0 = 预览模式，跑这么多秒就自己走正常退出流程
)

# ============ 可改配置 ============
$DefaultPassword   = 'dino'   # 未设置密码文件时使用的默认密码
$IdleHideCursorMs  = 3000     # 鼠标静止多久后隐藏光标
$ForceFocus        = $false   # $true = 被切走时强行抢回焦点（会让任务管理器也难用，慎开）
$CoverAllScreens   = $true    # 多显示器时把副屏也盖成黑屏
$BlockHotkeys      = $true    # 拦截 Win / Alt+Tab / Alt+Esc / Ctrl+Esc / Alt+F4 / Ctrl+Shift+Esc
                              # （钩子随进程生死，进程一没就自动解除，不会留后遗症；Ctrl+Alt+Del 拦不了也不该拦）
$BlockGestures     = $true    # 运行期间临时关掉触控板三指/四指滑动（切桌面、显示桌面都走这条路，钩子拦不住）
                              # 原值备份在 touchpad_backup.json，退出自动还原；万一没还原，跑「恢复触控板手势.bat」
$MuteWhileRunning  = $true    # 运行期间把系统主音量静音（接管声音），退出还原成原来的状态
                              # 这只是选择窗里那个勾的默认值，实际以勾选为准
$DefaultSkin       = 'dino'   # 没有 settings.json 时选择窗默认选中的皮肤
# ==================================

$ErrorActionPreference = 'Stop'
# 屏保只是个画面：CPU 永远先让给后台干活的程序（课堂转写的实时识别在电池上本来就踩着 CPU 上限）
try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class DinoNative {
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
    [DllImport("user32.dll")]   public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]   public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]   public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")]   public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder buf, int n);
    // 前台窗口是不是桌面/任务栏这类外壳表面。「显示桌面」之后焦点会落在这上头，
    // 键盘就够不着屏保了。只认这几个类，任务管理器之类的一概不抢。
    public static bool ShellHasFocus() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return true;
        var sb = new System.Text.StringBuilder(64);
        GetClassNameW(h, sb, 64);
        string c = sb.ToString();
        return c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd";
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint msg, IntPtr wp, string lp, uint flags, uint timeout, out IntPtr res);
}

// 虚拟桌面：三指左右滑会切桌面，一切走就等于绕过屏保。检测到不在当前桌面就把自己挪过去。
[ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopManager {
    [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr hWnd, out int onCurrent);
    [PreserveSig] int GetWindowDesktopId(IntPtr hWnd, out Guid id);
    [PreserveSig] int MoveWindowToDesktop(IntPtr hWnd, ref Guid id);
}
public class VDesk {
    private static IVirtualDesktopManager _m;
    public static bool Init() {
        try {
            Type t = Type.GetTypeFromCLSID(new Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a"));
            _m = (IVirtualDesktopManager)Activator.CreateInstance(t);
            return _m != null;
        } catch { _m = null; return false; }
    }
    // 拿不准就说「在」，宁可不动也别乱挪窗口
    public static bool OnCurrent(IntPtr h) {
        if (_m == null) return true;
        try { int b; if (_m.IsWindowOnCurrentVirtualDesktop(h, out b) != 0) return true; return b != 0; }
        catch { return true; }
    }
    // probe 是刚刚新建的窗口，它必然落在「当前」桌面上，用它问出当前桌面的 GUID
    public static bool MoveHere(IntPtr target, IntPtr probe) {
        if (_m == null) return false;
        try {
            Guid g;
            if (_m.GetWindowDesktopId(probe, out g) != 0) return false;
            if (g == Guid.Empty) return false;
            return _m.MoveWindowToDesktop(target, ref g) == 0;
        } catch { return false; }
    }
}
// 探针窗口不能抢焦点
public class NoFocusForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
}
// 低级键盘钩子：只吞掉能逃出屏保的那几个组合键，普通打字照常。
// 回调写在 C# 里而不是 PowerShell 委托里——钩子回调有超时，慢了会被系统静默摘掉。
public class KeyBlocker {
    private const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104;
    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
    private static HookProc _proc = new HookProc(Callback);   // 必须留引用，否则被 GC 掉
    private static IntPtr _hook = IntPtr.Zero;
    public static int Blocked = 0;
    [StructLayout(LayoutKind.Sequential)]
    private struct KBD { public uint vkCode, scanCode, flags, time; public IntPtr extra; }
    [DllImport("user32.dll")] private static extern IntPtr SetWindowsHookEx(int id, HookProc cb, IntPtr hMod, uint tid);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hk);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hk, int nCode, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);
    public static bool Install() {
        if (_hook == IntPtr.Zero) _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
        return _hook != IntPtr.Zero;
    }
    public static void Uninstall() {
        if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
    }
    private static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            int msg = (int)wParam;
            if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
                KBD k = (KBD)Marshal.PtrToStructure(lParam, typeof(KBD));
                int vk = (int)k.vkCode;
                bool alt  = (GetAsyncKeyState(0x12) & 0x8000) != 0;
                bool ctrl = (GetAsyncKeyState(0x11) & 0x8000) != 0;
                bool block =
                    vk == 0x5B || vk == 0x5C ||      // 左右 Win
                    (alt  && vk == 0x09)    ||       // Alt+Tab
                    (alt  && vk == 0x1B)    ||       // Alt+Esc
                    (ctrl && vk == 0x1B)    ||       // Ctrl+Esc / Ctrl+Shift+Esc
                    (alt  && vk == 0x73);            // Alt+F4
                if (block) { Blocked++; return (IntPtr)1; }
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }
}
public class DinoCanvas : Panel {
    public DinoCanvas() {
        this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                      ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        this.UpdateStyles();
    }
}

// ============================================================
//  接管系统声音：默认播放设备的主静音开关（Core Audio）
//  改的是「主音量那个喇叭图标」，等于所有正在响的东西一起哑掉；
//  退出时还原成进来之前的状态（本来就是静音的，出去也还它静音）。
// ============================================================
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    [PreserveSig] int GetDevice(string id, out IMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
                               [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    [PreserveSig] int OpenPropertyStore(int access, out IntPtr store);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
}
// 只用到 SetMute/GetMute，但 COM 是按 vtable 顺序调的，
// 前面那些方法一个都不能少——占位就行，反正不调用。
[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume {
    [PreserveSig] int RegisterControlChangeNotify(IntPtr n);
    [PreserveSig] int UnregisterControlChangeNotify(IntPtr n);
    [PreserveSig] int GetChannelCount(out uint n);
    [PreserveSig] int SetMasterVolumeLevel(float db, ref Guid ctx);
    [PreserveSig] int SetMasterVolumeLevelScalar(float v, ref Guid ctx);
    [PreserveSig] int GetMasterVolumeLevel(out float db);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float v);
    [PreserveSig] int SetChannelVolumeLevel(uint ch, float db, ref Guid ctx);
    [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float v, ref Guid ctx);
    [PreserveSig] int GetChannelVolumeLevel(uint ch, out float db);
    [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float v);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}
public class AudioMute {
    private static IAudioEndpointVolume _vol;
    private static Guid _ctx = Guid.NewGuid();
    public static string LastError = "";
    public static bool Init() {
        if (_vol != null) return true;
        try {
            var en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice dev;
            int hr = en.GetDefaultAudioEndpoint(0 /*eRender*/, 1 /*eMultimedia*/, out dev);
            if (hr != 0 || dev == null) { LastError = "GetDefaultAudioEndpoint 0x" + hr.ToString("x8"); return false; }
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object o;
            hr = dev.Activate(ref iid, 23 /*CLSCTX_ALL*/, IntPtr.Zero, out o);
            if (hr != 0 || o == null) { LastError = "Activate 0x" + hr.ToString("x8"); return false; }
            _vol = (IAudioEndpointVolume)o;
            return true;
        } catch (Exception e) { LastError = e.Message; _vol = null; return false; }
    }
    // -1 = 问不出来
    public static int GetMute() {
        if (_vol == null) return -1;
        try { bool m; if (_vol.GetMute(out m) != 0) return -1; return m ? 1 : 0; }
        catch (Exception e) { LastError = e.Message; return -1; }
    }
    public static bool SetMute(bool m) {
        if (_vol == null) return false;
        try { return _vol.SetMute(m, ref _ctx) == 0; }
        catch (Exception e) { LastError = e.Message; return false; }
    }
}
'@

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$PassFile     = Join-Path $ScriptDir 'password.hash'
$LogFile      = Join-Path $ScriptDir 'error.log'
$SkinDir      = Join-Path $ScriptDir 'skins'
$SettingsFile = Join-Path $ScriptDir 'settings.json'

# WinForms 会吞掉事件处理器里的异常，出了事只能靠这个日志
function Write-Err($stage, $msg) {
    try { Add-Content -Path $LogFile -Value ("[{0}] {1}: {2}" -f (Get-Date -Format 'HH:mm:ss'), $stage, $msg) -Encoding UTF8 } catch { }
}

# ============================================================
#  触控板手势（三指/四指滑动）临时关闭
#  钩子只能拦键盘，手势是驱动/外壳直接处理的，拦不到；只能改这份用户级设置
# ============================================================
$TP_KEY       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad'
$TP_VALUES    = @('ThreeFingerSlideEnabled','FourFingerSlideEnabled','ThreeFingerTapEnabled','FourFingerTapEnabled')
$TP_BACKUP    = Join-Path $ScriptDir 'touchpad_backup.json'
$script:tpSaved = $null

function Send-SettingChange {
    $res = [IntPtr]::Zero
    [void][DinoNative]::SendMessageTimeoutW(([IntPtr]0xFFFF), 0x1A, ([IntPtr]::Zero), 'PrecisionTouchPad', 2, 200, [ref]$res)
}

function Disable-TouchpadGestures {
    if (-not (Test-Path $TP_KEY)) { return }
    # 备份文件还在 = 上次没能正常退出。那就以它为准，
    # 否则会把「已经被我们改成 0 的值」当成原始值存下来，手势就永久丢了。
    if (Test-Path $TP_BACKUP) {
        try { $script:tpSaved = Get-Content $TP_BACKUP -Raw | ConvertFrom-Json } catch { $script:tpSaved = $null }
    }
    if (-not $script:tpSaved) {
        $o = New-Object psobject
        foreach ($v in $TP_VALUES) {
            $cur = (Get-ItemProperty -Path $TP_KEY -Name $v -ErrorAction SilentlyContinue).$v
            if ($null -eq $cur) { $cur = -1 }     # -1 = 原本就没这个值，还原时要删掉而不是写 0
            $o | Add-Member -NotePropertyName $v -NotePropertyValue ([int]$cur)
        }
        $script:tpSaved = $o
        try { $o | ConvertTo-Json | Set-Content -Path $TP_BACKUP -Encoding ASCII } catch { }
    }
    foreach ($v in $TP_VALUES) {
        try { Set-ItemProperty -Path $TP_KEY -Name $v -Value 0 -Type DWord } catch { Write-Err 'gesture' $_.Exception.Message }
    }
    Send-SettingChange
}

function Restore-TouchpadGestures {
    if (-not $script:tpSaved) {
        if (-not (Test-Path $TP_BACKUP)) { return }
        try { $script:tpSaved = Get-Content $TP_BACKUP -Raw | ConvertFrom-Json } catch { return }
    }
    foreach ($v in $TP_VALUES) {
        $old = [int]$script:tpSaved.$v
        try {
            if ($old -lt 0) { Remove-ItemProperty -Path $TP_KEY -Name $v -ErrorAction SilentlyContinue }
            else            { Set-ItemProperty   -Path $TP_KEY -Name $v -Value $old -Type DWord }
        } catch { Write-Err 'gesture' $_.Exception.Message }
    }
    Send-SettingChange
    Remove-Item $TP_BACKUP -Force -ErrorAction SilentlyContinue
    $script:tpSaved = $null
}

# ============================================================
#  接管声音
# ============================================================
$script:audioTaken = $false   # 我们到底改没改过
$script:audioPrev  = $false   # 进来之前是不是已经静音了

function Start-AudioTakeover {
    if (-not [AudioMute]::Init()) { Write-Err 'audio' ("拿不到音量接口：" + [AudioMute]::LastError); return }
    $prev = [AudioMute]::GetMute()
    if ($prev -lt 0) { Write-Err 'audio' ("GetMute 失败：" + [AudioMute]::LastError); return }
    if (-not [AudioMute]::SetMute($true)) { Write-Err 'audio' ("SetMute 失败：" + [AudioMute]::LastError); return }
    $script:audioPrev  = ($prev -eq 1)
    $script:audioTaken = $true
}

function Stop-AudioTakeover {
    if (-not $script:audioTaken) { return }
    # 只还原到「进来之前」，本来就静音的就让它继续静音
    [void][AudioMute]::SetMute($script:audioPrev)
    $script:audioTaken = $false
}

function Get-StrHash([string]$s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $b   = [System.Text.Encoding]::UTF8.GetBytes($s)
    (($sha.ComputeHash($b)) | ForEach-Object { $_.ToString('x2') }) -join ''
}

# ---------- 只还原触控板手势然后退出 ----------
if ($RestoreGestures) {
    Restore-TouchpadGestures
    Write-Host ''
    if (Test-Path $TP_KEY) {
        Write-Host '  触控板手势已还原成：' -ForegroundColor Green
        foreach ($v in $TP_VALUES) {
            $cur = (Get-ItemProperty -Path $TP_KEY -Name $v -ErrorAction SilentlyContinue).$v
            if ($null -eq $cur) { $cur = '(默认)' }
            Write-Host ("    {0,-26} {1}" -f $v, $cur)
        }
    } else {
        Write-Host '  这台机器没有精确式触控板设置项，无需还原。' -ForegroundColor Yellow
    }
    Read-Host '  回车退出'
    exit 0
}

# ---------- 设置密码模式 ----------
if ($SetPassword) {
    Write-Host ''
    Write-Host '  设置屏保的解锁密码' -ForegroundColor Cyan
    Write-Host ''
    $p1 = Read-Host '  请输入新密码'
    $p2 = Read-Host '  再输入一次'
    if ([string]::IsNullOrEmpty($p1)) { Write-Host '  密码不能为空，已取消。' -ForegroundColor Yellow; Read-Host '  回车退出'; exit 1 }
    if ($p1 -ne $p2)                  { Write-Host '  两次输入不一致，已取消。' -ForegroundColor Yellow; Read-Host '  回车退出'; exit 1 }
    Set-Content -Path $PassFile -Value (Get-StrHash $p1) -Encoding ASCII
    Write-Host ''
    Write-Host "  已保存到 $PassFile" -ForegroundColor Green
    Read-Host '  回车退出'
    exit 0
}

# ---------- 单实例 ----------
$mutex = New-Object System.Threading.Mutex($true, 'Local\DinoScreenSaverMutex', [ref]$null)
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

$script:PassHash = if (Test-Path $PassFile) { (Get-Content $PassFile -Raw).Trim() } else { Get-StrHash $DefaultPassword }

# ============================================================
#  皮肤：skins\<id>.ps1 每个文件 return 一个哈希表
#    Id / Title / Desc
#    Init   = { param($ctx) ... 返回状态哈希表 }
#    Update = { param($ctx,$st) 推进一帧 }
#    Draw   = { param($ctx,$st,$g) 画一帧 }
#    Theme  = { param($ctx,$st) 返回 @{Bg=;Fg=}，给「关闭」按钮配色 }
#    Close  = { param($ctx,$st) 可选，退出前收尾（比如存最高分）}
#  注意：皮肤文件是被「点源」进来的，所以里面的 scriptblock 跟本脚本同一个作用域，
#  可以直接调 Write-Err；但状态一律走 $st，别往 $script: 里塞。
# ============================================================
$SkinIds = @('dino','matrix','orbit','pendulum','flow')
$script:Skins = @{}
foreach ($id in $SkinIds) {
    $p = Join-Path $SkinDir "$id.ps1"
    if (-not (Test-Path $p)) { Write-Err 'skin' "缺文件：$p"; continue }
    try   { $script:Skins[$id] = (. $p) }
    catch { Write-Err 'skin' "$id 加载失败：$($_.Exception.ToString())" }
}
$SkinIds = @($SkinIds | Where-Object { $script:Skins.ContainsKey($_) })
if ($SkinIds.Count -eq 0) {
    [void][System.Windows.Forms.MessageBox]::Show('skins 文件夹里一个皮肤都没能加载，看 error.log。', '屏保')
    exit 1
}

function Get-SaverSettings {
    $d = @{ skin = $DefaultSkin; mute = $MuteWhileRunning }
    if (Test-Path $SettingsFile) {
        try {
            $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            if ($j.skin) { $d.skin = [string]$j.skin }
            if ($null -ne $j.mute) { $d.mute = [bool]$j.mute }
        } catch { }
    }
    if ($d.skin -ne 'random' -and -not ($SkinIds -contains $d.skin)) { $d.skin = $SkinIds[0] }
    $d
}
function Save-SaverSettings($s) {
    try { [pscustomobject]@{ skin = $s.skin; mute = [bool]$s.mute } | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding ASCII } catch { }
}

[void][DinoNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

# 进程是 DPI-aware 的，所以对话框里那些手写的像素坐标必须自己按 DPI 放大，
# 否则在高分屏上会挤成一团。窗口还没建，先从屏幕 DC 问 DPI。
$gTmp = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:uiK = $gTmp.DpiX / 96.0
$gTmp.Dispose()

# ---------- 皮肤选择窗 ----------
function Show-SkinPicker($cur) {
    $k = $script:uiK
    $d = New-Object System.Windows.Forms.Form
    $d.Text            = '选择屏保'
    $d.FormBorderStyle = 'FixedDialog'
    $d.StartPosition   = 'CenterScreen'
    $d.MaximizeBox     = $false; $d.MinimizeBox = $false
    $d.ClientSize      = New-Object System.Drawing.Size(([int](420*$k)), ([int](306*$k)))
    $d.TopMost         = $true
    $d.ShowInTaskbar   = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = '用哪张皮肤？'
    $lbl.Location = New-Object System.Drawing.Point(([int](20*$k)), ([int](16*$k)))
    $lbl.AutoSize = $true
    $d.Controls.Add($lbl)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location      = New-Object System.Drawing.Point(([int](20*$k)), ([int](44*$k)))
    $lst.Size          = New-Object System.Drawing.Size(([int](380*$k)), ([int](82*$k)))
    $lst.IntegralHeight = $false
    $d.Controls.Add($lst)

    $ids = @()
    foreach ($id in $SkinIds) { [void]$lst.Items.Add($script:Skins[$id].Title); $ids += $id }
    [void]$lst.Items.Add('随机（每次开都不一样）'); $ids += 'random'

    $desc = New-Object System.Windows.Forms.Label
    $desc.Location  = New-Object System.Drawing.Point(([int](22*$k)), ([int](136*$k)))
    $desc.Size      = New-Object System.Drawing.Size(([int](376*$k)), ([int](74*$k)))
    $desc.ForeColor = [System.Drawing.Color]::DimGray
    $d.Controls.Add($desc)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text     = '屏保运行期间静音（退出还原）'
    $chk.Location = New-Object System.Drawing.Point(([int](20*$k)), ([int](216*$k)))
    $chk.Size     = New-Object System.Drawing.Size(([int](380*$k)), ([int](26*$k)))
    $chk.Checked  = [bool]$cur.mute
    $d.Controls.Add($chk)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text     = '开始'
    $ok.Location = New-Object System.Drawing.Point(([int](200*$k)), ([int](258*$k)))
    $ok.Size     = New-Object System.Drawing.Size(([int](95*$k)), ([int](32*$k)))
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cn = New-Object System.Windows.Forms.Button
    $cn.Text     = '取消'
    $cn.Location = New-Object System.Drawing.Point(([int](305*$k)), ([int](258*$k)))
    $cn.Size     = New-Object System.Drawing.Size(([int](95*$k)), ([int](32*$k)))
    $cn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $d.Controls.Add($ok); $d.Controls.Add($cn)
    $d.AcceptButton = $ok
    $d.CancelButton = $cn

    # 闭包里的 $script: 指向闭包自己的模块作用域，跟外面通不了气，
    # 所以描述文字要用的东西全在这儿先抓成局部变量。
    $skins = $script:Skins
    $lst.Add_SelectedIndexChanged({
        $i = $lst.SelectedIndex
        if ($i -lt 0) { return }
        $sid = $ids[$i]
        $desc.Text = if ($sid -eq 'random') { '每次启动从上面几张里随机挑一张。' } else { $skins[$sid].Desc }
    }.GetNewClosure())
    $lst.Add_DoubleClick({ $d.DialogResult = [System.Windows.Forms.DialogResult]::OK; $d.Close() }.GetNewClosure())

    $sel = [Array]::IndexOf($ids, [string]$cur.skin)
    if ($sel -lt 0) { $sel = 0 }
    $lst.SelectedIndex = $sel
    $d.Add_Shown({ $lst.Focus() }.GetNewClosure())

    $r = $d.ShowDialog()
    $out = $null
    if ($r -eq [System.Windows.Forms.DialogResult]::OK) {
        $i = $lst.SelectedIndex
        if ($i -lt 0) { $i = 0 }
        $out = @{ skin = $ids[$i]; mute = [bool]$chk.Checked }
    }
    $d.Dispose()
    $out
}

$settings = Get-SaverSettings
if ($Skin) {
    $want = $Skin.ToLower()
    if ($want -ne 'random' -and -not ($SkinIds -contains $want)) {
        [void][System.Windows.Forms.MessageBox]::Show("没有叫 $Skin 的皮肤。可用：$($SkinIds -join ', '), random", '屏保')
        exit 1
    }
    $settings.skin = $want
} elseif (-not $NoPicker) {
    $picked = Show-SkinPicker $settings
    if ($null -eq $picked) { $mutex.ReleaseMutex(); exit 0 }   # 取消 = 不启动
    $settings = $picked
    Save-SaverSettings $settings
}

$chosenId = if ($settings.skin -eq 'random') { $SkinIds[(Get-Random -Minimum 0 -Maximum $SkinIds.Count)] } else { [string]$settings.skin }
# 注意：变量不能叫 $script:Skin——那是上面 [string]$Skin 这个参数，
# 往里塞哈希表会被静默转成字符串 "System.Collections.Hashtable"，然后 & 调用就炸了。
$script:ActiveSkin = $script:Skins[$chosenId]

# ============================================================
#  窗口
# ============================================================
$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$W = $primary.Width
$H = $primary.Height
$scale = [Math]::Max(3, [int][Math]::Round($H / 190.0))
$rnd = New-Object System.Random

$script:Ctx = @{ W = $W; H = $H; Scale = $scale; Rnd = $rnd; UiK = $script:uiK; Dir = $ScriptDir }

try {
    $script:St = & $script:ActiveSkin.Init $script:Ctx
} catch {
    Write-Err 'skin' "$chosenId Init 失败：$($_.Exception.ToString())"
    [void][System.Windows.Forms.MessageBox]::Show("皮肤 $chosenId 启动失败，看 error.log。", '屏保')
    $mutex.ReleaseMutex()
    exit 1
}
$theme0 = & $script:ActiveSkin.Theme $script:Ctx $script:St

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'Manual'
$form.Bounds          = $primary
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.BackColor       = $theme0.Bg
$form.KeyPreview      = $true
$form.Text            = 'Saver'

$canvas = New-Object DinoCanvas
$canvas.Dock      = 'Fill'
$canvas.BackColor = $theme0.Bg
$form.Controls.Add($canvas)

$btnW = [int]($scale * 22); $btnH = [int]($scale * 7)
$btn  = New-Object System.Windows.Forms.Button
$btn.Text      = '关闭'
$btn.Size      = New-Object System.Drawing.Size($btnW, $btnH)
$btn.Location  = New-Object System.Drawing.Point(($W - $btnW - $scale * 5), ($H - $btnH - $scale * 5))
$btn.Anchor    = 'Bottom,Right'
$btn.FlatStyle = 'Flat'
$btn.Font      = New-Object System.Drawing.Font('Microsoft YaHei', [single]($scale * 2.0))
$btn.TabStop   = $false
$canvas.Controls.Add($btn)

$extraForms = @()
if ($CoverAllScreens) {
    foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) {
        if ($sc.Primary) { continue }
        $f = New-Object System.Windows.Forms.Form
        $f.FormBorderStyle = 'None'; $f.StartPosition = 'Manual'; $f.Bounds = $sc.Bounds
        $f.TopMost = $true; $f.ShowInTaskbar = $false; $f.BackColor = [System.Drawing.Color]::Black
        $extraForms += $f
    }
}

$script:authorized   = $false
$script:dialogOpen   = $false
$script:activeDlg    = $null
$script:tickN        = 0
$script:cursorHidden = $false
$script:lastMove     = [Environment]::TickCount

# ============================================================
#  密码对话框
# ============================================================
function Show-PasswordDialog {
    $k = $script:uiK
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = '解锁屏保'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.MaximizeBox     = $false; $dlg.MinimizeBox = $false
    $dlg.ClientSize      = New-Object System.Drawing.Size(([int](360*$k)), ([int](170*$k)))
    $dlg.TopMost         = $true
    $dlg.ShowInTaskbar   = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = '请输入密码：'
    $lbl.Location = New-Object System.Drawing.Point(([int](20*$k)), ([int](18*$k)))
    $lbl.AutoSize = $true
    $dlg.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.UseSystemPasswordChar = $true
    $tb.Location = New-Object System.Drawing.Point(([int](20*$k)), ([int](46*$k)))
    $tb.Size     = New-Object System.Drawing.Size(([int](320*$k)), ([int](26*$k)))
    $dlg.Controls.Add($tb)

    $msg = New-Object System.Windows.Forms.Label
    $msg.Location  = New-Object System.Drawing.Point(([int](20*$k)), ([int](80*$k)))
    $msg.Size      = New-Object System.Drawing.Size(([int](320*$k)), ([int](24*$k)))
    $msg.ForeColor = [System.Drawing.Color]::Firebrick
    $dlg.Controls.Add($msg)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text     = '确定'
    $ok.Location = New-Object System.Drawing.Point(([int](170*$k)), ([int](120*$k)))
    $ok.Size     = New-Object System.Drawing.Size(([int](80*$k)), ([int](30*$k)))
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text     = '取消'
    $cancel.Location = New-Object System.Drawing.Point(([int](260*$k)), ([int](120*$k)))
    $cancel.Size     = New-Object System.Drawing.Size(([int](80*$k)), ([int](30*$k)))
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    # 忘记密码的退路：踢回系统锁屏
    $forgot = New-Object System.Windows.Forms.Button
    $forgot.Text      = '忘记密码…'
    $forgot.Location  = New-Object System.Drawing.Point(([int](20*$k)), ([int](120*$k)))
    $forgot.Size      = New-Object System.Drawing.Size(([int](110*$k)), ([int](30*$k)))
    $forgot.FlatStyle = 'Flat'
    $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel); $dlg.Controls.Add($forgot)
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    # 注意：这里的处理器必须用 GetNewClosure 才能抓住 $tb/$msg/$dlg 这些函数局部变量，
    # 但也正因为如此，闭包里的 $script: 指的是闭包自己的模块作用域，绝不能用来跟外面通信。
    # 结果一律通过 $dlg.DialogResult 回传。
    $expected = $script:PassHash
    $tries = 0
    $ok.Add_Click({
        if ((Get-StrHash $tb.Text) -eq $expected) {
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        } else {
            $tries++
            $tb.Clear()
            $msg.Text = "密码错误（第 $tries 次）"
            if (($tries % 3) -eq 0) {
                # 每错满 3 次锁一轮，时间递增：3 秒 → 10 秒 → 30 秒
                $round = [int]($tries / 3)
                $sec   = if ($round -le 1) { 3 } elseif ($round -eq 2) { 10 } else { 30 }
                $msg.Text = "连错 $tries 次，请等 $sec 秒…"
                $ok.Enabled = $false; $tb.Enabled = $false
                $t = New-Object System.Windows.Forms.Timer
                $t.Interval = $sec * 1000
                $t.Add_Tick({ $t.Stop(); $ok.Enabled = $true; $tb.Enabled = $true; $msg.Text = ''; $tb.Focus() }.GetNewClosure())
                $t.Start()
            }
        }
    }.GetNewClosure())

    $forgot.Add_Click({
        $mode = Show-PowerDialog
        if ($mode) {
            if (Invoke-SystemPower $mode) {
                $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK   # 让外层收尾，别挡住系统关机
                $dlg.Close()
            } else {
                $msg.Text = '关机命令没能执行'
            }
        }
    }.GetNewClosure())

    $dlg.Add_Shown({ $tb.Focus() }.GetNewClosure())
    $script:dialogOpen = $true
    $script:activeDlg  = $dlg
    $result = $dlg.ShowDialog($form)
    $script:activeDlg  = $null
    $script:dialogOpen = $false
    $dlg.Dispose()
    ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-PowerDialog {
    $k = $script:uiK
    $d = New-Object System.Windows.Forms.Form
    $d.Text            = '忘记密码'
    $d.FormBorderStyle = 'FixedDialog'
    $d.StartPosition   = 'CenterScreen'
    $d.MaximizeBox     = $false; $d.MinimizeBox = $false
    $d.ClientSize      = New-Object System.Drawing.Size(([int](420*$k)), ([int](200*$k)))
    $d.TopMost         = $true
    $d.ShowInTaskbar   = $false

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text     = "重启或关机后，用你的 Windows 账户密码登录就行，相当于把这道锁换成系统锁屏。"
    $l1.Location = New-Object System.Drawing.Point(([int](20*$k)), ([int](20*$k)))
    $l1.Size     = New-Object System.Drawing.Size(([int](380*$k)), ([int](56*$k)))
    $d.Controls.Add($l1)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text      = '注意：其他程序里没保存的东西会丢。'
    $l2.Location  = New-Object System.Drawing.Point(([int](20*$k)), ([int](86*$k)))
    $l2.Size      = New-Object System.Drawing.Size(([int](380*$k)), ([int](26*$k)))
    $l2.ForeColor = [System.Drawing.Color]::Firebrick
    $d.Controls.Add($l2)

    $br = New-Object System.Windows.Forms.Button
    $br.Text     = '重启'
    $br.Location = New-Object System.Drawing.Point(([int](20*$k)), ([int](140*$k)))
    $br.Size     = New-Object System.Drawing.Size(([int](110*$k)), ([int](34*$k)))
    $br.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $bs = New-Object System.Windows.Forms.Button
    $bs.Text     = '关机'
    $bs.Location = New-Object System.Drawing.Point(([int](145*$k)), ([int](140*$k)))
    $bs.Size     = New-Object System.Drawing.Size(([int](110*$k)), ([int](34*$k)))
    $bs.DialogResult = [System.Windows.Forms.DialogResult]::No
    $bc = New-Object System.Windows.Forms.Button
    $bc.Text     = '取消'
    $bc.Location = New-Object System.Drawing.Point(([int](290*$k)), ([int](140*$k)))
    $bc.Size     = New-Object System.Drawing.Size(([int](110*$k)), ([int](34*$k)))
    $bc.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $d.Controls.Add($br); $d.Controls.Add($bs); $d.Controls.Add($bc)
    $d.CancelButton = $bc
    $d.AcceptButton = $bc          # 误按回车 = 取消，不能是关机

    $r = $d.ShowDialog()
    $d.Dispose()
    if     ($r -eq [System.Windows.Forms.DialogResult]::Yes) { 'restart' }
    elseif ($r -eq [System.Windows.Forms.DialogResult]::No)  { 'shutdown' }
    else   { $null }
}

# 真去关机/重启。成功才返回 $true——失败必须留在锁定状态，不然「重启失败」就成了绕过密码的后门
function Invoke-SystemPower([string]$mode) {
    $argline = if ($mode -eq 'restart') { '/r /t 0' } else { '/s /t 0' }
    try {
        $p = Start-Process -FilePath 'shutdown.exe' -ArgumentList $argline -WindowStyle Hidden -PassThru -Wait
        if ($p.ExitCode -ne 0) { Write-Err 'power' "shutdown.exe 退出码 $($p.ExitCode)"; return $false }
    } catch {
        Write-Err 'power' $_.Exception.ToString()
        return $false
    }
    # 系统开始关机了：自己先解除所有拦截，别把关机流程卡住，
    # 也别把手势设置和静音留在被改过的状态
    $script:authorized = $true
    if ($BlockHotkeys) { [KeyBlocker]::Uninstall() }
    Restore-TouchpadGestures
    Stop-AudioTakeover
    [void][DinoNative]::SetThreadExecutionState($ES_CONTINUOUS)
    $true
}

# 「显示桌面」不会最小化我们，但会把任务栏抬到我们上面；三指左右滑还会整个切走虚拟桌面。
# 这个守卫每几帧跑一次，把这两种情况都按回去。SWP_NOACTIVATE 保证不抢焦点。
function Assert-Cover {
    $HWND_TOPMOST = [IntPtr](-1)
    $SWP = [uint32](0x0001 -bor 0x0002 -bor 0x0010)   # NOSIZE | NOMOVE | NOACTIVATE
    [void][DinoNative]::SetWindowPos($form.Handle, $HWND_TOPMOST, 0, 0, 0, 0, $SWP)
    foreach ($f in $extraForms) { [void][DinoNative]::SetWindowPos($f.Handle, $HWND_TOPMOST, 0, 0, 0, 0, $SWP) }
    # 密码框是 form 的子窗口，要跟着一起提，别被自己的主窗口盖住
    if ($script:activeDlg -and $script:activeDlg.IsHandleCreated) {
        [void][DinoNative]::SetWindowPos($script:activeDlg.Handle, $HWND_TOPMOST, 0, 0, 0, 0, $SWP)
    }
    if ($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Normal) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.Bounds = $primary
    }
    # 焦点掉到桌面/任务栏上就拿回来，否则 Esc 叫不出密码框。
    # 只针对外壳，不碰任务管理器——那是万一出事时的退路。
    if (-not $script:dialogOpen -and [DinoNative]::ShellHasFocus()) {
        [void][DinoNative]::SetForegroundWindow($form.Handle)
    }
    if (-not [VDesk]::OnCurrent($form.Handle)) { Move-ToCurrentDesktop }
}

# 新建的窗口必然落在当前虚拟桌面上，拿它当探针问出桌面 GUID，再把自己挪过去
function Move-ToCurrentDesktop {
    $probe = $null
    try {
        $probe = New-Object NoFocusForm
        $probe.FormBorderStyle = 'None'
        $probe.ShowInTaskbar   = $false
        $probe.StartPosition   = 'Manual'
        $probe.Size            = New-Object System.Drawing.Size(1, 1)
        $probe.Location        = New-Object System.Drawing.Point(-32000, -32000)
        $probe.Show()
        [void][VDesk]::MoveHere($form.Handle, $probe.Handle)
        foreach ($f in $extraForms) { [void][VDesk]::MoveHere($f.Handle, $probe.Handle) }
    } catch {
        Write-Err 'vdesk' $_.Exception.ToString()
    } finally {
        if ($probe) { $probe.Close(); $probe.Dispose() }
    }
}

function Close-Saver {
    $script:authorized = $true
    $script:timer.Stop()
    if ($BlockHotkeys) { [KeyBlocker]::Uninstall() }
    if ($script:cursorHidden) { [System.Windows.Forms.Cursor]::Show(); $script:cursorHidden = $false }
    if ($script:ActiveSkin.Close) {
        try { & $script:ActiveSkin.Close $script:Ctx $script:St } catch { Write-Err 'skin' $_.Exception.ToString() }
    }
    foreach ($f in $extraForms) { $f.Close() }
    $form.Close()
}

# ============================================================
#  事件
# ============================================================
# 这些处理器一律不用 GetNewClosure：脚本作用域的 $script: 和 $form/$btn 才能正常访问
$canvas.Add_Paint({
    param($s, $e)
    try { & $script:ActiveSkin.Draw $script:Ctx $script:St $e.Graphics } catch { Write-Err 'paint' $_.Exception.ToString() }
})

$onMove = {
    $script:lastMove = [Environment]::TickCount
    if ($script:cursorHidden) { [System.Windows.Forms.Cursor]::Show(); $script:cursorHidden = $false }
}
$canvas.Add_MouseMove($onMove)
$form.Add_MouseMove($onMove)
$btn.Add_MouseMove($onMove)

$btn.Add_Click({
    try { if (Show-PasswordDialog) { Close-Saver } } catch { Write-Err 'click' $_.Exception.ToString() }
})

$form.Add_KeyDown({
    param($s, $e)
    try {
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $e.Handled = $true; $e.SuppressKeyPress = $true
            if (-not $script:dialogOpen) { if (Show-PasswordDialog) { Close-Saver } }
        }
    } catch { Write-Err 'key' $_.Exception.ToString() }
})

$form.Add_FormClosing({
    param($s, $e)
    # 系统关机/注销时必须放行，否则我们自己会把关机流程卡住
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown) { return }
    if (-not $script:authorized) { $e.Cancel = $true }
})

# ---------- 主循环 ----------
$ES_CONTINUOUS = [uint32]2147483648
$ES_SYSTEM     = [uint32]1
$ES_DISPLAY    = [uint32]2
if ([DinoNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM -bor $ES_DISPLAY) -eq 0) {
    Write-Err 'power' 'SetThreadExecutionState 失败，屏幕可能仍会自动息屏'
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 30   # WinForms 定时器精度约 15.6ms，30 会落到 31.2ms(≈32fps)，写 33 反而掉到 21fps
$script:timer.Add_Tick({
  try {
    # 这个守卫必须在 dialogOpen 的提前返回之前，否则密码框开着时手势照样能扒开。
    # 用独立计数器：皮肤自己的帧号在密码框打开期间是不走的。
    $script:tickN++
    if (($script:tickN % 5) -eq 0) { Assert-Cover }
    if ($script:dialogOpen) { return }

    & $script:ActiveSkin.Update $script:Ctx $script:St
    $canvas.Invalidate()

    # 「关闭」按钮跟着皮肤当前配色走（小恐龙昼夜切换、字母雨常黑）
    $th = & $script:ActiveSkin.Theme $script:Ctx $script:St
    if ($btn.BackColor -ne $th.Bg) {
        $btn.BackColor = $th.Bg; $btn.ForeColor = $th.Fg
        $btn.FlatAppearance.BorderColor = $th.Fg
        $canvas.BackColor = $th.Bg
    }

    if (($script:tickN % 15) -eq 0 -and $ForceFocus -and [System.Windows.Forms.Form]::ActiveForm -ne $form) {
        [void][DinoNative]::SetForegroundWindow($form.Handle)
    }
    if (($script:tickN % 900) -eq 0) {
        [void][DinoNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM -bor $ES_DISPLAY)
    }
    if (-not $script:cursorHidden -and ([Environment]::TickCount - $script:lastMove) -gt $IdleHideCursorMs) {
        [System.Windows.Forms.Cursor]::Hide(); $script:cursorHidden = $true
    }
  } catch { Write-Err 'tick' $_.Exception.ToString() }
})

$btn.BackColor = $theme0.Bg
$btn.ForeColor = $theme0.Fg
$btn.FlatAppearance.BorderColor = $theme0.Fg

foreach ($f in $extraForms) { $f.Show() }
$form.Show()
$form.Activate()

# 键盘钩子要装在消息循环所在的这个线程上
if ($BlockHotkeys) {
    if (-not [KeyBlocker]::Install()) { Write-Err 'hook' '键盘钩子装不上，Win/Alt+Tab 不会被拦截' }
}
if (-not [VDesk]::Init()) { Write-Err 'vdesk' '虚拟桌面接口拿不到，切桌面不会被跟随' }
if ($BlockGestures) { Disable-TouchpadGestures }
if ($settings.mute)  { Start-AudioTakeover }

$script:timer.Start()

# 预览模式：到点自己走正常退出流程（钩子、手势、静音一样都会还原）。
# 它只管自己这个实例——屏保已经在跑的时候再启一个会被互斥体挡掉，
# 所以这个开关不构成绕过密码的路子。
if ($TestRun -gt 0) {
    $script:testTimer = New-Object System.Windows.Forms.Timer
    $script:testTimer.Interval = $TestRun * 1000
    $script:testTimer.Add_Tick({
        $script:testTimer.Stop()
        try { Close-Saver } catch { Write-Err 'testrun' $_.Exception.ToString() }
    })
    $script:testTimer.Start()
}

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    $script:timer.Stop()
    [KeyBlocker]::Uninstall()
    Restore-TouchpadGestures
    Stop-AudioTakeover
    if ($script:cursorHidden) { [System.Windows.Forms.Cursor]::Show() }
    [void][DinoNative]::SetThreadExecutionState($ES_CONTINUOUS)
    $mutex.ReleaseMutex()
}
