[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('save', 'validate', 'start', 'status', 'prepare', 'run', 'retry', 'retry-prose', 'export', 'cancel', 'stop')]
    [string]$Action,
    [string]$SettingsPath,
    [string]$ProjectName,
    [string]$InputPath,
    [string]$OutputDirectory,
    [string]$DataDirectory,
    [string]$PythonExecutable,
    [string]$KoharuExecutable,
    [string]$HyModelDirectory,
    [string]$QwenLifecycleScript,
    [string]$QwenApi,
    [string]$QwenModel,
    [string]$QwenLeasePath,
    [ValidateRange(1, 65535)][int]$KoharuPort,
    [ValidateRange(1, 65535)][int]$ServicePort,
    [ValidateSet('png', 'psd')][string]$ExportFormat,
    [string]$ReviewPageId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'launcher-core.psm1') -Force
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $root 'config\local.launcher.json'
}

function Write-LauncherEvent {
    param(
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)][object]$Data
    )
    $json = [pscustomobject]@{ event = $Event; data = $Data } | ConvertTo-Json -Depth 12 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

try {
    $settings = Import-LauncherSettings -Path $SettingsPath
    $overrides = @{
        ProjectName = 'project_name'
        InputPath = 'input_path'
        OutputDirectory = 'output_directory'
        DataDirectory = 'data_directory'
        PythonExecutable = 'python_executable'
        KoharuExecutable = 'koharu_executable'
        HyModelDirectory = 'hy_model_directory'
        QwenLifecycleScript = 'qwen_lifecycle_script'
        QwenApi = 'qwen_api'
        QwenModel = 'qwen_model'
        QwenLeasePath = 'qwen_lease_path'
        KoharuPort = 'koharu_port'
        ServicePort = 'service_port'
        ExportFormat = 'export_format'
    }
    foreach ($parameterName in $overrides.Keys) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $settings.($overrides[$parameterName]) = $PSBoundParameters[$parameterName]
        }
    }

    switch ($Action) {
        'save' {
            Save-LauncherSettings -Settings $settings -Path $SettingsPath
            Write-LauncherEvent -Event 'saved' -Data @{ path = [IO.Path]::GetFullPath($SettingsPath) }
        }
        'validate' {
            $validation = Test-LauncherRuntime -Settings $settings -OnProgress {
                param($progress)
                Write-LauncherEvent -Event 'validation_progress' -Data $progress
            }
            Save-LauncherSettings -Settings $settings -Path $SettingsPath
            Write-LauncherEvent -Event 'validated' -Data $validation
        }
        'start' {
            Save-LauncherSettings -Settings $settings -Path $SettingsPath
            Write-LauncherEvent -Event 'starting' -Data @{ message = 'Starting translation service and Koharu.' }
            $result = Start-LauncherPipeline -Settings $settings -OnProgress {
                param($progress)
                Write-LauncherEvent -Event 'startup_progress' -Data $progress
            }
            Write-LauncherEvent -Event 'started' -Data $result
        }
        'status' {
            $result = Get-LauncherStatus -Settings $settings
            Write-LauncherEvent -Event 'status' -Data $result
        }
        'prepare' {
            Save-LauncherSettings -Settings $settings -Path $SettingsPath
            Write-LauncherEvent -Event 'importing' -Data @{ project = $settings.project_name; input = $settings.input_path }
            $result = Initialize-LauncherProject -Settings $settings -ProjectName $settings.project_name -InputPath $settings.input_path -OnProgress {
                param($progress)
                Write-LauncherEvent -Event 'prepare_progress' -Data $progress
            }
            Write-LauncherEvent -Event 'prepared' -Data $result
        }
        'run' {
            Save-LauncherSettings -Settings $settings -Path $SettingsPath
            $result = Invoke-LauncherSerialProjectJob -Settings $settings -OnStarted {
                param($run)
                Write-LauncherEvent -Event 'job_started' -Data $run
            } -OnProgress {
                param($job)
                Write-LauncherEvent -Event 'progress' -Data $job
            }
            $reviews = @(Get-LauncherReviewItems -Settings $settings -SkipLayerValidation)
            $result | Add-Member -NotePropertyName review_count -NotePropertyValue $reviews.Count -Force
            Write-LauncherEvent -Event 'finished' -Data $result
        }
        'retry' {
            if ([string]::IsNullOrWhiteSpace($ReviewPageId)) { throw 'A review page ID is required.' }
            $result = Invoke-LauncherReviewRetry -Settings $settings -PageId $ReviewPageId -OnStarted {
                param($jobId)
                Write-LauncherEvent -Event 'review_retry_started' -Data @{ id = $jobId; page_id = $ReviewPageId }
            } -OnProgress {
                param($job)
                Write-LauncherEvent -Event 'progress' -Data $job
            }
            $reviews = @(Get-LauncherReviewItems -Settings $settings -SkipLayerValidation)
            $retryStatus = Get-LauncherStatus -Settings $settings
            Write-LauncherEvent -Event 'review_retry_finished' -Data @{
                job = $result
                page_id = $ReviewPageId
                review_count = $reviews.Count
                project_job_state = [string]$retryStatus.project_job_state
            }
        }
        'retry-prose' {
            $result = Invoke-LauncherProseReviewRetryBatch -Settings $settings -OnPageStarted {
                param($page)
                Write-LauncherEvent -Event 'prose_retry_batch_started' -Data $page
            } -OnProgress {
                param($job)
                Write-LauncherEvent -Event 'progress' -Data $job
            }
            $retryStatus = Get-LauncherStatus -Settings $settings
            Write-LauncherEvent -Event 'prose_retry_batch_finished' -Data @{
                attempted = [int]$result.attempted
                succeeded = [int]$result.succeeded
                failed = @($result.failed)
                review_count = [int]$result.remaining
                project_job_state = [string]$retryStatus.project_job_state
            }
        }
        'export' {
            Save-LauncherSettings -Settings $settings -Path $SettingsPath
            Write-LauncherEvent -Event 'exporting' -Data @{ directory = $settings.output_directory; format = $settings.export_format }
            $result = Export-LauncherProject -Settings $settings
            Write-LauncherEvent -Event 'exported' -Data $result
        }
        'cancel' {
            $result = Stop-LauncherCurrentJob -Settings $settings
            Write-LauncherEvent -Event 'cancelled' -Data $result
        }
        'stop' {
            $result = Stop-LauncherPipeline
            Write-LauncherEvent -Event 'stopped' -Data $result
        }
    }
}
catch {
    Write-LauncherEvent -Event 'error' -Data @{
        message = $_.Exception.Message
        category = [string]$_.CategoryInfo.Category
    }
    exit 1
}
