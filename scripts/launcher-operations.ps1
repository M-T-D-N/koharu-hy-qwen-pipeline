# Dot-sourced by launcher-core.psm1 after API helpers and review operations are available.

function Get-LauncherSerialRunPath {
    return Join-Path (Get-LauncherRoot) 'run\serial-project-run.json'
}

function Get-LauncherSerialCancelPath {
    return Join-Path (Get-LauncherRoot) 'run\serial-project-cancel.json'
}

function Get-LauncherSerialRunState {
    $path = Get-LauncherSerialRunPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw "Serial project run state is invalid: $path" }
}

function Write-LauncherSerialRunState {
    param([Parameter(Mandatory)][object]$State)

    $path = Get-LauncherSerialRunPath
    $directory = Split-Path -Parent $path
    [void](New-Item -ItemType Directory -Force -Path $directory)
    $temporary = Join-Path $directory ('.serial-project-run.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Test-LauncherSerialOwnerActive {
    param([Parameter(Mandatory)][object]$State)

    foreach ($field in @('owner_pid', 'owner_path', 'owner_start_time')) {
        if ($null -eq $State.PSObject.Properties[$field]) { return $false }
    }
    $process = Get-Process -Id ([int]$State.owner_pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        return (
            [IO.Path]::GetFullPath($process.Path) -ceq [IO.Path]::GetFullPath([string]$State.owner_path) -and
            $process.StartTime.ToString('o') -ceq ([datetime]$State.owner_start_time).ToString('o')
        )
    }
    catch { return $false }
}

function Test-LauncherSerialCancellation {
    param([Parameter(Mandatory)][string]$RunId)

    $path = Get-LauncherSerialCancelPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $request = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
        return [string]$request.run_id -ceq $RunId
    }
    catch { throw "Serial project cancellation state is invalid: $path" }
}

