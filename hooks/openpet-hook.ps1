# OpenPet bridge for Claude Code hooks.
# Usage: openpet-hook.ps1 -EventType <thinking|tool-running|reviewing|success|failure|attention> [-Message "..."] [-TtlMs 6000]
# Sends a companion event to the local OpenPet runtime (http://127.0.0.1:17321).
# Designed to be fast and silent: no python startup, 2s HTTP timeout, swallows errors so it never blocks the session.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('thinking', 'tool-running', 'reviewing', 'success', 'failure', 'attention')]
    [string]$EventType,
    [string]$Message,
    [int]$TtlMs = 6000
)

$ErrorActionPreference = 'SilentlyContinue'

$body = @{ type = $EventType }
if ($Message) { $body['message'] = $Message }
if ($TtlMs -gt 0) { $body['ttlMs'] = $TtlMs }

# Allow runtime host/port override via env (matches openpet-cli contract).
$host_ = $env:CODEX_PET_RUNTIME_HOST
if (-not $host_) { $host_ = '127.0.0.1' }
$port = $env:CODEX_PET_RUNTIME_PORT
if (-not $port) { $port = '17321' }
$url = "http://${host_}:${port}/api/event"

try {
    $json = $body | ConvertTo-Json -Compress
    # Explicitly UTF-8 encode the body as bytes; otherwise PS 5.1 mangles non-ASCII
    # (e.g. CJK) into '?' when sending a string body.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Uri $url -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 2 | Out-Null
}
catch {
    # Runtime not reachable: safe failure, do not disturb the session.
    exit 0
}
