$ErrorActionPreference = 'Stop'

$desktopRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$systemRoot = (Resolve-Path (Join-Path $desktopRoot '..\..')).Path
$taskTemp = Join-Path $systemRoot 'server\tmp\tauri-bundle'
New-Item -ItemType Directory -Path $taskTemp -Force | Out-Null

# NSIS extracts its toolchain into the project's local cache. Both that cache
# and the temporary archive must be on the same Windows volume.
$env:TEMP = $taskTemp
$env:TMP = $taskTemp

Push-Location $desktopRoot
try {
    npm run build:server-sidecar
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    npm run tauri -- build
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
