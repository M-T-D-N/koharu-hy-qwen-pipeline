[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$QwenLifecycleScript,
    [string]$HyModelDirectory,
    [string]$QwenApi = 'http://127.0.0.1:8000/v1',
    [string]$QwenModel = 'dirk-qwen3.8-27b-q5',
    [string]$QwenLeasePath = '',
    [string]$PowerShellExecutable
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'runtime-contract.psm1') -Force

$pipelineRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $pipelineRoot 'run\pipeline-state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "Pipeline state does not exist: $statePath"
}
if (-not (Test-Path -LiteralPath $QwenLifecycleScript -PathType Leaf)) {
    throw "Qwen lifecycle script is missing: $QwenLifecycleScript"
}
$QwenLifecycleScript = (Resolve-Path -LiteralPath $QwenLifecycleScript).Path

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ([int]$state.schema_version -ge 2 -and $null -ne $state.runtime) {
    if (-not $PSBoundParameters.ContainsKey('QwenApi')) { $QwenApi = [string]$state.runtime.qwen_api }
    if (-not $PSBoundParameters.ContainsKey('QwenModel')) { $QwenModel = [string]$state.runtime.qwen_model }
    if (-not $PSBoundParameters.ContainsKey('QwenLeasePath')) { $QwenLeasePath = [string]$state.runtime.qwen_lease_path }
    if (-not $PSBoundParameters.ContainsKey('PowerShellExecutable')) { $PowerShellExecutable = [string]$state.runtime.powershell_executable }
}
if ([string]::IsNullOrWhiteSpace($HyModelDirectory) -and $null -ne $state.sidecar.PSObject.Properties['hy_model_directory']) {
    $HyModelDirectory = [string]$state.sidecar.hy_model_directory
}
if ([string]::IsNullOrWhiteSpace($HyModelDirectory) -or -not (Test-Path -LiteralPath $HyModelDirectory -PathType Container)) {
    throw "Hy-MT2 model directory is missing: $HyModelDirectory"
}
$HyModelDirectory = (Resolve-Path -LiteralPath $HyModelDirectory).Path
[void](Test-PinnedModelLayout -ModelDirectory $HyModelDirectory -LockPath (Join-Path $pipelineRoot 'config\model-lock.json'))
$QwenApi = (Assert-LocalHttpUrl -Value $QwenApi -Name 'Qwen API').AbsoluteUri.TrimEnd('/')
if ([string]::IsNullOrWhiteSpace($QwenLeasePath)) { throw 'Qwen lease path is missing from the recorded runtime.' }
$QwenLeasePath = [IO.Path]::GetFullPath($QwenLeasePath)
if (-not (Test-Path -LiteralPath (Split-Path -Parent $QwenLeasePath) -PathType Container)) {
    throw "Qwen lease directory is missing: $QwenLeasePath"
}
if ((Test-Path -LiteralPath $QwenLeasePath) -and (Test-Path -LiteralPath $QwenLeasePath -PathType Container)) {
    throw "Qwen lease path is a directory: $QwenLeasePath"
}
if ([string]::IsNullOrWhiteSpace($PowerShellExecutable)) { $PowerShellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path }
if (-not (Test-Path -LiteralPath $PowerShellExecutable -PathType Leaf)) {
    throw "PowerShell executable is missing: $PowerShellExecutable"
}
$PowerShellExecutable = (Resolve-Path -LiteralPath $PowerShellExecutable).Path
$runtimeStatus = & $QwenLifecycleScript -Operation status -Summary | ConvertFrom-Json
[void](Assert-LocalQwenStatus -Status $runtimeStatus -ExpectedModel $QwenModel)
$koharuApi = if ([int]$state.schema_version -ge 2 -and $state.runtime.koharu_api) {
    [string]$state.runtime.koharu_api
}
else {
    ([string]$state.koharu.url).TrimEnd('/') + '/api/v1'
}
$fontCatalog = Invoke-RestMethod -Uri "$koharuApi/fonts" -TimeoutSec 30
[void](Test-KoharuFontPolicy -PolicyPath (Join-Path $pipelineRoot 'config\translation-policy.json') -FontCatalog $fontCatalog)

