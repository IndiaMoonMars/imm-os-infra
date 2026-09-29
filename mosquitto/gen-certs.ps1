<#
.SYNOPSIS
  Create the private CA and TLS server certificate for the IMM-OS MQTT broker (Windows).

.DESCRIPTION
  PowerShell version of mosquitto/gen-certs.sh. Needs OpenSSL, found in this order:
    1. openssl on PATH
    2. the copy that ships with Git for Windows
    3. otherwise Docker Desktop: runs gen-certs.sh in a throwaway Alpine container

  The certificate is valid for imm.local, mosquitto and localhost plus any extra
  DNS names or IP addresses you pass (e.g. this PC's LAN IP from `ipconfig`).
  Edge nodes must connect using one of these names (MQTT_HOST).

  Output (mosquitto\certs\, git-ignored):
    ca.crt      copy to every edge node (MQTT_TLS_CA); not secret
    ca.key      keep private: only needed to issue new server certs
    server.crt / server.key   used by the broker

.EXAMPLE
  cd imm-os-infra
  .\mosquitto\gen-certs.ps1 192.168.1.100
  .\mosquitto\gen-certs.ps1 -Force 192.168.1.100 mcc.habitat.lan   # replace existing
#>
param(
    [switch]$Force,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Names = @()
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$out = Join-Path $here 'certs'

if ((Test-Path (Join-Path $out 'server.crt')) -and -not $Force) {
    Write-Host "$(Join-Path $out 'server.crt') already exists; use -Force to replace it" -ForegroundColor Red
    exit 1
}

function Find-OpenSsl {
    $cmd = Get-Command openssl -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if (-not $base) { continue }
        foreach ($rel in @('Git\usr\bin\openssl.exe', 'Git\mingw64\bin\openssl.exe')) {
            $p = Join-Path $base $rel
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

$openssl = Find-OpenSsl
if (-not $openssl) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host 'OpenSSL not found. Install Git for Windows (includes OpenSSL) or start Docker Desktop, then retry.' -ForegroundColor Red
        exit 1
    }
    Write-Host 'OpenSSL not found locally; generating inside a Docker container...'
    $argsList = @()
    if ($Force) { $argsList += '--force' }
    $argsList += $Names
    # tr strips CRLF in case the script was checked out with Windows line endings.
    # No double quotes in $cmd: Windows PowerShell 5.1 mangles them for native programs.
    $cmd = 'apk add --no-cache openssl >/dev/null && tr -d ''\015'' < gen-certs.sh > /tmp/gen-certs.sh && sh /tmp/gen-certs.sh $*'
    $ErrorActionPreference = 'Continue'
    & docker run --rm -v "${here}:/work" -w /work alpine:3 sh -c $cmd gen-certs @argsList
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    exit 0
}

New-Item -ItemType Directory -Force -Path $out | Out-Null

$san = 'DNS:imm.local,DNS:mosquitto,DNS:localhost,IP:127.0.0.1'
foreach ($n in $Names) {
    if ($n -match '^[0-9.]+$') { $san += ",IP:$n" } else { $san += ",DNS:$n" }
}

function Invoke-OpenSsl([string[]]$OpenSslArgs) {
    # openssl writes progress to stderr; Windows PowerShell 5.1 turns native stderr
    # into terminating errors under ErrorActionPreference=Stop, so capture it instead.
    $ErrorActionPreference = 'Continue'
    $log = & $openssl @OpenSslArgs 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        $log | Write-Host
        throw "openssl $($OpenSslArgs[0]) failed (exit $LASTEXITCODE)"
    }
}

$ca = Join-Path $out 'ca'
$srv = Join-Path $out 'server'
$ext = Join-Path $out 'server.ext'

Invoke-OpenSsl @('req', '-x509', '-newkey', 'rsa:4096', '-sha256', '-days', '3650', '-nodes',
    '-keyout', "$ca.key", '-out', "$ca.crt", '-subj', '/O=India Moon Mars/CN=IMM-OS MQTT CA',
    '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
Invoke-OpenSsl @('req', '-newkey', 'rsa:2048', '-sha256', '-nodes',
    '-keyout', "$srv.key", '-out', "$srv.csr", '-subj', '/O=India Moon Mars/CN=imm.local')
$extText = "basicConstraints=CA:FALSE`nkeyUsage=critical,digitalSignature,keyEncipherment`nextendedKeyUsage=serverAuth`nsubjectAltName=$san`n"
[System.IO.File]::WriteAllText($ext, $extText, (New-Object System.Text.UTF8Encoding $false))
Invoke-OpenSsl @('x509', '-req', '-in', "$srv.csr", '-CA', "$ca.crt", '-CAkey', "$ca.key",
    '-CAcreateserial', '-out', "$srv.crt", '-days', '825', '-sha256', '-extfile', $ext)
Remove-Item -Force -ErrorAction SilentlyContinue "$srv.csr", $ext, "$ca.srl"

# Private keys readable only by the current Windows user
if ($env:OS -eq 'Windows_NT') {
    foreach ($k in @("$ca.key", "$srv.key")) {
        & icacls $k /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    }
}

Write-Host "Created ca.crt, server.crt, server.key in $out (names: $san)"
Write-Host "Copy $(Join-Path $out 'ca.crt') to each edge node as /etc/imm-os/mqtt-ca.crt"
