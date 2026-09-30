$ErrorActionPreference = "Stop"

function Allow {
    Write-Output '{"continue":true}'
    exit 0
}

function Block([string]$Reason, [string]$Event) {
    if ($Event -eq "PreToolUse") {
        $result = @{
            continue = $false
            decision = "block"
            reason   = $Reason
            hookSpecificOutput = @{
                hookEventName = "PreToolUse"
                permissionDecision = "deny"
                permissionDecisionReason = $Reason
            }
        }
    }
    else {
        $result = @{
            continue = $false
            decision = "block"
            reason   = $Reason
        }
    }

    $result | ConvertTo-Json -Compress -Depth 8
    exit 0
}

function Invoke-BetterLeaks([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $betterLeaks = Get-Command betterleaks -ErrorAction SilentlyContinue
    if (-not $betterLeaks) {
        throw "betterleaks is not installed or is not on PATH."
    }

    # Keep the scanner's own output away from Codex.
    # We only care whether BetterLeaks reports findings.
    $temp = New-TemporaryFile

    try {
        $Text |
            & $betterLeaks.Source stdin `
                --report-path $temp.FullName `
                --report-format json `
                --redact *> $null

        if (-not (Test-Path $temp.FullName)) {
            return $false
        }

        $content = Get-Content $temp.FullName -Raw

        if ([string]::IsNullOrWhiteSpace($content)) {
            return $false
        }

        try {
            $report = $content | ConvertFrom-Json
        }
        catch {
            # Fail closed if BetterLeaks generated an unreadable report.
            throw "Could not parse BetterLeaks report."
        }

        # BetterLeaks' JSON report is expected to contain findings.
        if ($report -is [System.Array]) {
            return $report.Count -gt 0
        }

        # Be tolerant of a future object-shaped report.
        if ($null -ne $report.findings) {
            return @($report.findings).Count -gt 0
        }

        return $false
    }
    finally {
        Remove-Item $temp.FullName -Force -ErrorAction SilentlyContinue
    }
}

$raw = [Console]::In.ReadToEnd()

if ([string]::IsNullOrWhiteSpace($raw)) {
    Allow
}

try {
    $inputData = $raw | ConvertFrom-Json
}
catch {
    Block "Sensitive-canary could not parse Codex hook input." "Unknown"
}

$event = $inputData.hook_event_name

switch ($event) {
    "UserPromptSubmit" {
        $text = [string]$inputData.prompt

        if (Invoke-BetterLeaks $text) {
            Block "The submitted prompt appears to contain a secret. Remove or redact it before sending." $event
        }

        Allow
    }

    "PreToolUse" {
        # Currently this is mainly useful for shell-command hooks.
        $toolInputJson = $inputData.tool_input | ConvertTo-Json -Compress -Depth 20

        # Cheap path/name guard before doing the deeper scan.
        $sensitivePaths = @(
            '(?i)(^|[\\/])\.env($|[.\s''"\\/])',
            '(?i)(^|[\\/])secrets?([\\/]|$)',
            '(?i)\.(pem|p12|pfx|key)(?:\s|$|["''])',
            '(?i)(^|[\\/])id_(rsa|dsa|ecdsa|ed25519)(?:\s|$|["''])'
        )

        foreach ($pattern in $sensitivePaths) {
            if ($toolInputJson -match $pattern) {
                Block "Command references a sensitive credential file or secret path." $event
            }
        }

        if (Invoke-BetterLeaks $toolInputJson) {
            Block "Tool input appears to contain secret material." $event
        }

        Allow
    }

    default {
        Allow
    }
}