function Request-LauncherSerialCancellation {
    param([Parameter(Mandatory)][object]$State)

    $path = Get-LauncherSerialCancelPath
    $directory = Split-Path -Parent $path
    [void](New-Item -ItemType Directory -Force -Path $directory)
    $temporary = Join-Path $directory ('.serial-project-cancel.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [pscustomobject]@{
            schema_version = 1
            run_id = [string]$State.run_id
            requested_at_utc = [datetime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-LauncherProjectJobState {
    param(
        [object[]]$Jobs = @(),
        [object[]]$ReviewActions = @(),
        [string]$ProjectName = '',
        [object[]]$CurrentPages = @(),
        [object]$SerialRunState
    )
    $projectActions = @($ReviewActions | Where-Object {
        [string]$_.action -in @('project_job_started', 'project_job_finished') -and
        ([string]::IsNullOrWhiteSpace($ProjectName) -or [string]$_.project -ceq $ProjectName)
    })
    if ($projectActions.Count -eq 0) { return $null }
    $started = @($projectActions | Where-Object { [string]$_.action -eq 'project_job_started' }) | Select-Object -Last 1
    if ($null -eq $started) { return $null }

    $recordedPages = @($started.page_identity | ForEach-Object { [string]$_ } | Sort-Object)
    if ($CurrentPages.Count -gt 0) {
        $currentIdentity = @($CurrentPages | ForEach-Object { "$([string]$_.id)|$([string]$_.source_asset)" } | Sort-Object)
        if ($recordedPages.Count -eq 0 -or $recordedPages.Count -ne $currentIdentity.Count) { return 'outdated' }
        for ($index = 0; $index -lt $recordedPages.Count; $index++) {
            if ($recordedPages[$index] -cne $currentIdentity[$index]) { return 'outdated' }
        }
    }

    $jobId = [string]$started.koharu_job_id
    $reported = $Jobs | Where-Object { [string]$_.id -ceq $jobId } | Select-Object -First 1
    if ($null -ne $reported) { return [string]$reported.state }
    if ($started.PSObject.Properties.Name -contains 'serial_pages' -and [bool]$started.serial_pages) {
        $serial = if ($PSBoundParameters.ContainsKey('SerialRunState')) { $SerialRunState } else { Get-LauncherSerialRunState }
        if ($null -ne $serial -and [string]$serial.run_id -ceq $jobId -and [string]$serial.status -eq 'running') {
            $actualJobId = if ($null -ne $serial.PSObject.Properties['actual_job_id']) { [string]$serial.actual_job_id } else { '' }
            $actual = $Jobs | Where-Object { [string]$_.id -ceq $actualJobId } | Select-Object -First 1
            if ($null -ne $actual -and [string]$actual.state -in @('queued', 'running')) { return [string]$actual.state }
            if (Test-LauncherSerialOwnerActive -State $serial) { return 'running' }
        }
    }
    $finished = $projectActions | Where-Object {
        [string]$_.action -eq 'project_job_finished' -and
        ([string]$_.start_action_id -ceq [string]$started.action_id -or
         ([string]::IsNullOrWhiteSpace([string]$_.start_action_id) -and [string]$_.koharu_job_id -ceq $jobId))
    } | Select-Object -Last 1
    if ($null -ne $finished) { return [string]$finished.state }
    return 'interrupted'
}

function Get-LauncherRecommendedAction {
    param([Parameter(Mandatory)][object]$Status)

    if (-not $Status.healthy) {
        return $(if ($Status.recorded) { 'stop' } else { 'validate' })
    }
    if ($null -eq $Status.project) { return 'prepare' }
    $jobs = @($Status.jobs)
    if ($jobs.Count -gt 0 -and [string]$jobs[$jobs.Count - 1].state -in @('queued', 'running')) {
        return 'run'
    }
    $projectJobState = if ($Status.project_job_state) {
        [string]$Status.project_job_state
    }
    elseif ($jobs.Count -gt 0) {
        [string]$jobs[$jobs.Count - 1].state
    }
    else {
        $null
    }
    if ($projectJobState -in @('failed', 'stopped', 'interrupted', 'outdated')) { return 'run' }
    if ([int]$Status.review_count -gt 0) { return 'review' }
    if ($projectJobState -eq 'finished') { return 'export' }
    return 'run'
}

function Complete-LauncherProjectJobRecord {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][ValidateSet('finished', 'failed', 'stopped')][string]$State,
        [string]$ErrorMessage = ''
    )

    $actions = @(Get-LauncherReviewActions)
    $started = $actions | Where-Object {
        [string]$_.action -eq 'project_job_started' -and [string]$_.koharu_job_id -ceq $JobId
    } | Select-Object -Last 1
    if ($null -eq $started) { return }
    $alreadyRecorded = $actions | Where-Object {
        [string]$_.action -eq 'project_job_finished' -and [string]$_.koharu_job_id -ceq $JobId
    } | Select-Object -First 1
    if ($null -ne $alreadyRecorded) { return }
    $project = $null
    try {
        $project = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'project' -TimeoutSeconds 5
    }
    catch {
        # The terminal job state is authoritative even when its optional final
        # project revision cannot be sampled because the service is restarting.
    }
    [void](Add-LauncherReviewAction -Data @{
        action = 'project_job_finished'
        start_action_id = [string]$started.action_id
        project = [string]$started.project
        koharu_job_id = $JobId
        state = $State
        error = $ErrorMessage
        final_revision = if ($null -ne $project) { [int64]$project.revision } else { $null }
    })
}

function Invoke-LauncherReviewRetry {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][string]$PageId,
        [scriptblock]$OnStarted,
        [scriptblock]$OnProgress
    )

    $items = @(Get-LauncherReviewItems -Settings $Settings -SkipLayerValidation | Where-Object { [string]$_.page_id -ceq $PageId })
    if ($items.Count -eq 0) { throw 'This page has no pending review items.' }
    if (@($items | Where-Object { -not $_.retry_available }).Count -gt 0) { throw 'This page already used its one review retry.' }
    $status = Get-LauncherStatus -Settings $Settings
    if (-not $status.healthy) { throw 'Koharu is not ready for a review retry.' }
    if (@($status.jobs | Where-Object { [string]$_.state -in @('queued', 'running') }).Count -gt 0) { throw 'Another Koharu pipeline job is already running.' }
    if (@($status.pages | Where-Object { [string]$_.id -ceq $PageId }).Count -eq 0) { throw 'The review page is not part of the current project.' }

    $request = New-LauncherReviewRetryRequest -PageId $PageId
    $jobId = [string](Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'pipeline' -Method POST -Body $request -TimeoutSeconds 60)
    $startedRecord = Add-LauncherReviewAction -Data @{
        action = 'page_retry_started'
        project = [string]$status.project.name
        page_id = $PageId
        koharu_job_id = $jobId
    }
    if ($OnStarted) { & $OnStarted $jobId }
    try {
        $result = Wait-LauncherJob -Settings $Settings -JobId $jobId -OnProgress $OnProgress
        [void](Add-LauncherReviewAction -Data @{
            action = 'page_retry_finished'
            retry_action_id = [string]$startedRecord.action_id
            project = [string]$status.project.name
            page_id = $PageId
            koharu_job_id = $jobId
            state = 'finished'
            consumes_retry = $true
        })
        return $result
    }
    catch {
        $failureMessage = $_.Exception.Message
        $consumesRetry = Test-LauncherRetryFailureConsumesAttempt -Message $failureMessage
        [void](Add-LauncherReviewAction -Data @{
            action = 'page_retry_finished'
            retry_action_id = [string]$startedRecord.action_id
            project = [string]$status.project.name
            page_id = $PageId
            koharu_job_id = $jobId
            state = 'failed'
            consumes_retry = $consumesRetry
            error = $failureMessage
        })
        throw
    }
}

