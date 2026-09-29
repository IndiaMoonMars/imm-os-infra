# Mission readiness test (fault injection V&V), see vv\README.md. Options: --quick, --no-disruptive, --only ID,...
Set-Location (Split-Path $PSScriptRoot -Parent)
docker compose --profile vv run --rm vv python -u /vv/mission_readiness.py @args
exit $LASTEXITCODE
