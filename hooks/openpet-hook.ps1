# OpenPet bridge for Claude Code hooks.
# Two modes:
#   1) Hook mode (Claude Code calls this script): reads event JSON from stdin, maps to OpenPet events.
#   2) CLI mode (manual): openpet-hook.ps1 -EventType <...> [-Message "..."] [-TtlMs 6000]
# Sends a companion event to the local OpenPet runtime (http://127.0.0.1:17321).
# Designed to be fast and silent: 2s HTTP timeout, swallows errors so it never blocks the session.

param(
    [ValidateSet('thinking', 'tool-running', 'reviewing', 'success', 'failure', 'attention')]
    [string]$EventType,
    [string]$Message,
    [int]$TtlMs = 600000
)

$ErrorActionPreference = 'SilentlyContinue'

# ── debug logging (OPENPET_HOOK_DEBUG=1) ──────────────────────────────
$debugLogPath = $null
if ($env:OPENPET_HOOK_DEBUG -eq '1') {
    $debugLogPath = Join-Path $env:TEMP 'openpet-hook-debug.log'
}
function Write-DebugLog {
    param([string]$Msg)
    if ($debugLogPath) {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Add-Content -Path $debugLogPath -Value "[$ts] $Msg" -Encoding UTF8
    }
}

# ── helpers ──────────────────────────────────────────────────────────────

function Send-OpenPetEvent {
    param([string]$Type, [string]$Msg, [int]$Ttl = 600000)

    $body = @{ type = $Type }
    if ($Msg) { $body['message'] = $Msg }
    if ($Ttl -gt 0) { $body['ttlMs'] = $Ttl }

    $host_ = $env:CODEX_PET_RUNTIME_HOST
    if (-not $host_) { $host_ = '127.0.0.1' }
    $port = $env:CODEX_PET_RUNTIME_PORT
    if (-not $port) { $port = '17321' }
    $url = "http://${host_}:${port}/api/event"

    try {
        $json = $body | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        Invoke-RestMethod -Uri $url -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 2 | Out-Null
    }
    catch {
        exit 0
    }
}

function Truncate-Message {
    param([string]$Text, [int]$MaxLen = 120)
    if ($Text.Length -gt $MaxLen) {
        return $Text.Substring(0, $MaxLen - 3) + "..."
    }
    return $Text
}

# Win32 类型源：仅在 msgbox 场景惰性编译，避免拖慢纯气泡的 CLI 模式
$ccWin32Source = @"
using System;
using System.Runtime.InteropServices;
public class CCWin32 {
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FlashWindow(IntPtr hwnd, bool bInvert);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hwnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    public static void FlashForever(IntPtr hwnd) {
        FLASHWINFO fi = new FLASHWINFO();
        fi.cbSize = (uint)Marshal.SizeOf(fi);
        fi.hwnd = hwnd;
        fi.dwFlags = 3;  // FLASHW_ALL | FLASHW_TIMER
        fi.uCount = 0;   // 持续闪烁，直到窗口获得焦点或 FlashWindow(hwnd, false)
        fi.dwTimeout = 0;
        FlashWindowEx(ref fi);
    }

    public static void Focus(IntPtr hwnd) {
        ShowWindow(hwnd, 9);  // SW_RESTORE：最小化时先还原
        if (!SetForegroundWindow(hwnd)) {
            // 前台锁兜底：模拟按下/释放 Alt 键解除限制后重试
            keybd_event(0x12, 0, 0, UIntPtr.Zero);
            keybd_event(0x12, 0, 2, UIntPtr.Zero);
            SetForegroundWindow(hwnd);
        }
    }
}
"@

# WinForms 置顶弹窗类型源：TopMost Form（WS_EX_TOPMOST）保证弹窗持续浮于
# 所有普通窗口之上——即使点击其他应用也不会被覆盖，直到用户点击确定。
$topBoxSource = @"
using System;
using System.Drawing;
using System.Windows.Forms;

public class TopBox {
    public static int Show(string text, string caption, int iconType) {
        using (var f = new Form()) {
            f.Text = caption;
            f.StartPosition = FormStartPosition.CenterScreen;
            f.FormBorderStyle = FormBorderStyle.FixedDialog;
            f.MaximizeBox = false;
            f.MinimizeBox = false;
            f.ShowInTaskbar = false;
            f.TopMost = true;  // 持续置顶，点击其他应用时焦点可转移但窗口不被覆盖
            f.ClientSize = new Size(400, 140);

            var pic = new PictureBox {
                Location = new Point(16, 20),
                Size = new Size(32, 32),
                SizeMode = PictureBoxSizeMode.Zoom
            };
            switch (iconType) {
                case 16: pic.Image = SystemIcons.Error.ToBitmap(); break;
                case 32: pic.Image = SystemIcons.Question.ToBitmap(); break;
                case 48: pic.Image = SystemIcons.Warning.ToBitmap(); break;
                default: pic.Image = SystemIcons.Information.ToBitmap(); break;
            }
            f.Controls.Add(pic);

            var lbl = new Label {
                Text = text,
                Location = new Point(64, 14),
                AutoSize = true,
                MaximumSize = new Size(316, 0),
                Font = new Font("Microsoft YaHei UI", 9F)
            };
            f.Controls.Add(lbl);

            var btn = new Button {
                Text = "确定",
                DialogResult = DialogResult.OK,
                Size = new Size(88, 28),
                Location = new Point(156, 98)
            };
            f.Controls.Add(btn);
            f.AcceptButton = btn;
            f.CancelButton = btn;

            return f.ShowDialog() == DialogResult.OK ? 1 : 0;
        }
    }
}
"@

