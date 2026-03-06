# peon-ping adapter for Kiro CLI (Amazon) (Windows)
# Translates Kiro hook events into peon.ps1 stdin JSON
#
# Kiro CLI has a hook system that pipes JSON to hooks via stdin,
# nearly identical to Claude Code. This adapter remaps the few
# differing event names and forwards to peon.sh.

# preToolUse triggers a background stall detector that plays a
# PermissionRequest sound if the kiro-cli DB doesn't update within
# PEON_STALL_TIMEOUT seconds (default: 30).
# - This heuristically detects permission prompts without being noisy
#   on auto-approved tools.

# Setup: Create ~/.kiro/agents/peon-ping.json with:
# {
#   "name": "peon-ping",
#   "description": "Audio notifications via peon-ping hooks.",
#   "hooks": {
#     "agentSpawn": [
#       { "command": "powershell -NoProfile -File %USERPROFILE%\\.claude\\hooks\\peon-ping\\adapters\\kiro.ps1" }
#     ],
#     "userPromptSubmit": [
#       { "command": "powershell -NoProfile -File %USERPROFILE%\\.claude\\hooks\\peon-ping\\adapters\\kiro.ps1" }
#     ],
#     "stop": [
#       { "command": "powershell -NoProfile -File %USERPROFILE%\\.claude\\hooks\\peon-ping\\adapters\\kiro.ps1" }
#     ],
#     "preToolUse": [
#       { "command": "powershell -NoProfile -File %USERPROFILE%\\.claude\\hooks\\peon-ping\\adapters\\kiro.ps1" }
#     ]
#   }
# }

# Tip: Desktop overlay notifications add ~10s latency to hooks.
#      Recommend: peon notifications off

$ErrorActionPreference = "SilentlyContinue"

$PeonDir = if ($env:CLAUDE_PEON_DIR) { $env:CLAUDE_PEON_DIR } else { Join-Path $env:USERPROFILE ".claude\hooks\peon-ping" }
$PeonScript = Join-Path $PeonDir "peon.ps1"
$StallTimeout = if ($env:PEON_STALL_TIMEOUT) { [int]$env:PEON_STALL_TIMEOUT } else { 30 }

if (-not (Test-Path $PeonScript)) { exit 0 }

# --- Find kiro-cli DB ---
function Find-KiroDb {
    if ($env:KIRO_DB -and (Test-Path $env:KIRO_DB)) { return $env:KIRO_DB }
    $db = Join-Path $env:APPDATA "kiro-cli\data.sqlite3"
    if (Test-Path $db) { return $db }
    $db = Join-Path $env:LOCALAPPDATA "kiro-cli\data.sqlite3"
    if (Test-Path $db) { return $db }
    return $null
}

# --- Read JSON from stdin ---
$inputJson = $null
try {
    if ([Console]::IsInputRedirected) {
        $stream = [Console]::OpenStandardInput()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
        $reader.Close()
        if ($raw) { $inputJson = $raw | ConvertFrom-Json }
    }
} catch {}

if (-not $inputJson) { exit 0 }

$hookEvent = $inputJson.hook_event_name
if (-not $hookEvent) { exit 0 }

# --- Event remap ---
# Note: session_id is kept raw (no prefix) so the stall detector can use it
# for lockfiles and DB lookups. The "kiro-" prefix is added when forwarding
# to peon.ps1, so peon can distinguish Kiro sessions from other IDEs.
$remap = @{
    "agentSpawn"        = "SessionStart"
    "userPromptSubmit"  = "UserPromptSubmit"
    "stop"              = "Stop"
    "preToolUse"        = "_StallWatch"
}

$mapped = $remap[$hookEvent]
if (-not $mapped) { exit 0 }

$sid = if ($inputJson.session_id) { $inputJson.session_id } else { "$PID" }
$cwd = if ($inputJson.cwd) { $inputJson.cwd } else { $PWD.Path }

if ($mapped -eq "_StallWatch") {
    # --- Stall detector (background job) ---
    $db = Find-KiroDb
    if (-not $db -or -not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) { exit 0 }

    # Spawn background stall watcher
    Start-Job -ScriptBlock {
        param($db, $cwd, $sid, $timeout, $peonDir)

        # Lockfile — only one watcher per session
        $lockfile = Join-Path $env:TEMP "kiro-stall-$sid.pid"
        if (Test-Path $lockfile) {
            $oldPid = Get-Content $lockfile -ErrorAction SilentlyContinue
            if ($oldPid) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }
        }
        $PID | Set-Content $lockfile -Force

        try {
            $initial = & sqlite3 $db "SELECT MAX(updated_at) FROM conversations_v2 WHERE key='$cwd';" 2>$null
            if (-not $initial) { return }

            $elapsed = 0
            while ($elapsed -lt $timeout) {
                Start-Sleep -Seconds 2
                $elapsed += 2
                $current = & sqlite3 $db "SELECT MAX(updated_at) FROM conversations_v2 WHERE key='$cwd';" 2>$null
                if ($current -ne $initial) { return }
            }

            # Stalled — play permission sound
            $payload = @{
                hook_event_name = "PermissionRequest"
                session_id      = "kiro-$sid"
                cwd             = $cwd
            } | ConvertTo-Json -Compress

            $peonScript = Join-Path $peonDir "peon.ps1"
            $payload | powershell -NoProfile -NonInteractive -File $peonScript 2>$null
        } finally {
            if ((Test-Path $lockfile) -and ((Get-Content $lockfile -ErrorAction SilentlyContinue) -eq $PID)) {
                Remove-Item $lockfile -Force -ErrorAction SilentlyContinue
            }
        }
    } -ArgumentList $db, $cwd, $sid, $StallTimeout, $PeonDir | Out-Null

} else {
    # --- Normal event — forward to peon.ps1 ---
    $payload = @{
        hook_event_name = $mapped
        notification_type = ""
        cwd             = $cwd
        session_id      = "kiro-$sid"
        permission_mode = if ($inputJson.permission_mode) { $inputJson.permission_mode } else { "" }
    } | ConvertTo-Json -Compress

    $payload | powershell -NoProfile -NonInteractive -File $PeonScript 2>$null
}

exit 0