function Invoke-LauncherProseReviewRetryBatch {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [scriptblock]$OnPageStarted,
        [scriptblock]$OnProgress
    )

    $plan = Get-LauncherLocalResolutionPlan -Settings $Settings
    $pages = @($plan.prose_retry_pages)
    if ($pages.Count -eq 0) {
        return [pscustomobject]@{ attempted = 0; succeeded = 0; failed = @(); remaining = @($plan.items).Count }
    }

    $pageStartedCallback = $OnPageStarted
    $batchProgressCallback = $OnProgress
    $succeeded = 0
    $failures = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $pages.Count; $index++) {
        $page = $pages[$index]
        try {
            [void](Invoke-LauncherReviewRetry -Settings $Settings -PageId ([string]$page.page_id) -OnStarted {
                param($jobId)
                if ($pageStartedCallback) {
                    & $pageStartedCallback ([pscustomobject]@{
                        job_id = $jobId
                        page_id = [string]$page.page_id
                        page_label = [string]$page.page_label
                        page_index = $index + 1
                        page_total = $pages.Count
                    })
                }
            } -OnProgress {
                param($job)
                if ($batchProgressCallback) {
                    & $batchProgressCallback (ConvertTo-LauncherSerialProgress -Job $job -PageIndex ($index + 1) -PageCount $pages.Count)
                }
            })
            $succeeded++
        }
        catch {
            $message = $_.Exception.Message
            if (-not (Test-LauncherRetryFailureConsumesAttempt -Message $message)) {
                throw "Prose retry batch stopped after $index/$($pages.Count) page(s): $message"
            }
            $failures.Add([pscustomobject]@{
                page_id = [string]$page.page_id
                page_label = [string]$page.page_label
                error = $message
            })
        }
    }
    $remaining = @(Get-LauncherReviewItems -Settings $Settings -SkipLayerValidation).Count
    return [pscustomobject]@{
        attempted = $pages.Count
        succeeded = $succeeded
        failed = @($failures)
        remaining = $remaining
    }
}

function Get-LauncherStatus {
    param([Parameter(Mandatory)][object]$Settings)

    $root = Get-LauncherRoot
    $statePath = Join-Path $root 'run\pipeline-state.json'
    $status = [ordered]@{
        recorded = (Test-Path -LiteralPath $statePath -PathType Leaf)
        healthy = $false
        health = $null
        project = $null
        pages = @()
        jobs = @()
        review_count = 0
        review_pages = 0
        blocking_review_count = 0
        project_job_state = $null
    }
    try {
        $status.health = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'health' -TimeoutSeconds 3
        $status.healthy = ($status.health.status -eq 'ok')
        if ($status.healthy) {
            try {
                $status.project = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'project' -TimeoutSeconds 5
            }
            catch {
                if ($_.Exception.Message -notmatch '\b400\b') { throw }
                $status.project = $null
            }
            if ($null -ne $status.project) {
                $status.pages = @((Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'pages' -TimeoutSeconds 5) | ForEach-Object { $_ })
                try {
                    $reviews = @(Get-LauncherReviewItems -Settings $Settings -SkipLayerValidation)
                    $status.review_count = $reviews.Count
                    $status.review_pages = @($reviews.page_id | Sort-Object -Unique).Count
                    $status.blocking_review_count = @($reviews | Where-Object { @($_.blocking_defects).Count -gt 0 }).Count
                }
                catch { $status.review_error = $_.Exception.Message }
            }
            $jobResult = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'jobs' -TimeoutSeconds 5
            $status.jobs = @($jobResult | ForEach-Object { $_ })
            try {
                $projectName = if ($null -ne $status.project) { [string]$status.project.name } else { '' }
                $status.project_job_state = Get-LauncherProjectJobState -Jobs $status.jobs -ReviewActions @(Get-LauncherReviewActions) -ProjectName $projectName -CurrentPages @($status.pages)
            }
            catch { $status.review_error = $_.Exception.Message }
        }
        try {
            $status.translation_service = Invoke-LauncherServiceApi -Port ([int]$Settings.service_port) -Path 'status' -TimeoutSeconds 3
        }
        catch { $status.translation_service_error = $_.Exception.Message }
    }
    catch {
        $status.error = $_.Exception.Message
    }
    return [pscustomobject]$status
}