function Find-ConsoleWindow {
    # 沿父进程链向上找第一个有主窗口的进程（终端宿主窗口）
    # 链：hook powershell -> claude node -> shell -> conhost/OpenConsole/mintty/WindowsTerminal
    $current = $PID
    for ($i = 0; $i -lt 10; $i++) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $current" -ErrorAction SilentlyContinue
        if (-not $parent -or [int]$parent.ParentProcessId -le 0) { return [IntPtr]::Zero }
        $ppid = [int]$parent.ParentProcessId
        $proc = Get-Process -Id $ppid -ErrorAction SilentlyContinue
        if (-not $proc) { return [IntPtr]::Zero }
        if ($proc.MainWindowHandle -ne 0) { return [IntPtr]$proc.MainWindowHandle }
        $current = $ppid
    }
    return [IntPtr]::Zero
}

function Show-MsgBox {
    param([string]$Text, [string]$Title = "Claude Code", [int]$Seconds = 0, [int]$Icon = 64)
    # Seconds = 0 表示永久显示，直到用户点击确定（任务栏闪烁同步持续）
    try {
        if (-not ("CCWin32" -as [type])) {
            Add-Type -TypeDefinition $ccWin32Source -ErrorAction SilentlyContinue | Out-Null
        }

        # 弹窗前让对应终端窗口在任务栏持续闪烁
        $hwnd = [IntPtr]::Zero
        if ("CCWin32" -as [type]) {
            $hwnd = Find-ConsoleWindow
            if ($hwnd -ne [IntPtr]::Zero) {
                [CCWin32]::FlashForever($hwnd)
            }
        }

        # 持续置顶弹窗：WinForms TopMost Form（WS_EX_TOPMOST），
        # 点击其他应用也不会被覆盖，直到用户点击确定。
        # 返回值：确定 = 1（与 WScript Popup 的 OK 一致，后续 $result -eq 1 判断通用）
        # 注意：不支持超时自动关闭（当前所有调用均为永久显示，无影响）
        $result = $null
        if (-not ("TopBox" -as [type])) {
            # -TypeDefinition 编译不会自动引用 -AssemblyName 加载的程序集，
            # 必须通过 -ReferencedAssemblies 显式声明
            Add-Type -TypeDefinition $topBoxSource -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction SilentlyContinue | Out-Null
        }
        if ("TopBox" -as [type]) {
            $result = [TopBox]::Show($Text, $Title, $Icon)
        }
        else {
            # 兜底：WinForms 编译失败（如非交互会话）时退化为普通弹窗
            $shell = New-Object -ComObject WScript.Shell
            $result = $shell.Popup($Text, $Seconds, $Title, $Icon)
        }

        if ("CCWin32" -as [type] -and $hwnd -ne [IntPtr]::Zero) {
            [CCWin32]::FlashWindow($hwnd, $false) | Out-Null  # 停止闪烁
            if ($result -eq 1) {
                [CCWin32]::Focus($hwnd)  # 用户点击确定 → 跳转聚焦终端窗口
            }
        }
    }
    catch {
        # 非交互会话（无桌面）时静默忽略
    }
}

# ── CLI mode first (fast path, no stdin) ───────────────────────────────
# Settings.json hooks use -EventType/-Message/-TtlMs parameters.
# Process these FIRST to avoid any blocking from $input when stdin pipes
# are open but empty.

if ($EventType) {
    Write-DebugLog ("CLI mode: type=" + $EventType + " msg=" + $Message + " ttl=" + $TtlMs)
    $bubbleText = Truncate-Message -Text $Message
    Send-OpenPetEvent -Type $EventType -Msg $bubbleText -Ttl $TtlMs
    exit 0
}

# ── Hook mode (stdin): Claude Code pipes event JSON ────────────────────
# $input is PowerShell's pipeline enumerator — reads piped stdin correctly.
# [Console]::In reads the console buffer, NOT the pipe, so it returns empty
# when Claude Code forks this script and pipes JSON to it.

$rawStdin = $input | Out-String
Write-DebugLog ("stdin len=" + $rawStdin.Length + " content=" + $rawStdin.Substring(0, [Math]::Min(300, $rawStdin.Length)))

