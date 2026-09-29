# Restore IMM-OS data from a backup (disaster recovery). REPLACES the live data.
#
#   .\scripts\restore.ps1 postgres [-File <backup>] [-Yes]   default: newest backups\postgres\imm_db-*.dump
#   .\scripts\restore.ps1 influx   [-File <backup>] [-Yes]   default: newest backups\influx\influx-*.tar.gz
#
# Same steps as scripts/restore.sh: checksum, safety backup, stop writers, restore,
# check row counts (Postgres), start everything. To practise without touching live
# data use the DR drill instead: .\scripts\dr-drill.ps1
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('postgres', 'influx')][string]$Kind,
    [string]$File,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

function EnvValue($name, $default) {
    $line = Get-Content .env -ErrorAction SilentlyContinue | Where-Object { $_ -match "^$name=" } | Select-Object -Last 1
    if ($line) { return $line.Substring($name.Length + 1) } else { return $default }
}
$dir = EnvValue 'BACKUP_DIR' '.\backups'
$pgUser = EnvValue 'POSTGRES_USER' 'admin'
$pgDb = EnvValue 'POSTGRES_DB' 'imm_db'
if ($Kind -eq 'postgres') {
    $pattern = 'imm_db-*.dump'; $db = 'postgres'
    $writers = 'keycloak eclss-api eva-api inventory-api comms-api scheduling-api medical-api psych-api mission-assistant auto-control ai-processor health-monitor telemetry-ingest backup-postgres'.Split(' ')
} else {
    $pattern = 'influx-*.tar.gz'; $db = 'influxdb'
    $writers = 'telemetry-processor telemetry-worker backup-influx'.Split(' ')
}
if (-not $File) {
    $newest = Get-ChildItem (Join-Path $dir $Kind) -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $newest) { throw "no $Kind backup found in $dir\$Kind" }
    $File = $newest.FullName
}
if (-not (Test-Path $File)) { throw "backup not found: $File" }
if (Test-Path "$File.sha256") {
    $want = (Get-Content "$File.sha256").Split(' ')[0]
    $have = (Get-FileHash $File -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $have) { throw "checksum MISMATCH: $File is damaged" }
    Write-Host "checksum ok: $File"
} else { Write-Warning "no checksum file for $File" }

Write-Host ""
Write-Host "This REPLACES the live $Kind data with $(Split-Path $File -Leaf) (taken $((Get-Item $File).LastWriteTime))."
Write-Host "Services stopped meanwhile: $($writers -join ', ')"
if (-not $Yes) {
    if ((Read-Host 'Type RESTORE to continue') -ne 'RESTORE') { Write-Host 'cancelled'; exit 1 }
}

Write-Host 'safety backup of the current data ...'
docker compose exec -T "backup-$Kind" /bin/sh /scripts/backup.sh $Kind once
if ($LASTEXITCODE -ne 0) { Write-Warning 'no safety backup (database or backup container down); continuing' }

Write-Host 'stopping writers ...'
docker compose stop @writers 2>$null | Out-Null
docker compose up -d $db | Out-Null
# copy, don't pipe: PowerShell pipes are text and would corrupt the binary backup
docker compose cp $File "${db}:/tmp/imm-restore" | Out-Null

if ($Kind -eq 'postgres') {
    docker compose exec -T postgres sh -c 'until pg_isready -U "$POSTGRES_USER" -q; do sleep 1; done; pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner /tmp/imm-restore; rc=$?; rm -f /tmp/imm-restore; exit $rc'
    if ($LASTEXITCODE -ne 0) { Write-Warning "pg_restore reported errors (often harmless 'does not exist' notes on a fresh database)" }
    if (Test-Path "$File.counts-after") {
        $sql = "SELECT table_name, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1"
        $now = docker compose exec -T postgres psql -U $pgUser -d $pgDb -At -F ' ' -c $sql
        $want = @{}; Get-Content "$File.counts-after" | ForEach-Object { $p = $_.Split(' '); if ($p.Count -eq 2) { $want[$p[0]] = $p[1] } }
        $bad = @($now | ForEach-Object { $p = $_.Split(' '); if ($p.Count -eq 2 -and $want.ContainsKey($p[0]) -and $want[$p[0]] -ne $p[1]) { $p[0] } })
        Write-Host "row counts: $($bad.Count) table(s) differ from the backup's record (0 expected)"
    }
} else {
    docker compose exec -T influxdb sh -c 'rm -rf /tmp/imm-r && mkdir /tmp/imm-r && tar xzf /tmp/imm-restore -C /tmp/imm-r && INFLUX_TOKEN="$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" influx restore --full /tmp/imm-r/*; rc=$?; rm -rf /tmp/imm-r /tmp/imm-restore; exit $rc'
    if ($LASTEXITCODE -ne 0) { throw 'influx restore failed' }
}

Write-Host 'starting everything ...'
docker compose up -d | Out-Null
Write-Host 'done. Check: docker compose ps   and the IMM-OS alarm panel.'