function Initialize-LauncherProject {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$InputPath,
        [scriptblock]$OnProgress
    )

    if ([string]::IsNullOrWhiteSpace($ProjectName)) { throw 'Enter a project name.' }
    if ($ProjectName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw 'Project name contains invalid filename characters.' }
    $port = [int]$Settings.koharu_port
    $health = Invoke-KoharuApi -Port $port -Path 'health' -TimeoutSeconds 5
    if ($health.status -ne 'ok') { throw "Koharu is not ready: $($health.status)" }
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ phase = 'health'; completed = 1; total = 4; detail = 'Koharu ready' }) }
    try {
        $current = Invoke-KoharuApi -Port $port -Path 'project' -TimeoutSeconds 5
    }
    catch {
        if ($_.Exception.Message -notmatch '\b400\b') { throw }
        $current = $null
    }
    if ($null -ne $current -and [string]$current.name -cne $ProjectName) {
        [void](Invoke-KoharuApi -Port $port -Path 'projects/close' -Method POST -Body @{} -TimeoutSeconds 30)
        $current = $null
    }
    if ($null -eq $current) {
        $projects = @((Invoke-KoharuApi -Port $port -Path 'projects' -TimeoutSeconds 10) | ForEach-Object { $_ })
        if (@($projects | Where-Object { [string]$_.name -ceq $ProjectName }).Count -gt 0) {
            [void](Invoke-KoharuApi -Port $port -Path 'projects/open' -Method POST -Body @{ name = $ProjectName } -TimeoutSeconds 60)
        }
        else {
            [void](Invoke-KoharuApi -Port $port -Path 'projects' -Method POST -Body @{ name = $ProjectName } -TimeoutSeconds 60)
        }
    }
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ phase = 'project'; completed = 2; total = 4; detail = 'project open' }) }
    $existingPages = @((Invoke-KoharuApi -Port $port -Path 'pages' -TimeoutSeconds 10) | ForEach-Object { $_ })
    if ($existingPages.Count -gt 0) {
        if ($OnProgress) { & $OnProgress ([pscustomobject]@{ phase = 'pages'; completed = 4; total = 4; detail = "resumed $($existingPages.Count) pages" }) }
        return [pscustomobject]@{
            project = $ProjectName
            imported = 0
            pages = $existingPages.Count
            resumed = $true
        }
    }
    $paths = @(Get-SupportedInputFiles -InputPath $InputPath)
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ phase = 'import'; completed = 3; total = 4; detail = "importing $($paths.Count) inputs" }) }
    [void](Invoke-KoharuApi -Port $port -Path 'pages' -Method POST -Body @{ paths = $paths } -TimeoutSeconds 600)
    $pages = @((Invoke-KoharuApi -Port $port -Path 'pages' -TimeoutSeconds 30) | ForEach-Object { $_ })
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ phase = 'pages'; completed = 4; total = 4; detail = "verified $($pages.Count) pages" }) }
    [pscustomobject]@{ project = $ProjectName; imported = $paths.Count; pages = $pages.Count; resumed = $false }
}

function Start-LauncherJob {
    param([Parameter(Mandatory)][object]$Settings)

    $port = [int]$Settings.koharu_port
    $pages = @((Invoke-KoharuApi -Port $port -Path 'pages' -TimeoutSeconds 10) | ForEach-Object { $_ })
    if ($pages.Count -eq 0) { throw 'The current project has no pages to process.' }
    $id = Invoke-KoharuApi -Port $port -Path 'pipeline' -Method POST -Body @{
        scope = @{ scope = 'project' }
        operation = @{ operation = 'full' }
    } -TimeoutSeconds 60
    $project = Invoke-KoharuApi -Port $port -Path 'project' -TimeoutSeconds 5
    [void](Add-LauncherReviewAction -Data @{
        action = 'project_job_started'
        project = [string]$project.name
        koharu_job_id = [string]$id
        starting_revision = [int64]$project.revision
        pages = $pages.Count
        page_identity = @($pages | ForEach-Object { "$([string]$_.id)|$([string]$_.source_asset)" })
    })
    return [string]$id
}

function New-LauncherFullPageRequest {
    param([Parameter(Mandatory)][string]$PageId)

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($PageId, [ref]$parsed)) { throw 'Pipeline page ID is invalid.' }
    return [ordered]@{
        scope = [ordered]@{ scope = 'pages'; value = @($PageId) }
        operation = [ordered]@{ operation = 'full' }
    }
}

function ConvertTo-LauncherSerialProgress {
    param(
        [Parameter(Mandatory)][object]$Job,
        [Parameter(Mandatory)][ValidateRange(1, 1000000)][int]$PageIndex,
        [Parameter(Mandatory)][ValidateRange(1, 1000000)][int]$PageCount
    )

    if ($PageIndex -gt $PageCount) { throw 'Serial page progress is outside the project page count.' }
    $pageWork = [math]::Max([int64]1, [int64]$Job.total)
    $pageCompleted = [math]::Max([int64]0, [math]::Min($pageWork, [int64]$Job.completed))
    $progress = $Job.PSObject.Copy()
    $progress.completed = (($PageIndex - 1) * $pageWork) + $pageCompleted
    $progress.total = [int64]$PageCount * [int64]$pageWork
    $progress | Add-Member -NotePropertyName actual_job_id -NotePropertyValue ([string]$Job.id) -Force
    $progress | Add-Member -NotePropertyName serial_page_index -NotePropertyValue $PageIndex -Force
    $progress | Add-Member -NotePropertyName serial_page_total -NotePropertyValue $PageCount -Force
    return $progress
}

function Get-LauncherResumePageIds {
    param(
        [object]$PriorState,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][object[]]$Pages
    )

    if ($null -eq $PriorState -or [string]$PriorState.project -cne $ProjectName -or
        [string]$PriorState.status -eq 'finished' -or
        $null -eq $PriorState.PSObject.Properties['page_identity'] -or
        $null -eq $PriorState.PSObject.Properties['completed_pages']) {
        return @()
    }
    $identity = @($Pages | ForEach-Object { "$([string]$_.id)|$([string]$_.source_asset)" })
    $priorIdentity = @($PriorState.page_identity | ForEach-Object { [string]$_ })
    $completed = @($PriorState.completed_pages | ForEach-Object { [string]$_ })
    if ($priorIdentity.Count -ne $identity.Count -or $completed.Count -gt $Pages.Count) { return @() }
    for ($index = 0; $index -lt $identity.Count; $index++) {
        if ($priorIdentity[$index] -cne $identity[$index]) { return @() }
    }
    for ($index = 0; $index -lt $completed.Count; $index++) {
        if ($completed[$index] -cne [string]$Pages[$index].id) { return @() }
    }
    return @($completed)
}