if ($rawStdin.Trim()) {
    try {
        $data = $rawStdin | ConvertFrom-Json
    }
    catch {
        Write-DebugLog ("ConvertFrom-Json FAILED: " + $_.Exception.Message)
        # Malformed input – bail silently.
        exit 0
    }

    $event = $data.hook_event_name
    $bubbleType = "thinking"
    $bubbleText = ""
    $ttl = 600000

    switch ($event) {
        "PreToolUse" {
            $bubbleType = "tool-running"
            $ttl = 600000
            $tool = $data.tool_name
            $toolInput = $data.tool_input

            switch ($tool) {
                "Bash" {
                    $cmd = if ($toolInput.command) { $toolInput.command } else { "" }
                    $bubbleText = "执行命令: $cmd"
                }
                "Read" {
                    $path = if ($toolInput.file_path) { Split-Path $toolInput.file_path -Leaf } else { "..." }
                    $bubbleText = "读取文件: $path"
                }
                "Write" {
                    $path = if ($toolInput.file_path) { Split-Path $toolInput.file_path -Leaf } else { "..." }
                    $bubbleText = "写入文件: $path"
                }
                "Edit" {
                    $path = if ($toolInput.file_path) { Split-Path $toolInput.file_path -Leaf } else { "..." }
                    $bubbleText = "编辑文件: $path"
                }
                "Glob" {
                    $bubbleText = "搜索文件: $($toolInput.pattern)"
                }
                "Grep" {
                    $bubbleText = "搜索内容: $($toolInput.pattern)"
                }
                "TaskCreate" {
                    $bubbleText = "创建任务: $($toolInput.subject)"
                }
                "TaskUpdate" {
                    $bubbleText = "更新任务状态"
                }
                "WebFetch" {
                    $bubbleText = "获取网页: $($toolInput.url)"
                }
                "WebSearch" {
                    $bubbleText = "搜索网络: $($toolInput.query)"
                }
                "Agent" {
                    $bubbleText = "启动子代理: $($toolInput.description)"
                }
                "EnterPlanMode" {
                    $bubbleText = "进入规划模式..."
                }
                default {
                    $bubbleText = "调用工具: $tool"
                }
            }
        }

        "PostToolUse" {
            $tool = $data.tool_name
            # Check for errors in tool_response
            $resp = $data.tool_response
            if ($resp -and $resp -is [string] -and $resp -match "error|Error|failed|Failed") {
                $bubbleType = "failure"
                $bubbleText = "$tool 执行出错"
                $ttl = 600000
            }
            else {
                $bubbleType = "success"
                $bubbleText = "$tool 完成"
                $ttl = 600000
            }
        }

        "Stop" {
            $bubbleType = "reviewing"
            $bubbleText = "Claude 已完成本轮回复"
            $ttl = 600000
        }

        "UserPromptSubmit" {
            $bubbleType = "thinking"
            $bubbleText = "收到输入，思考中..."
            $ttl = 600000
        }

        "Notification" {
            $bubbleType = "attention"
            $bubbleText = if ($data.message) { "通知：$($data.message)" } else { "收到通知" }
            $ttl = 600000
        }

        "PreCompact" {
            $bubbleType = "thinking"
            $bubbleText = "正在压缩上下文..."
            $ttl = 600000
        }

        "SessionStart" {
            $bubbleType = "attention"
            $bubbleText = "新会话开始"
            $ttl = 600000
        }

        "SessionEnd" {
            $bubbleType = "reviewing"
            $bubbleText = "会话结束"
            $ttl = 600000
        }

        "PostToolUseFailure" {
            $tool = $data.tool_name
            $bubbleType = "failure"
            $bubbleText = if ($tool) { "$tool 执行失败" } else { "工具执行失败" }
            $ttl = 600000
        }

        "StopFailure" {
            $bubbleType = "failure"
            $bubbleText = "Claude 响应出错"
            $ttl = 600000
        }

        "SubagentStop" {
            $bubbleType = "success"
            $bubbleText = "子代理完成"
            $ttl = 600000
        }

        "TaskCompleted" {
            $bubbleType = "success"
            $bubbleText = "后台任务完成"
            $ttl = 600000
        }

        default {
            $bubbleText = "事件: $event"
        }
    }

    # 先截断主体，再追加工作目录末级目录名，保证目录始终显示
    $bubbleText = Truncate-Message -Text $bubbleText -MaxLen 100

    $cwdLeaf = if ($data.cwd) { Split-Path $data.cwd -Leaf } else { $null }
    if ($cwdLeaf -and $bubbleText) {
        $bubbleText = "[$cwdLeaf] $bubbleText"
    }

    Write-DebugLog ("event=" + $event + " -> type=" + $bubbleType + " text=" + $bubbleText + " ttl=" + $ttl)
    Send-OpenPetEvent -Type $bubbleType -Msg $bubbleText -Ttl $ttl

    # 关键事件弹 msgbox（带超时自动关闭，无人值守时不残留）
    $msgboxPrefix = if ($cwdLeaf) { "[$cwdLeaf] " } else { "" }
    switch ($event) {
        "PermissionRequest" { Show-MsgBox -Text "$msgboxPrefix Claude Code 正在等待权限确认，请查看终端" -Icon 32 }
        "Stop"              { Show-MsgBox -Text "$msgboxPrefix Claude Code 任务已完成" -Icon 64 }
        "StopFailure"       { Show-MsgBox -Text "$msgboxPrefix Claude Code 响应出错" -Icon 16 }
    }
    exit 0
}

# Neither stdin nor params — nothing to do.
exit 0