function Set-StateProperty {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Value
    )

    $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Write-PipelineState {
    param([Parameter(Mandatory)][object]$Value)

    $temporaryState = "$statePath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryState -Encoding utf8NoBOM
        Move-Item -LiteralPath $temporaryState -Destination $statePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryState -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryState -Force
        }
    }
}

function Stop-ExactRecordedProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object]$Record
    )

    $process = Get-Process -Id ([int]$Record.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return }
    if (-not (Test-RecordedProcessIdentity -Name $Name -Record $Record -Process $process)) { return }
    Stop-Process -Id $process.Id
    Wait-Process -Id $process.Id -Timeout 15 -ErrorAction SilentlyContinue
    if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
        throw "$Name PID $($process.Id) did not stop."
    }
}

$sidecarExecutable = [string]$state.sidecar.path
$sidecarPort = [int]$state.sidecar.listener.port
$records = @()
if ($null -ne $state.sidecar.listener) {
    $records += [pscustomobject]@{ name = 'sidecar-listener'; record = $state.sidecar.listener }
}
$records += [pscustomobject]@{ name = 'sidecar-launcher'; record = $state.sidecar }
$seen = @{}
$verifiedOldRecords = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $records) {
    $record = $entry.record
    if ($seen.ContainsKey([int]$record.pid)) { continue }
    $seen[[int]$record.pid] = $true
    $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { continue }
    if (Test-RecordedProcessIdentity -Name $entry.name -Record $record -Process $process) {
        $verifiedOldRecords.Add($entry)
    }
}
$oldStopErrors = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $verifiedOldRecords) {
    try { Stop-ExactRecordedProcess -Name $entry.name -Record $entry.record }
    catch { $oldStopErrors.Add($_.Exception.Message); break }
}
if ($oldStopErrors.Count -gt 0) {
    $oldStopError = 'Existing sidecar shutdown was incomplete: ' + ($oldStopErrors -join ' ')
    Set-StateProperty -InputObject $state -Name 'sidecar_status' -Value 'restart_failed_cleanup_required'
    Set-StateProperty -InputObject $state -Name 'sidecar_restart_error' -Value $oldStopError
    Write-PipelineState -Value $state
    throw $oldStopError
}

Set-StateProperty -InputObject $state -Name 'sidecar_status' -Value 'stopped'
Set-StateProperty -InputObject $state -Name 'sidecar_restart_error' -Value $null
Write-PipelineState -Value $state