function Wait-LauncherJob {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][string]$JobId,
        [scriptblock]$OnProgress,
        [int]$PollMilliseconds = 1000,
        [switch]$SkipProjectRecord,
        [string]$SerialRunId = '',
        [int]$SerialPageIndex = 0,
        [int]$SerialPageCount = 0
    )

    $port = [int]$Settings.koharu_port
    $cancellationSent = $false
    $progressCallbackError = $null
    $consecutivePollFailures = 0
    while ($true) {
        try {
            $jobs = @((Invoke-KoharuApi -Port $port -Path 'jobs' -TimeoutSeconds 10) | ForEach-Object { $_ })
            $consecutivePollFailures = 0
        }
        catch {
            $consecutivePollFailures++
            if ($consecutivePollFailures -ge 3) {
                throw "Koharu job status remained unavailable after $consecutivePollFailures bounded polls: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds $PollMilliseconds
            continue
        }
        $job = $jobs | Where-Object { [string]$_.id -ceq $JobId } | Select-Object -First 1
        if ($null -eq $job) { throw "Koharu no longer reports job $JobId." }
        if (-not $cancellationSent -and [string]$job.state -in @('queued', 'running') -and
            -not [string]::IsNullOrWhiteSpace($SerialRunId) -and
            (Test-LauncherSerialCancellation -RunId $SerialRunId)) {
            [void](Stop-LauncherExactJob -Settings $Settings -Job $job)
            $cancellationSent = $true
        }
        $progress = $job.PSObject.Copy()
        if ([string]$job.stage -eq 'translation') {
            try {
                $sidecar = Invoke-LauncherServiceApi -Port ([int]$Settings.service_port) -Path 'status' -TimeoutSeconds 3
                if ($sidecar.status -eq 'busy' -and $null -ne $sidecar.active) {
                    $progress | Add-Member -NotePropertyName sidecar -NotePropertyValue $sidecar.active -Force
                }
            }
            catch {}
        }
        if ($OnProgress) {
            $reportedProgress = if ($SerialPageIndex -gt 0 -and $SerialPageCount -gt 0) {
                ConvertTo-LauncherSerialProgress -Job $progress -PageIndex $SerialPageIndex -PageCount $SerialPageCount
            }
            else { $progress }
            try { & $OnProgress $reportedProgress }
            catch {
                if ([string]::IsNullOrWhiteSpace([string]$progressCallbackError)) {
                    $progressCallbackError = $_.Exception.Message
                }
            }
        }
        switch ([string]$job.state) {
            'finished' {
                if (-not $SkipProjectRecord) {
                    Complete-LauncherProjectJobRecord -Settings $Settings -JobId $JobId -State finished
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$progressCallbackError)) {
                    $job | Add-Member -NotePropertyName progress_callback_error -NotePropertyValue $progressCallbackError -Force
                }
                return $job
            }
            'failed' {
                if (-not $SkipProjectRecord) {
                    Complete-LauncherProjectJobRecord -Settings $Settings -JobId $JobId -State failed -ErrorMessage ([string]$job.error)
                }
                if ($cancellationSent) { throw 'Pipeline job was stopped.' }
                throw "Pipeline job failed: $($job.error)"
            }
            'stopped' {
                if (-not $SkipProjectRecord) {
                    Complete-LauncherProjectJobRecord -Settings $Settings -JobId $JobId -State stopped
                }
                throw 'Pipeline job was stopped.'
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
}

function Test-LauncherAmbiguousTransportFailure {
    param([Parameter(Mandatory)][object]$Exception)

    $current = if ($Exception -is [System.Management.Automation.ErrorRecord]) {
        $Exception.Exception
    }
    else { $Exception }
    while ($null -ne $current) {
        if ($current.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
            return $false
        }
        if ($current -is [System.Net.Sockets.SocketException] -or
            $current -is [System.Net.Http.HttpRequestException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException] -or
            $current -is [System.TimeoutException]) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Get-LauncherNewSubmissionJobId {
    param(
        [Parameter(Mandatory)][object[]]$Jobs,
        [Parameter(Mandatory)][string]$PageId,
        [string[]]$BaselineJobIds = @()
    )

    $baseline = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $BaselineJobIds) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$baseline.Add($id) }
    }
    $matches = @($Jobs | Where-Object {
        $id = [string]$_.id
        -not [string]::IsNullOrWhiteSpace($id) -and
        -not $baseline.Contains($id) -and
        [string]$_.page -ceq $PageId
    })
    if ($matches.Count -gt 1) {
        throw "Koharu reports multiple new jobs for page $PageId; refusing an ambiguous resubmission."
    }
    if ($matches.Count -eq 1) { return [string]$matches[0].id }
    return ''
}

function Invoke-LauncherSerialPageSubmission {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string]$PageId,
        [int]$ReconcileMilliseconds = 500
    )

    $port = [int]$Settings.koharu_port
    $baselineJobs = @((Invoke-KoharuApi -Port $port -Path 'jobs' -TimeoutSeconds 10) | ForEach-Object { $_ })
    $baselineJobIds = @($baselineJobs | ForEach-Object { [string]$_.id })
    $baselineProject = Invoke-KoharuApi -Port $port -Path 'project' -TimeoutSeconds 10

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            return [string](Invoke-KoharuApi -Port $port -Path 'pipeline' -Method POST -Body $Request -TimeoutSeconds 60)
        }
        catch {
            $submissionError = $_
            if (-not (Test-LauncherAmbiguousTransportFailure -Exception $submissionError)) { throw }

            $observedProject = $null
            for ($observation = 1; $observation -le 3; $observation++) {
                if ($observation -gt 1) { Start-Sleep -Milliseconds $ReconcileMilliseconds }
                try {
                    $jobs = @((Invoke-KoharuApi -Port $port -Path 'jobs' -TimeoutSeconds 10) | ForEach-Object { $_ })
                    $reconciledJobId = Get-LauncherNewSubmissionJobId `
                        -Jobs $jobs `
                        -PageId $PageId `
                        -BaselineJobIds $baselineJobIds
                    if (-not [string]::IsNullOrWhiteSpace($reconciledJobId)) { return $reconciledJobId }
                    $observedProject = Invoke-KoharuApi -Port $port -Path 'project' -TimeoutSeconds 10
                }
                catch {
                    if ($_.Exception.Message -match 'multiple new jobs') { throw }
                }
            }

            if ($null -eq $observedProject) {
                throw "Koharu submission outcome could not be reconciled after a transport failure; no page was resubmitted. Original error: $($submissionError.Exception.Message)"
            }
            if ([int64]$observedProject.revision -ne [int64]$baselineProject.revision) {
                throw "Koharu project revision changed after an ambiguous submission for page $PageId; no page was resubmitted."
            }
            if ($attempt -ge 2) {
                throw "Koharu did not accept page $PageId after one bounded, reconciled resubmission. Original error: $($submissionError.Exception.Message)"
            }
            $health = Invoke-KoharuApi -Port $port -Path 'health' -TimeoutSeconds 10
            if ([string]$health.status -cne 'ok') {
                throw "Koharu is not healthy after an ambiguous submission for page $PageId; no page was resubmitted."
            }
        }
    }
}

function Invoke-LauncherSerialProjectJob {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [scriptblock]$OnStarted,
        [scriptblock]$OnProgress,
        [int]$PollMilliseconds = 1000
    )

    $port = [int]$Settings.koharu_port
    $status = Get-LauncherStatus -Settings $Settings
    if (-not $status.healthy -or $null -eq $status.project) { throw 'Koharu is not ready to run an open project.' }
    if (@($status.jobs | Where-Object { [string]$_.state -in @('queued', 'running') }).Count -gt 0) {
        throw 'Another Koharu pipeline job is already running.'
    }
    $pages = @($status.pages)
    if ($pages.Count -eq 0) { throw 'The current project has no pages to process.' }
    $pageIdentity = @($pages | ForEach-Object { "$([string]$_.id)|$([string]$_.source_asset)" })

    $priorState = Get-LauncherSerialRunState
    if ($null -ne $priorState -and [string]$priorState.status -eq 'running' -and (Test-LauncherSerialOwnerActive -State $priorState)) {
        throw "Another serialized project run is still active: $($priorState.run_id)"
    }

    $completedPageIds = @(Get-LauncherResumePageIds -PriorState $priorState -ProjectName ([string]$status.project.name) -Pages $pages)

    $runId = [guid]::NewGuid().ToString()
    $owner = Get-Process -Id $PID -ErrorAction Stop
    $runState = [pscustomobject][ordered]@{
        schema_version = 1
        run_id = $runId
        project = [string]$status.project.name
        status = 'running'
        phase = 'starting'
        actual_job_id = ''
        page_id = ''
        page_index = 0
        page_count = $pages.Count
        page_identity = $pageIdentity
        completed_pages = @($completedPageIds)
        owner_pid = $PID
        owner_path = $owner.Path
        owner_start_time = $owner.StartTime.ToString('o')
        updated_at_utc = [datetime]::UtcNow.ToString('o')
    }
    Write-LauncherSerialRunState -State $runState
    [void](Add-LauncherReviewAction -Data @{
        action = 'project_job_started'
        project = [string]$status.project.name
        koharu_job_id = $runId
        starting_revision = [int64]$status.project.revision
        pages = $pages.Count
        resumed_pages = $completedPageIds.Count
        serial_pages = $true
        page_identity = $pageIdentity
    })
    if ($OnStarted) { & $OnStarted ([pscustomobject]@{ id = $runId; pages = $pages.Count; resumed_pages = $completedPageIds.Count }) }

    $lastResult = $null
    try {
        for ($index = $completedPageIds.Count; $index -lt $pages.Count; $index++) {
            if (Test-LauncherSerialCancellation -RunId $runId) { throw 'Pipeline job was stopped.' }
            $page = $pages[$index]
            $runState.phase = 'submitting'
            $runState.actual_job_id = ''
            $runState.page_id = [string]$page.id
            $runState.page_index = $index + 1
            $runState.updated_at_utc = [datetime]::UtcNow.ToString('o')
            Write-LauncherSerialRunState -State $runState
            $request = New-LauncherFullPageRequest -PageId ([string]$page.id)
            $actualJobId = Invoke-LauncherSerialPageSubmission `
                -Settings $Settings `
                -Request $request `
                -PageId ([string]$page.id)
            $runState.phase = 'running'
            $runState.actual_job_id = $actualJobId
            $runState.updated_at_utc = [datetime]::UtcNow.ToString('o')
            Write-LauncherSerialRunState -State $runState
            $lastResult = Wait-LauncherJob `
                -Settings $Settings `
                -JobId $actualJobId `
                -OnProgress $OnProgress `
                -PollMilliseconds $PollMilliseconds `
                -SkipProjectRecord `
                -SerialRunId $runId `
                -SerialPageIndex ($index + 1) `
                -SerialPageCount $pages.Count
            $completedPageIds += [string]$page.id
            $runState.completed_pages = @($completedPageIds)
            $runState.phase = 'between_pages'
            $runState.actual_job_id = ''
            $runState.updated_at_utc = [datetime]::UtcNow.ToString('o')
            Write-LauncherSerialRunState -State $runState
        }
    }
    catch {
        $state = if ($_.Exception.Message -match 'Pipeline job was stopped') { 'stopped' } else { 'failed' }
        $runState.status = $state
        $runState.phase = 'terminal'
        $runState.updated_at_utc = [datetime]::UtcNow.ToString('o')
        Write-LauncherSerialRunState -State $runState
        Complete-LauncherProjectJobRecord -Settings $Settings -JobId $runId -State $state -ErrorMessage $_.Exception.Message
        throw
    }

    $runState.status = 'finished'
    $runState.phase = 'terminal'
    $runState.actual_job_id = ''
    $runState.updated_at_utc = [datetime]::UtcNow.ToString('o')
    Write-LauncherSerialRunState -State $runState
    Complete-LauncherProjectJobRecord -Settings $Settings -JobId $runId -State finished
    $pageWork = if ($null -ne $lastResult) { [math]::Max(1, [int]$lastResult.total) } else { 1 }
    return [pscustomobject]@{
        id = $runId
        state = 'finished'
        completed = $pages.Count * $pageWork
        total = $pages.Count * $pageWork
        pages = $pages.Count
    }
}

