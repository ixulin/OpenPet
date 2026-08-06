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
    [int]$TtlMs = 6000
)

$ErrorActionPreference = 'SilentlyContinue'

# ── helpers ──────────────────────────────────────────────────────────────

function Send-OpenPetEvent {
    param([string]$Type, [string]$Msg, [int]$Ttl = 6000)

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

# ── try stdin first (hook mode) ─────────────────────────────────────────
# $input is PowerShell's pipeline enumerator — reads piped stdin correctly.
# [Console]::In reads the console buffer, NOT the pipe, so it returns empty
# when Claude Code forks this script and pipes JSON to it.

$rawStdin = $input | Out-String

if ($rawStdin.Trim()) {
    # ── Hook mode: Claude Code passed us event JSON via stdin ────────────
    try {
        $data = $rawStdin | ConvertFrom-Json
    }
    catch {
        # Malformed input – bail silently.
        exit 0
    }

    $event = $data.hook_event_name
    $bubbleType = "thinking"
    $bubbleText = ""
    $ttl = 6000

    switch ($event) {
        "PreToolUse" {
            $bubbleType = "tool-running"
            $ttl = 10000
            $tool = $data.tool_name
            $input = $data.tool_input

            switch ($tool) {
                "Bash" {
                    $cmd = if ($input.command) { $input.command } else { "" }
                    $bubbleText = "执行命令: $cmd"
                }
                "Read" {
                    $path = if ($input.file_path) { Split-Path $input.file_path -Leaf } else { "..." }
                    $bubbleText = "读取文件: $path"
                }
                "Write" {
                    $path = if ($input.file_path) { Split-Path $input.file_path -Leaf } else { "..." }
                    $bubbleText = "写入文件: $path"
                }
                "Edit" {
                    $path = if ($input.file_path) { Split-Path $input.file_path -Leaf } else { "..." }
                    $bubbleText = "编辑文件: $path"
                }
                "Glob" {
                    $bubbleText = "搜索文件: $($input.pattern)"
                }
                "Grep" {
                    $bubbleText = "搜索内容: $($input.pattern)"
                }
                "TaskCreate" {
                    $bubbleText = "创建任务: $($input.subject)"
                }
                "TaskUpdate" {
                    $bubbleText = "更新任务状态"
                }
                "WebFetch" {
                    $bubbleText = "获取网页: $($input.url)"
                }
                "WebSearch" {
                    $bubbleText = "搜索网络: $($input.query)"
                }
                "Agent" {
                    $bubbleText = "启动子代理: $($input.description)"
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
                $ttl = 8000
            }
            else {
                $bubbleType = "success"
                $bubbleText = "$tool 完成"
                $ttl = 4000
            }
        }

        "Stop" {
            $bubbleType = "reviewing"
            $bubbleText = "Claude 已完成本轮回复"
            $ttl = 5000
        }

        "UserPromptSubmit" {
            $bubbleType = "thinking"
            $bubbleText = "收到输入，思考中..."
            $ttl = 4000
        }

        "Notification" {
            $bubbleType = "attention"
            $bubbleText = if ($data.message) { $data.message } else { "收到通知" }
            $ttl = 8000
        }

        "PreCompact" {
            $bubbleType = "thinking"
            $bubbleText = "正在压缩上下文..."
            $ttl = 4000
        }

        "SessionStart" {
            $bubbleType = "attention"
            $bubbleText = "新会话开始"
            $ttl = 4000
        }

        "SessionEnd" {
            $bubbleType = "reviewing"
            $bubbleText = "会话结束"
            $ttl = 4000
        }

        default {
            $bubbleText = "事件: $event"
        }
    }

    $bubbleText = Truncate-Message -Text $bubbleText
    Send-OpenPetEvent -Type $bubbleType -Msg $bubbleText -Ttl $ttl
    exit 0
}

# ── CLI mode (no stdin): use explicit parameters ────────────────────────

if (-not $EventType) {
    # Neither stdin nor params — nothing to do.
    exit 0
}

Send-OpenPetEvent -Type $EventType -Msg $Message -Ttl $TtlMs
