# Non-destructive disaster-recovery drill: fresh backups, restored into scratch containers,
# verified (row and point counts), restore time reported. Live data is never touched.
Set-Location (Split-Path $PSScriptRoot -Parent)
docker compose --profile vv run --rm vv python -u /vv/dr_drill.py
exit $LASTEXITCODE