function Stop-LauncherExactJob {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][object]$Job
    )

    if ([string]$Job.state -notin @('queued', 'running')) { throw "Koharu job is not active: $($Job.id)" }
    $sidecarCancelled = $false
    $sidecarWarning = $null
    if ([string]$Job.stage -eq 'translation') {
        try {
            $sidecar = Invoke-LauncherServiceApi -Port ([int]$Settings.service_port) -Path 'status' -TimeoutSeconds 3
            if ($sidecar.status -eq 'busy' -and $null -ne $sidecar.active -and
                [string]$sidecar.active.page_id -ceq [string]$Job.page) {
                [void](Invoke-LauncherServiceApi -Port ([int]$Settings.service_port) -Path 'control/cancel' -Method POST -Body @{} -TimeoutSeconds 10)
                $sidecarCancelled = $true
            }
        }
        catch { $sidecarWarning = $_.Exception.Message }
    }
    [void](Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'pipeline/stop' -Method POST -Body @{ job = [string]$Job.id } -TimeoutSeconds 30)
    return [pscustomobject]@{
        cancelled = $true
        koharu_job_id = [string]$Job.id
        sidecar_cancel_requested = $sidecarCancelled
        warning = $sidecarWarning
    }
}

function Stop-LauncherCurrentJob {
    param([Parameter(Mandatory)][object]$Settings)

    $serial = Get-LauncherSerialRunState
    if ($null -ne $serial -and [string]$serial.status -eq 'running' -and (Test-LauncherSerialOwnerActive -State $serial)) {
        Request-LauncherSerialCancellation -State $serial
        return [pscustomobject]@{
            cancelled = $true
            serial_run_id = [string]$serial.run_id
            koharu_job_id = if ($null -ne $serial.PSObject.Properties['actual_job_id'] -and $serial.actual_job_id) { [string]$serial.actual_job_id } else { $null }
            sidecar_cancel_requested = $false
            pending = $true
            warning = $null
        }
    }

    $actions = @(Get-LauncherReviewActions)
    $retryStarts = @($actions | Where-Object { [string]$_.action -eq 'page_retry_started' })
    $retryFinishedIds = @($actions | Where-Object { [string]$_.action -eq 'page_retry_finished' } | ForEach-Object { [string]$_.koharu_job_id })
    $retry = $retryStarts | Where-Object { [string]$_.koharu_job_id -cnotin $retryFinishedIds } | Select-Object -Last 1
    if ($null -eq $retry) { throw 'No launcher-owned translation job was found.' }
    $jobs = @((Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'jobs' -TimeoutSeconds 5) | ForEach-Object { $_ })
    $job = $jobs | Where-Object {
        [string]$_.id -ceq [string]$retry.koharu_job_id -and [string]$_.state -in @('queued', 'running')
    } | Select-Object -First 1
    if ($null -eq $job) { throw 'The launcher-owned review retry is no longer active.' }
    return Stop-LauncherExactJob -Settings $Settings -Job $job
}

