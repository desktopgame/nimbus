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

    # Native stderr is diagnostic output, not a PowerShell exception.
    $savedPreference = $ErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $ErrorActionPreference = "Continue"
        $Text | & $betterLeaks.Source stdin --redact *> $null
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    $exitCode = $LASTEXITCODE

    switch ($exitCode) {
        0 {
            return $false
        }

        1 {
            return $true
        }

        default {
            throw "betterleaks failed with exit code $exitCode."
        }
    }
}

$event = "Unknown"
try {
    # Hook JSON and scanner stdin use UTF-8, independent of the console code page.
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
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
                '(?i)(^|[\s\x27"=;|&(){}\[\]\\/])\.env($|[.\s''"\\/])',
                '(?i)(^|[\s\x27"=;|&(){}\[\]\\/])secrets?([\\/\s\x27";|&()]|$)',
                '(?i)\.(pem|p12|pfx|key)(?:\s|$|["''])',
                '(?i)(^|[\s\x27"=;|&(){}\[\]\\/])id_(rsa|dsa|ecdsa|ed25519)(?:\s|$|["''])'
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
}
catch {
    Block "Sensitive-canary could not complete the scan. Check the scanner installation and hook configuration." $event
}
