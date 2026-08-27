[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$KoharuPort = 4010,
    [ValidateRange(1, 65535)]
    [int]$ServicePort = 4020,
    [ValidateRange(5, 300)]
    [int]$SidecarReadyTimeoutSeconds = 30,
    [ValidateRange(10, 600)]
    [int]$KoharuReadyTimeoutSeconds = 180,
    [Parameter(Mandatory = $true)]
    [string]$QwenLifecycleScript,
    [string]$KoharuExecutable,
    [string]$PythonExecutable,
    [Parameter(Mandatory = $true)]
    [string]$HyModelDirectory,
    [string]$DataDirectory,
    [string]$QwenApi = 'http://127.0.0.1:8000/v1',
    [string]$QwenModel = 'dirk-qwen3.8-27b-q5',
    [Parameter(Mandatory = $true)]
    [string]$QwenLeasePath,
    [string]$PowerShellExecutable,
    [scriptblock]$OnProgress
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'runtime-contract.psm1') -Force

function Write-StartupProgress {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][int]$Completed,
        [Parameter(Mandatory)][string]$Detail
    )
    if ($OnProgress) {
        & $OnProgress ([pscustomobject]@{ phase = $Phase; completed = $Completed; total = 6; detail = $Detail })
    }
}

$pipelineRoot = Split-Path -Parent $PSScriptRoot
$runRoot = Join-Path $pipelineRoot 'run'
$statePath = Join-Path $runRoot 'pipeline-state.json'
$python = if ($PythonExecutable) { $PythonExecutable } else { Join-Path $pipelineRoot '.venv\Scripts\python.exe' }
$koharu = if ($KoharuExecutable) { $KoharuExecutable } else { Join-Path $pipelineRoot 'vendor\koharu\target\debug\koharu.exe' }
$dataDir = if ($DataDirectory) { $DataDirectory } else { Join-Path $pipelineRoot 'data' }
$localAI = $QwenLifecycleScript
$pwsh = if ($PowerShellExecutable) { $PowerShellExecutable } else { (Get-Process -Id $PID -ErrorAction Stop).Path }

foreach ($required in @($python, $koharu, $localAI, $pwsh)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required runtime is missing: $required"
    }
}
if (-not (Test-Path -LiteralPath $HyModelDirectory -PathType Container)) {
    throw "Hy-MT2 model directory is missing: $HyModelDirectory"
}
$HyModelDirectory = (Resolve-Path -LiteralPath $HyModelDirectory).Path
$python = (Resolve-Path -LiteralPath $python).Path
$koharu = (Resolve-Path -LiteralPath $koharu).Path
$localAI = (Resolve-Path -LiteralPath $localAI).Path
$pwsh = (Resolve-Path -LiteralPath $pwsh).Path
$qwenUri = Assert-LocalHttpUrl -Value $QwenApi -Name 'Qwen API'
$QwenApi = $qwenUri.AbsoluteUri.TrimEnd('/')
$leaseFullPath = [IO.Path]::GetFullPath($QwenLeasePath)
$leaseParent = Split-Path -Parent $leaseFullPath
if ([string]::IsNullOrWhiteSpace($leaseParent) -or -not (Test-Path -LiteralPath $leaseParent -PathType Container)) {
    throw "Qwen lease directory is missing: $leaseParent"
}
if ((Test-Path -LiteralPath $leaseFullPath) -and (Test-Path -LiteralPath $leaseFullPath -PathType Container)) {
    throw "Qwen lease path is a directory: $leaseFullPath"
}
$QwenLeasePath = $leaseFullPath
[void](Test-PinnedModelLayout -ModelDirectory $HyModelDirectory -LockPath (Join-Path $pipelineRoot 'config\model-lock.json'))
$dataDir = [IO.Path]::GetFullPath($dataDir)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
if (Test-Path -LiteralPath $statePath) {
    throw "Pipeline state already exists: $statePath. Use scripts\stop.ps1 or inspect the recorded processes."
}