$sidecarOut = Join-Path $pipelineRoot 'run\sidecar.stdout.log'
$sidecarErr = Join-Path $pipelineRoot 'run\sidecar.stderr.log'
$sidecarArgs = @('-m', 'service.server', '--host', '127.0.0.1', '--port', [string]$sidecarPort)
$env:KOHARU_QWEN_LIFECYCLE_SCRIPT = $QwenLifecycleScript
$env:KOHARU_QWEN_API = $QwenApi
$env:KOHARU_QWEN_MODEL = $QwenModel
$env:KOHARU_QWEN_LEASE_PATH = $QwenLeasePath
$env:KOHARU_PWSH_EXECUTABLE = $PowerShellExecutable
$env:KOHARU_SPECIALIST_PYTHON = [string]$state.sidecar.path
$env:KOHARU_HY_MODEL_PATH = $HyModelDirectory
$env:KOHARU_API = $koharuApi
$sidecar = $null
$sidecarIdentity = $null
$listenerIdentity = $null
$listenerOwnershipConfirmed = $false
$newOwnedRecords = [System.Collections.Generic.List[object]]::new()
$spawned = $false
$ready = $false
try {
    $sidecar = Start-Process -FilePath $sidecarExecutable -ArgumentList $sidecarArgs -WorkingDirectory $pipelineRoot -WindowStyle Hidden -RedirectStandardOutput $sidecarOut -RedirectStandardError $sidecarErr -PassThru
    $spawned = $true
    $sidecarIdentity = Get-RecordedProcessIdentity -Process $sidecar
    $newOwnedRecords.Add([pscustomobject]@{ name = 'sidecar-launcher'; record = $sidecarIdentity })

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if ($sidecar.HasExited) { throw "Translation sidecar exited during startup. See $sidecarErr" }
        try {
            $health = Invoke-RestMethod "http://127.0.0.1:$sidecarPort/health" -TimeoutSec 2
            if ($health.status -eq 'ok') { $ready = $true; break }
        }
        catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw 'Translation sidecar did not become ready.' }

    $sidecar.Refresh()
    $listener = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $sidecarPort -State Listen -ErrorAction Stop | Select-Object -First 1
    $runtime = Get-Process -Id ([int]$listener.OwningProcess) -ErrorAction Stop
    $listenerIdentity = Get-RecordedProcessIdentity -Process $runtime
    $null = Assert-OwnedProcessListener -LauncherIdentity $sidecarIdentity -ListenerIdentity $listenerIdentity
    $listenerOwnershipConfirmed = $true
    if ([int]$listenerIdentity.pid -ne [int]$sidecarIdentity.pid) {
        $newOwnedRecords.Add([pscustomobject]@{ name = 'sidecar-listener'; record = $listenerIdentity })
    }

    $sidecarIdentity['arguments'] = $sidecarArgs
    $sidecarIdentity['url'] = "http://127.0.0.1:$sidecarPort/v1"
    $sidecarIdentity['hy_model_directory'] = $HyModelDirectory
    $listenerIdentity['port'] = $sidecarPort
    $sidecarIdentity['listener'] = $listenerIdentity
    $state.sidecar = [pscustomobject]$sidecarIdentity
    if ([int]$state.schema_version -ge 2 -and $null -ne $state.runtime) {
        $state.runtime.qwen_api = $QwenApi.TrimEnd('/')
        $state.runtime.qwen_model = $QwenModel
        $state.runtime.qwen_lease_path = $(if ([string]::IsNullOrWhiteSpace($QwenLeasePath)) { $null } else { [IO.Path]::GetFullPath($QwenLeasePath) })
        $state.runtime.powershell_executable = $PowerShellExecutable
    }
    Set-StateProperty -InputObject $state -Name 'sidecar_status' -Value 'running'
    Set-StateProperty -InputObject $state -Name 'sidecar_restart_error' -Value $null
    Write-PipelineState -Value $state
}
catch {
    $restartError = $_.Exception.Message
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
    if ($ready -and -not $listenerOwnershipConfirmed) {
        $cleanupErrors.Add('A ready listener was observed but its exact ownership could not be confirmed; it was not stopped automatically.')
    }
    for ($index = $newOwnedRecords.Count - 1; $index -ge 0; $index--) {
        try {
            Stop-ExactRecordedProcess -Name $newOwnedRecords[$index].name -Record $newOwnedRecords[$index].record
        }
        catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    if ($spawned -and $newOwnedRecords.Count -eq 0) {
        $cleanupErrors.Add('The replacement sidecar started before an exact process identity could be recorded; it was not stopped automatically.')
    }
    $combinedError = $restartError
    if ($cleanupErrors.Count -gt 0) { $combinedError += ' Cleanup: ' + ($cleanupErrors -join ' ') }
    Set-StateProperty -InputObject $state -Name 'sidecar_status' -Value $(if ($cleanupErrors.Count -eq 0) { 'stopped' } else { 'restart_failed_cleanup_required' })
    Set-StateProperty -InputObject $state -Name 'sidecar_restart_error' -Value $combinedError
    try { Write-PipelineState -Value $state }
    catch { $combinedError += " State update failed: $($_.Exception.Message)" }
    throw "Translation sidecar restart failed: $combinedError"
}

[pscustomobject]@{ status = 'restarted'; sidecar = $state.sidecar; koharu = $state.koharu } | ConvertTo-Json -Depth 20
