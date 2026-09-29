<#
.SYNOPSIS
  Fill imm-os-infra\.env with strong random values for the required secrets (Windows).

.DESCRIPTION
  PowerShell version of scripts/generate-secrets.sh. Works in Windows PowerShell 5.1
  and PowerShell 7.

  - Creates .env from .env.example if it doesn't exist.
  - Only fills a secret that is missing, empty or still the example placeholder;
    values you already set are never changed, so re-running is safe.
  - Restricts .env to your Windows user and prints the values each edge node needs.

.EXAMPLE
  cd imm-os-infra
  .\scripts\generate-secrets.ps1              # create/complete .env
  .\scripts\generate-secrets.ps1 -Webhook     # also set SLEEP_WEBHOOK_TOKEN

  If Windows blocks the script ("running scripts is disabled"), run it once with:
  powershell -ExecutionPolicy Bypass -File .\scripts\generate-secrets.ps1
#>
param([switch]$Webhook)

$ErrorActionPreference = 'Stop'
$infra = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $infra '.env'
$example = Join-Path $infra '.env.example'

$secrets = @('IMM_SERVICE_TOKEN', 'IMM_EDGE_CLIENT_SECRET', 'MQTT_EDGE_PASSWORD',
             'MQTT_ECLSS_PASSWORD', 'MQTT_INGEST_PASSWORD', 'MQTT_SIM_PASSWORD')
if ($Webhook) { $secrets += 'SLEEP_WEBHOOK_TOKEN' }

function New-Secret {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

if (-not (Test-Path $envFile)) {
    Copy-Item $example $envFile
    Write-Host 'Created .env from .env.example'
}

$lines = New-Object System.Collections.Generic.List[string]
foreach ($l in (Get-Content $envFile)) { $lines.Add($l) }

function Get-Index([string]$name) {
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].StartsWith("$name=")) { return $i }
    }
    return -1
}

foreach ($var in $secrets) {
    $idx = Get-Index $var
    $val = ''
    if ($idx -ge 0) { $val = $lines[$idx].Substring($var.Length + 1) }
    if ($val -and $val -notmatch '^(change-me|changeme|your-)') {
        Write-Host "kept      $var"
        continue
    }
    $new = New-Secret
    if ($idx -ge 0) { $lines[$idx] = "$var=$new" } else { $lines.Add("$var=$new") }
    Write-Host "generated $var"
}

# UTF-8 without BOM and LF line endings, which docker compose reads cleanly
$text = ($lines -join "`n") + "`n"
[System.IO.File]::WriteAllText($envFile, $text, (New-Object System.Text.UTF8Encoding $false))

# Only the current Windows user may read .env (the equivalent of chmod 600)
if ($env:OS -eq 'Windows_NT') {
    & icacls $envFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
}

$edgeSecret = $lines[(Get-Index 'IMM_EDGE_CLIENT_SECRET')].Split('=', 2)[1]
$mqttEdge = $lines[(Get-Index 'MQTT_EDGE_PASSWORD')].Split('=', 2)[1]
Write-Host ''
Write-Host 'Done. Values for /etc/imm-os/edge.env on each edge node:'
Write-Host "  IMM_EDGE_CLIENT_SECRET=$edgeSecret"
Write-Host "  MQTT_PASSWORD=$mqttEdge"
Write-Host ''
Write-Host 'Next: .\mosquitto\gen-certs.ps1 <this PC''s IP>, then: docker compose up -d'
Write-Host '(Keycloak reads IMM_EDGE_CLIENT_SECRET only when it first imports the realm.)'