try {
    $identityProbe = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
    if ($null -eq $identityProbe) {
        throw 'the current process was not returned'
    }
}
catch {
    throw "Process identity inspection is required before startup: $($_.Exception.Message)"
}
Write-StartupProgress -Phase 'runtime' -Completed 1 -Detail 'runtime, model layout, and process identity validated'

$status = & $localAI -Operation status -Summary | ConvertFrom-Json
[void](Assert-LocalQwenStatus -Status $status -ExpectedModel $QwenModel)
Write-StartupProgress -Phase 'coordination' -Completed 2 -Detail 'Qwen model/context and ComfyUI state validated'

$sidecar = $null
$koharuProcess = $null
$ownedProcesses = [System.Collections.Generic.List[object]]::new()
try {
    $sidecarOut = Join-Path $runRoot 'sidecar.stdout.log'
    $sidecarErr = Join-Path $runRoot 'sidecar.stderr.log'
    $sidecarArgs = @('-m', 'service.server', '--host', '127.0.0.1', '--port', [string]$ServicePort)
    $env:KOHARU_QWEN_LIFECYCLE_SCRIPT = $localAI
    $env:KOHARU_QWEN_API = $QwenApi
    $env:KOHARU_QWEN_MODEL = $QwenModel
    $env:KOHARU_QWEN_LEASE_PATH = $QwenLeasePath
    $env:KOHARU_PWSH_EXECUTABLE = $pwsh
    $env:KOHARU_SPECIALIST_PYTHON = $python
    $env:KOHARU_HY_MODEL_PATH = $HyModelDirectory
    $env:KOHARU_API = "http://127.0.0.1:$KoharuPort/api/v1"
    $sidecar = Start-Process -FilePath $python -ArgumentList $sidecarArgs -WorkingDirectory $pipelineRoot -WindowStyle Hidden -RedirectStandardOutput $sidecarOut -RedirectStandardError $sidecarErr -PassThru
    $sidecarIdentity = Get-RecordedProcessIdentity -Process $sidecar
    $ownedProcesses.Add([pscustomobject]@{ name = 'sidecar-launcher'; record = $sidecarIdentity })
    Write-StartupProgress -Phase 'sidecar_process' -Completed 3 -Detail "translation sidecar started as PID $($sidecarIdentity.pid)"
    $sidecarReady = $false
    $sidecarDeadline = [datetime]::UtcNow.AddSeconds($SidecarReadyTimeoutSeconds)
    while ([datetime]::UtcNow -lt $sidecarDeadline) {
        if ($sidecar.HasExited) { throw "Translation sidecar exited during startup. See $sidecarErr" }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$ServicePort/health" -TimeoutSec 2
            if ($health.status -eq 'ok') { $sidecarReady = $true; break }
        }
        catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $sidecarReady) { throw 'Translation sidecar did not become ready.' }

    $sidecarListener = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $ServicePort -State Listen -ErrorAction Stop | Select-Object -First 1
    $sidecarRuntime = Get-Process -Id ([int]$sidecarListener.OwningProcess) -ErrorAction Stop
    $listenerIdentity = Get-RecordedProcessIdentity -Process $sidecarRuntime
    Assert-OwnedProcessListener -LauncherIdentity $sidecarIdentity -ListenerIdentity $listenerIdentity
    if ([int]$listenerIdentity.pid -ne [int]$sidecarIdentity.pid) {
        $ownedProcesses.Add([pscustomobject]@{ name = 'sidecar-listener'; record = $listenerIdentity })
    }
    Write-StartupProgress -Phase 'sidecar_ready' -Completed 4 -Detail "translation sidecar owns port $ServicePort"

    $koharuOut = Join-Path $runRoot 'koharu.stdout.log'
    $koharuErr = Join-Path $runRoot 'koharu.stderr.log'
    $koharuArgs = @('--headless', '--host', '127.0.0.1', '--port', [string]$KoharuPort, '--data-dir', $dataDir)
    $koharuProcess = Start-Process -FilePath $koharu -ArgumentList $koharuArgs -WorkingDirectory (Split-Path -Parent $koharu) -WindowStyle Hidden -RedirectStandardOutput $koharuOut -RedirectStandardError $koharuErr -PassThru
    $koharuIdentity = Get-RecordedProcessIdentity -Process $koharuProcess
    $ownedProcesses.Add([pscustomobject]@{ name = 'koharu'; record = $koharuIdentity })
    Write-StartupProgress -Phase 'koharu_process' -Completed 5 -Detail "Koharu started as PID $($koharuIdentity.pid)"
    $koharuReady = $false
    $koharuDeadline = [datetime]::UtcNow.AddSeconds($KoharuReadyTimeoutSeconds)
    while ([datetime]::UtcNow -lt $koharuDeadline) {
        if ($koharuProcess.HasExited) { throw "Koharu exited during startup. See $koharuErr" }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$KoharuPort/api/v1/health" -TimeoutSec 2
            if ($health.status -eq 'ok') { $koharuReady = $true; break }
            if ($health.initialization_error) {
                throw "Koharu initialization failed: $($health.initialization_error)"
            }
        }
        catch {
            if ($_.Exception.Message -like 'Koharu initialization failed:*') { throw }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $koharuReady) { throw 'Koharu did not become ready.' }
    $fontCatalog = Invoke-RestMethod -Uri "http://127.0.0.1:$KoharuPort/api/v1/fonts" -TimeoutSec 30
    [void](Test-KoharuFontPolicy -PolicyPath (Join-Path $pipelineRoot 'config\translation-policy.json') -FontCatalog $fontCatalog)
    Write-StartupProgress -Phase 'koharu_ready' -Completed 6 -Detail "Koharu owns port $KoharuPort; initialization and required fonts are ready"

    $sidecarIdentity['arguments'] = $sidecarArgs
    $sidecarIdentity['url'] = "http://127.0.0.1:$ServicePort/v1"
    $sidecarIdentity['hy_model_directory'] = $HyModelDirectory
    $listenerIdentity['port'] = $ServicePort
    $sidecarIdentity['listener'] = $listenerIdentity

    $koharuIdentity['arguments'] = $koharuArgs
    $koharuIdentity['url'] = "http://127.0.0.1:$KoharuPort/"

    $runtime = [ordered]@{
        koharu_api = "http://127.0.0.1:$KoharuPort/api/v1"
        sidecar_api = "http://127.0.0.1:$ServicePort/v1"
        qwen_api = $QwenApi.TrimEnd('/')
        qwen_model = $QwenModel
        qwen_lease_path = $(if ([string]::IsNullOrWhiteSpace($QwenLeasePath)) { $null } else { [IO.Path]::GetFullPath($QwenLeasePath) })
        qwen_lifecycle_script = $localAI
        powershell_executable = $pwsh
        python_executable = $python
        koharu_executable = $koharu
        hy_model_directory = $HyModelDirectory
        data_directory = $dataDir
    }
    $state = [ordered]@{
        schema_version = 2
        created_at = (Get-Date).ToString('o')
        runtime = $runtime
        sidecar_status = 'running'
        sidecar_restart_error = $null
        sidecar = $sidecarIdentity
        koharu = $koharuIdentity
    }
    $temporary = "$statePath.$PID.tmp"
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $statePath
    $state | ConvertTo-Json -Depth 8
}
catch {
    $startupError = $_
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($entry in $ownedProcesses) {
        $record = $entry.record
        if ($seen.ContainsKey([int]$record.pid)) { continue }
        $seen[[int]$record.pid] = $true
        $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        try {
            if (-not (Test-RecordedProcessIdentity -Name $entry.name -Record $record -Process $process)) {
                continue
            }
            Stop-Process -Id $process.Id -ErrorAction Stop
            Wait-Process -Id $process.Id -Timeout 15 -ErrorAction SilentlyContinue
            if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
                throw "$($entry.name) PID $($process.Id) did not stop."
            }
        }
        catch {
            $cleanupErrors.Add($_.Exception.Message)
        }
    }
    if ($cleanupErrors.Count -gt 0) {
        throw "Startup failed: $($startupError.Exception.Message) Cleanup was incomplete: $($cleanupErrors -join ' | ')"
    }
    throw $startupError
}