function Test-LauncherDirectoryEmpty {
    param([Parameter(Mandatory)][string]$Path)
    return $null -eq (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Select-Object -First 1)
}

function Invoke-LauncherExportTransaction {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateSet('png', 'psd')][string]$Format,
        [Parameter(Mandatory)][ValidateRange(1, 1000000)][int]$ExpectedPageCount,
        [Parameter(Mandatory)][scriptblock]$RenderAction
    )

    $destination = [IO.Path]::GetFullPath($Directory)
    $root = [IO.Path]::GetPathRoot($destination)
    if ($destination.TrimEnd([IO.Path]::DirectorySeparatorChar) -ceq $root.TrimEnd([IO.Path]::DirectorySeparatorChar)) {
        throw 'The export destination cannot be a filesystem root.'
    }
    $parent = Split-Path -Parent $destination
    $leaf = Split-Path -Leaf $destination
    if ([string]::IsNullOrWhiteSpace($leaf)) { throw 'The export destination must name a directory.' }
    [void](New-Item -ItemType Directory -Force -Path $parent)

    $destinationExisted = Test-Path -LiteralPath $destination -PathType Container
    $destinationCreationTicks = $null
    if (Test-Path -LiteralPath $destination) {
        if (-not $destinationExisted) { throw "The export destination is not a directory: $destination" }
        if (-not (Test-LauncherDirectoryEmpty -Path $destination)) {
            throw "The export destination is not empty. Existing output will not be overwritten: $destination"
        }
        $destinationCreationTicks = (Get-Item -LiteralPath $destination -Force).CreationTimeUtc.Ticks
    }

    $token = [guid]::NewGuid().ToString('N')
    $staging = Join-Path $parent (".{0}.koharu-export-{1}" -f $leaf, $token)
    $backup = Join-Path $parent (".{0}.koharu-empty-{1}" -f $leaf, $token)
    foreach ($privatePath in @($staging, $backup)) {
        $resolvedPrivate = [IO.Path]::GetFullPath($privatePath)
        if ([IO.Path]::GetDirectoryName($resolvedPrivate) -cne [IO.Path]::GetFullPath($parent)) {
            throw 'An export transaction path escaped the destination parent.'
        }
        if (Test-Path -LiteralPath $resolvedPrivate) { throw "An export transaction path already exists: $resolvedPrivate" }
    }

    try {
        & $RenderAction $staging
        if (-not (Test-Path -LiteralPath $staging -PathType Container)) {
            throw 'Koharu did not create the export staging directory.'
        }
        $entries = @(Get-ChildItem -LiteralPath $staging -Force -ErrorAction Stop)
        if (@($entries | Where-Object { $_.PSIsContainer }).Count -gt 0) {
            throw 'The export staging directory contains unexpected subdirectories.'
        }
        $files = @($entries | Where-Object { -not $_.PSIsContainer })
        if ($files.Count -ne $ExpectedPageCount) {
            throw "Koharu exported $($files.Count) file(s), but $ExpectedPageCount page(s) were expected."
        }
        foreach ($file in $files) {
            if ($file.Extension -cne ".$Format" -or $file.Length -le 0) {
                throw "The export staging directory contains an invalid output file: $($file.Name)"
            }
        }

        if ($destinationExisted) {
            if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
                throw 'The export destination disappeared during rendering.'
            }
            $currentDestination = Get-Item -LiteralPath $destination -Force
            if ($currentDestination.CreationTimeUtc.Ticks -ne $destinationCreationTicks -or -not (Test-LauncherDirectoryEmpty -Path $destination)) {
                throw 'The export destination changed during rendering; no output was published.'
            }
            [IO.Directory]::Move($destination, $backup)
            try {
                if (-not (Test-LauncherDirectoryEmpty -Path $backup)) {
                    throw 'The original export destination changed while publishing.'
                }
                if (Test-Path -LiteralPath $destination) {
                    throw 'The export destination was recreated while publishing.'
                }
                [IO.Directory]::Move($staging, $destination)
            }
            catch {
                if (-not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $backup -PathType Container)) {
                    [IO.Directory]::Move($backup, $destination)
                }
                throw
            }
            [IO.Directory]::Delete($backup, $false)
        }
        else {
            if (Test-Path -LiteralPath $destination) {
                throw 'The export destination appeared during rendering; no output was published.'
            }
            [IO.Directory]::Move($staging, $destination)
        }
        return [pscustomobject]@{
            exported = $true
            directory = $destination
            format = $Format
            files = $ExpectedPageCount
        }
    }
    catch {
        if (Test-Path -LiteralPath $staging -PathType Container) {
            $stagingFull = [IO.Path]::GetFullPath($staging)
            if ([IO.Path]::GetDirectoryName($stagingFull) -ceq [IO.Path]::GetFullPath($parent) -and
                [IO.Path]::GetFileName($stagingFull) -ceq (".{0}.koharu-export-{1}" -f $leaf, $token)) {
                [IO.Directory]::Delete($stagingFull, $true)
            }
        }
        throw
    }
}
