[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'runtime-contract.psm1') -Force

$pipelineRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $pipelineRoot 'run\pipeline-state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "Pipeline state does not exist: $statePath"
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$records = @()
if ($null -ne $state.sidecar.listener) {
    $records += [pscustomobject]@{ name = 'sidecar-listener'; record = $state.sidecar.listener }
}
$records += [pscustomobject]@{ name = 'sidecar-launcher'; record = $state.sidecar }
$records += [pscustomobject]@{ name = 'koharu'; record = $state.koharu }
$seen = @{}
$verified = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $records) {
    $name = $entry.name
    $record = $entry.record
    if ($seen.ContainsKey([int]$record.pid)) { continue }
    $seen[[int]$record.pid] = $true
    $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { continue }
    if (-not (Test-RecordedProcessIdentity -Name $name -Record $record -Process $process)) {
        continue
    }
    $verified.Add($entry)
}

foreach ($entry in $verified) {
    $name = $entry.name
    $record = $entry.record
    $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { continue }
    if (-not (Test-RecordedProcessIdentity -Name $name -Record $record -Process $process)) {
        continue
    }
    Stop-Process -Id $process.Id
    Wait-Process -Id $process.Id -Timeout 15 -ErrorAction SilentlyContinue
    if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
        throw "$name PID $($process.Id) did not stop. State was retained."
    }
}

Remove-Item -LiteralPath $statePath
[pscustomobject]@{ status = 'stopped'; state_removed = $true } | ConvertTo-Json
