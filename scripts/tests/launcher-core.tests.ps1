$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\launcher-core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\runtime-contract.psm1') -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) { throw "Assertion failed: $Message (expected='$Expected', actual='$Actual')" }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('koharu-launcher-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
try {
    Assert-Equal 'http://127.0.0.1:8000/v1' ((Assert-LocalHttpUrl -Value 'http://127.0.0.1:8000/v1' -Name 'test API').AbsoluteUri.TrimEnd('/')) 'loopback HTTP URL is accepted'
    foreach ($unsafeUrl in @('https://127.0.0.1:8000/v1', 'http://example.com/v1')) {
        try {
            [void](Assert-LocalHttpUrl -Value $unsafeUrl -Name 'test API')
            throw 'unsafe API URL unexpectedly succeeded'
        }
        catch { Assert-True ($_.Exception.Message -match 'loopback HTTP') 'nonlocal or HTTPS API URL is rejected' }
    }
    $qwenStatus = [pscustomobject]@{
        comfyui = 'off'
        qwen = [pscustomobject]@{ state = 'ready_owned'; alias = 'test-model'; context = 131072 }
    }
    $validatedQwenStatus = Assert-LocalQwenStatus -Status $qwenStatus -ExpectedModel 'test-model'
    Assert-Equal 'test-model' ([string]$validatedQwenStatus.qwen.alias) 'matching Qwen runtime contract is accepted'
    foreach ($badStatus in @(
        [pscustomobject]@{ comfyui = 'ready'; qwen = [pscustomobject]@{ state = 'ready_owned'; alias = 'test-model'; context = 131072 } },
        [pscustomobject]@{ comfyui = 'off'; qwen = [pscustomobject]@{ state = 'unhealthy_owned'; alias = 'test-model'; context = 131072 } },
        [pscustomobject]@{ comfyui = 'off'; qwen = [pscustomobject]@{ state = 'ready_owned'; alias = 'wrong-model'; context = 131072 } },
        [pscustomobject]@{ comfyui = 'off'; qwen = [pscustomobject]@{ state = 'ready_owned'; alias = 'test-model'; context = 65536 } }
    )) {
        try {
            [void](Assert-LocalQwenStatus -Status $badStatus -ExpectedModel 'test-model')
            throw 'invalid Qwen status unexpectedly succeeded'
        }
        catch { Assert-True ($_.Exception.Message -match 'ComfyUI|reusable|model mismatch|context') 'invalid Qwen runtime contract is rejected' }
    }
    foreach ($startableState in @('off', 'stale_state')) {
        $startable = [pscustomobject]@{ comfyui = 'off'; qwen = [pscustomobject]@{ state = $startableState; alias = $null; context = $null } }
        $acceptedStartable = Assert-LocalQwenStatus -Status $startable -ExpectedModel 'test-model'
        Assert-Equal $startableState ([string]$acceptedStartable.qwen.state) 'an inactive Qwen can be started on demand'
    }
    $fontPolicyPath = Join-Path $PSScriptRoot '..\..\config\translation-policy.json'
    $fontPolicy = Get-Content -LiteralPath $fontPolicyPath -Raw -Encoding utf8 | ConvertFrom-Json
    $fontCatalog = @($fontPolicy.roles.PSObject.Properties.Value.fonts.koharu_family | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ name = [string]$_ } })
    $fontValidation = Test-KoharuFontPolicy -PolicyPath $fontPolicyPath -FontCatalog $fontCatalog
    Assert-Equal $fontCatalog.Count ([int]$fontValidation.required) 'every mapped Koharu font family is validated'
    try {
        [void](Test-KoharuFontPolicy -PolicyPath $fontPolicyPath -FontCatalog @($fontCatalog | Select-Object -Skip 1))
        throw 'missing Koharu font unexpectedly succeeded'
    }
    catch { Assert-True ($_.Exception.Message -match 'font families are unavailable') 'a missing Koharu font is rejected before translation' }
    $identityFields = [ordered]@{
        pid = 123
        path = 'C:\test\worker.exe'
        start_time = '2026-08-27T00:00:00Z'
        parent_pid = 12
        creation_date = '2026-08-27T00:00:00Z'
        command_line = 'worker.exe --test'
    }
    $contractModule = Get-Module runtime-contract
    $dictionaryValues = & $contractModule { param($record) Get-IdentityRecordValues -Name 'test' -Record $record } $identityFields
    Assert-Equal 'C:\test\worker.exe' ([string]$dictionaryValues.path) 'in-memory ordered identity records are accepted'
    $jsonIdentity = $identityFields | ConvertTo-Json | ConvertFrom-Json
    $objectValues = & $contractModule { param($record) Get-IdentityRecordValues -Name 'test' -Record $record } $jsonIdentity
    Assert-Equal 'worker.exe --test' ([string]$objectValues.command_line) 'persisted JSON identity records are accepted'

    $original = @'
[pipeline.translation]
target_language = "en-US"

[pipeline.translation.generation]
reasoning = true
vision = true

[pipeline.translation.model]
model = "old-model"
provider = "openai-compatible"
reasoning = true
vision = true

[providers.openai-compatible]
base_url = "http://127.0.0.1:9999/v1"

[unrelated]
keep = "exactly"
'@
    $session = New-KoharuSessionConfig -OriginalText $original -ServicePort 4020
    Assert-True ($session -match 'target_language = "ko-KR"') 'target language is changed'
    Assert-True ($session -match 'model = "koharu-hy-qwen-v1"') 'model is changed'
    Assert-True ($session -match 'base_url = "http://127.0.0.1:4020/v1"') 'provider URL is changed'
    Assert-True ($session -match '\[unrelated\]\s+keep = "exactly"') 'unrelated config is preserved'
    Assert-Equal 0 ([regex]::Matches($session, '(?m)^reasoning = true$').Count) 'all session reasoning flags are disabled'

    $firstRunSession = New-KoharuSessionConfig -OriginalText '' -ServicePort 4120
    Assert-True ($firstRunSession -match '\[pipeline\.translation\]') 'first run creates the translation section from an empty config'
    Assert-True ($firstRunSession -match 'model = "koharu-hy-qwen-v1"') 'first run creates the model profile'
    Assert-True ($firstRunSession -match 'base_url = "http://127.0.0.1:4120/v1"') 'first run creates the selected nondefault provider URL'

    $retryRequest = New-LauncherReviewRetryRequest -PageId '00000000-0000-0000-0000-000000000001'
    Assert-Equal 'pages' $retryRequest.scope.scope 'review retry is page-scoped'
    Assert-Equal 1 @($retryRequest.scope.value).Count 'review retry targets one page'
    Assert-Equal '00000000-0000-0000-0000-000000000001' $retryRequest.scope.value[0] 'review retry preserves the selected page ID'
    Assert-Equal 'only' $retryRequest.operation.operation 'review retry runs a bounded operation'
    Assert-Equal 'translation' $retryRequest.operation.stage 'review retry does not repeat detection or OCR'
    $largeProgress = ConvertTo-LauncherSerialProgress -Job ([pscustomobject]@{
        id = 'large-progress'
        completed = [int64]2176782336
        total = [int64]2176782336
    }) -PageIndex 2 -PageCount 6
    Assert-Equal ([int64]13060694016) ([int64]$largeProgress.total) 'serial progress keeps large work counters in 64-bit range'
    Assert-Equal ([int64]4353564672) ([int64]$largeProgress.completed) 'serial progress composes large completed counters without overflow'
    try {
        [void](New-LauncherReviewRetryRequest -PageId 'not-a-page-id')
        throw 'invalid review page unexpectedly succeeded'
    }
    catch { Assert-True ($_.Exception.Message -match 'invalid') 'invalid review page ID is rejected' }

    $fullPageRequest = New-LauncherFullPageRequest -PageId '00000000-0000-0000-0000-000000000003'
    Assert-Equal 'pages' $fullPageRequest.scope.scope 'serial project work is page-scoped'
    Assert-Equal '00000000-0000-0000-0000-000000000003' $fullPageRequest.scope.value[0] 'serial project work preserves the page ID'
    Assert-Equal 'full' $fullPageRequest.operation.operation 'each serial page runs the complete pipeline'
    try {
        [void](New-LauncherFullPageRequest -PageId 'not-a-page-id')
        throw 'invalid full-pipeline page unexpectedly succeeded'
    }
    catch { Assert-True ($_.Exception.Message -match 'invalid') 'invalid full-pipeline page ID is rejected' }

    $pageProgress = [pscustomobject]@{ id = 'actual-page-job'; state = 'running'; stage = 'translation'; completed = 2; total = 4 }
    $serialProgress = ConvertTo-LauncherSerialProgress -Job $pageProgress -PageIndex 3 -PageCount 42
    Assert-Equal 10 $serialProgress.completed 'serial progress includes completed earlier pages'
    Assert-Equal 168 $serialProgress.total 'serial progress has a stable project-wide total'
    Assert-Equal 3 $serialProgress.serial_page_index 'serial progress reports the current page number'
    Assert-Equal 42 $serialProgress.serial_page_total 'serial progress reports the project page count'
    Assert-Equal 'actual-page-job' $serialProgress.actual_job_id 'serial progress retains the cancellable Koharu job ID'
    Assert-Equal 2 $pageProgress.completed 'serial progress does not mutate the Koharu job response'
    try {
        [void](ConvertTo-LauncherSerialProgress -Job $pageProgress -PageIndex 43 -PageCount 42)
        throw 'out-of-range serial progress unexpectedly succeeded'
    }
    catch { Assert-True ($_.Exception.Message -match 'outside') 'serial progress rejects an impossible page index' }

    $reconciledJobId = & (Get-Module launcher-core) {
        Get-LauncherNewSubmissionJobId `
            -Jobs @(
                [pscustomobject]@{ id = 'old-job'; page = 'page-a'; state = 'finished' },
                [pscustomobject]@{ id = 'new-job'; page = 'page-a'; state = 'running' },
                [pscustomobject]@{ id = 'other-page-job'; page = 'page-b'; state = 'running' }
            ) `
            -PageId 'page-a' `
            -BaselineJobIds @('old-job')
    }
    Assert-Equal 'new-job' $reconciledJobId 'ambiguous transport recovery adopts only the newly observed exact-page job'
    $noReconciledJob = & (Get-Module launcher-core) {
        Get-LauncherNewSubmissionJobId `
            -Jobs @([pscustomobject]@{ id = 'old-job'; page = 'page-a'; state = 'finished' }) `
            -PageId 'page-a' `
            -BaselineJobIds @('old-job')
    }
    Assert-Equal '' $noReconciledJob 'ambiguous transport recovery does not adopt a pre-existing job'
    try {
        & (Get-Module launcher-core) {
            Get-LauncherNewSubmissionJobId `
                -Jobs @(
                    [pscustomobject]@{ id = 'new-job-1'; page = 'page-a'; state = 'running' },
                    [pscustomobject]@{ id = 'new-job-2'; page = 'page-a'; state = 'queued' }
                ) `
                -PageId 'page-a'
        }
        throw 'multiple matching new jobs unexpectedly reconciled'
    }
    catch { Assert-True ($_.Exception.Message -match 'multiple new jobs') 'ambiguous transport recovery refuses multiple candidate jobs' }
    $socketFailure = [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::ConnectionRefused)
    Assert-True (& (Get-Module launcher-core) { param($errorValue) Test-LauncherAmbiguousTransportFailure -Exception $errorValue } $socketFailure) 'socket failures are eligible for bounded reconciliation'
    Assert-True (-not (& (Get-Module launcher-core) { param($errorValue) Test-LauncherAmbiguousTransportFailure -Exception $errorValue } ([System.InvalidOperationException]::new('bad request')))) 'ordinary application failures are never resubmitted'

    $resumePages = @(
        [pscustomobject]@{ id = 'page-a'; source_asset = 'a.png' },
        [pscustomobject]@{ id = 'page-b'; source_asset = 'b.png' },
        [pscustomobject]@{ id = 'page-c'; source_asset = 'c.png' }
    )
    $resumeState = [pscustomobject]@{
        project = 'project-a'; status = 'failed';
        page_identity = @('page-a|a.png', 'page-b|b.png', 'page-c|c.png');
        completed_pages = @('page-a', 'page-b')
    }
    Assert-Equal 2 @(Get-LauncherResumePageIds -PriorState $resumeState -ProjectName 'project-a' -Pages $resumePages).Count 'a verified successful prefix is resumable'
    $resumeState.completed_pages = @('page-a', 'page-c')
    Assert-Equal 0 @(Get-LauncherResumePageIds -PriorState $resumeState -ProjectName 'project-a' -Pages $resumePages).Count 'a non-prefix checkpoint is rejected'
    $resumeState.completed_pages = @('page-a')
    $resumeState.page_identity = @('page-a|changed.png', 'page-b|b.png', 'page-c|c.png')
    Assert-Equal 0 @(Get-LauncherResumePageIds -PriorState $resumeState -ProjectName 'project-a' -Pages $resumePages).Count 'changed project inputs invalidate a checkpoint'

    $serialState = [pscustomobject]@{
        schema_version = 1
        run_id = 'logical-serial-run'
        status = 'running'
        phase = 'running'
        actual_job_id = 'actual-page-job'
        owner_pid = $PID
        owner_path = (Get-Process -Id $PID).Path
        owner_start_time = (Get-Process -Id $PID).StartTime.ToString('o')
    }
    $serialActions = @([pscustomobject]@{
        action = 'project_job_started'; action_id = 'serial-start'; project = 'project-a';
        koharu_job_id = 'logical-serial-run'; serial_pages = $true; page_identity = @('page-a|a.png', 'page-b|b.png')
    })
    $serialJobs = @([pscustomobject]@{ id = 'actual-page-job'; state = 'running' })
    Assert-Equal 'running' (Get-LauncherProjectJobState -Jobs $serialJobs -ReviewActions $serialActions -ProjectName 'project-a' -SerialRunState $serialState -CurrentPages @(
        [pscustomobject]@{ id = 'page-a'; source_asset = 'a.png' },
        [pscustomobject]@{ id = 'page-b'; source_asset = 'b.png' }
    )) 'an active page job maps back to its logical serial project run'

    $existingTypography = [pscustomobject]@{ font_size = 24; preferred_font = 'Old Font'; alignment = 'center' }
    $typographyRequest = New-LauncherReviewTypographyRequest `
        -RegionId '00000000-0000-0000-0000-000000000002' `
        -Typography $existingTypography `
        -FontRole 'Gowun Dodum'
    Assert-Equal 1 @($typographyRequest.updates).Count 'review typography changes one text layer'
    Assert-Equal '00000000-0000-0000-0000-000000000002' $typographyRequest.updates[0].layer 'review typography targets the selected region'
    Assert-Equal 'Gowun Dodum' $typographyRequest.updates[0].typography.preferred_font 'review typography applies the audited font role'
    Assert-Equal 24 $typographyRequest.updates[0].typography.font_size 'review typography preserves existing settings'
    Assert-Equal 'Old Font' ([string]$existingTypography.preferred_font) 'current typography is not mutated while building the request'
    try {
        [void](New-LauncherReviewTypographyRequest `
            -RegionId '00000000-0000-0000-0000-000000000002' `
            -Typography ([pscustomobject]@{ font_size = 24 }) `
            -FontRole 'Unknown Font')
        throw 'invalid review font unexpectedly succeeded'
    }
    catch { Assert-True ($_.Exception.Message -match 'invalid') 'untrusted review font is rejected' }

    $sourceDecision = Resolve-LauncherReviewText `
        -Source '日本語の原文' -FirstTranslation '초벌' -FinalTranslation '검토본' `
        -Choice source -Translation '日本語の原文'
    Assert-True ($null -eq $sourceDecision.text) 'source preservation removes the translated text overlay'
    Assert-True (-not $sourceDecision.apply_typography) 'source preservation does not apply reviewed Korean typography'
    Assert-True $sourceDecision.preserve_source_pixels 'source preservation requests original page pixels'
    $reviewItem = [pscustomobject]@{
        expected_revision = 41
        current_typography = $existingTypography
        font_role = 'Gowun Dodum'
    }
    $sourceRequest = New-LauncherReviewDecisionRequest `
        -Item $reviewItem -RegionId '00000000-0000-0000-0000-000000000002' -Decision $sourceDecision
    Assert-Equal 41 $sourceRequest.expected_revision 'source decision is pinned to the reviewed project revision'
    Assert-True ($null -eq $sourceRequest.text) 'source decision sends no replacement translation'
    Assert-True ($null -eq $sourceRequest.typography) 'source decision sends no Korean typography'
    Assert-True $sourceRequest.preserve_source_pixels 'source decision explicitly preserves source pixels'

    $manualDecision = Resolve-LauncherReviewText `
        -Source '日本語の原文' -FirstTranslation '초벌' -FinalTranslation '검토본' `
        -Choice manual -Translation '사용자 번역'
    $manualRequest = New-LauncherReviewDecisionRequest `
        -Item $reviewItem -RegionId '00000000-0000-0000-0000-000000000002' -Decision $manualDecision
    Assert-Equal '사용자 번역' $manualRequest.text 'manual review applies the selected Korean text'
    Assert-Equal 'Gowun Dodum' $manualRequest.typography.preferred_font 'translation and typography share one atomic request'
    Assert-True (-not $manualRequest.preserve_source_pixels) 'translated review does not reveal source pixels'
    $mappedFont = New-LauncherReviewTypographyRequest `
        -RegionId '00000000-0000-0000-0000-000000000002' `
        -Typography $reviewItem.current_typography -FontRole 'HS Yuji'
    Assert-Equal 'HS유지체' $mappedFont.updates[0].typography.preferred_font 'logical review font maps to the exact Koharu family'
    $hanjaDecision = Resolve-LauncherReviewText `
        -Source '日本語の原文' -FirstTranslation '초벌' -FinalTranslation '검토본' `
        -Choice manual -Translation '大韓民國의 수도'
    Assert-Equal '大韓民國의 수도' $hanjaDecision.text 'manual Korean text may intentionally contain Hanja'
    try {
        [void](Resolve-LauncherReviewText `
            -Source '日本語の原文' -FirstTranslation '초벌' -FinalTranslation '검토본' `
            -Choice manual -Translation '日本語の原文')
        throw 'Japanese manual translation unexpectedly succeeded'
    }
    catch { Assert-True ($_.Exception.Message -match 'Japanese') 'Japanese text remains blocked outside explicit source preservation' }

    $metadataOnlyItem = [pscustomobject]@{
        audit_job_id = 'audit-a'
        page_id = '00000000-0000-0000-0000-000000000001'
        page_label = 'page-a'
        region_id = '00000000-0000-0000-0000-000000000002'
        source = '日本語の原文'
        first_translation = '초벌 번역'
        final_translation = '현재 검토 번역'
        current_translation = '현재 검토 번역'
        status = 'failed'
        confidence = 'low'
        semantic_role = 'dialogue'
        font_role = 'Gowun Dodum'
        issues = @('none')
        validator_defects = @('failed', 'low_confidence', 'review_metadata')
        blocking_defects = @()
        expected_revision = 41
        layer_available = $true
        current_typography = $existingTypography
        retry_available = $true
    }
    Assert-True (Test-LauncherMetadataOnlyReviewItem -Item $metadataOnlyItem) 'nonblocking live-matched metadata-only review is eligible for explicit fast approval'
    foreach ($unsafeMetadataItem in @(
        [pscustomobject]@{ value = 'source_residual'; property = 'validator_defects' },
        [pscustomobject]@{ value = 'meaning_error'; property = 'issues' },
        [pscustomobject]@{ value = '다른 live 번역'; property = 'current_translation' },
        [pscustomobject]@{ value = $false; property = 'layer_available' }
    )) {
        $candidate = $metadataOnlyItem.PSObject.Copy()
        if ($unsafeMetadataItem.property -in @('validator_defects', 'issues')) {
            $candidate.($unsafeMetadataItem.property) = @($unsafeMetadataItem.value)
        }
        else {
            $candidate.($unsafeMetadataItem.property) = $unsafeMetadataItem.value
        }
        Assert-True (-not (Test-LauncherMetadataOnlyReviewItem -Item $candidate)) "fast approval rejects unsafe metadata item: $($unsafeMetadataItem.property)"
    }
    $effectItem = $metadataOnlyItem.PSObject.Copy()
    $effectItem.audit_job_id = 'audit-effect'
    $effectItem.region_id = '00000000-0000-0000-0000-000000000003'
    $effectItem.semantic_role = 'handwritten_effect'
    $effectItem.font_role = 'HS Yuji'
    $effectItem.issues = @('source_residual')
    $effectItem.validator_defects = @('source_residual', 'failed', 'low_confidence')
    Assert-True (Test-LauncherUncertainSoundEffectReviewItem -Item $effectItem) 'an uncertain handwritten effect is eligible for original-pixel preservation'
    $effectByIssue = $effectItem.PSObject.Copy()
    $effectByIssue.semantic_role = 'dialogue'
    $effectByIssue.font_role = 'Gowun Dodum'
    $effectByIssue.issues = @('sound_effect', 'voice_or_register')
    Assert-True (Test-LauncherUncertainSoundEffectReviewItem -Item $effectByIssue) 'an explicit sound-effect issue is eligible even when its font metadata is wrong'
    $proseItem = $effectItem.PSObject.Copy()
    $proseItem.audit_job_id = 'audit-prose'
    $proseItem.region_id = '00000000-0000-0000-0000-000000000004'
    $proseItem.semantic_role = 'dialogue'
    $proseItem.font_role = 'Gowun Dodum'
    Assert-True (-not (Test-LauncherUncertainSoundEffectReviewItem -Item $proseItem)) 'uncertain dialogue is retained for prose retry instead of being discarded as an effect'
    $unavailableProse = $proseItem.PSObject.Copy()
    $unavailableProse.audit_job_id = 'audit-unavailable'
    $unavailableProse.region_id = '00000000-0000-0000-0000-000000000005'
    $unavailableProse.layer_available = $false
    $classification = & (Get-Module launcher-core) {
        param($items)
        ConvertTo-LauncherLocalResolutionPlan -Items $items
    } @($metadataOnlyItem, $effectItem, $proseItem, $unavailableProse)
    Assert-Equal 1 @($classification.metadata_items).Count 'local plan keeps verified metadata items in the automatic group'
    Assert-Equal 1 @($classification.effect_items).Count 'local plan keeps verified effects in the source-preservation group'
    Assert-Equal 1 @($classification.prose_items).Count 'local plan keeps only available prose in the retry group'
    Assert-Equal 1 @($classification.unavailable_items).Count 'a transient scene read failure is isolated from every mutating batch'
    Assert-Equal 1 @($classification.prose_retry_pages).Count 'an unavailable item cannot add a spurious retry page'

    $pages = @(
        [pscustomobject]@{ id = 'page-b'; source_asset = 'b.png' },
        [pscustomobject]@{ id = 'page-a'; source_asset = 'a.png' }
    )
    $jobs = @(
        [pscustomobject]@{ id = 'project-failed'; state = 'failed' },
        [pscustomobject]@{ id = 'page-retry'; state = 'finished' }
    )
    $projectActions = @([pscustomobject]@{
        action = 'project_job_started'; action_id = 'start-failed'; project = 'project-a';
        koharu_job_id = 'project-failed'; page_identity = @('page-a|a.png', 'page-b|b.png')
    })
    Assert-Equal 'failed' (Get-LauncherProjectJobState -Jobs $jobs -ReviewActions $projectActions -ProjectName 'project-a' -CurrentPages $pages) 'page retry success does not imply full project completion'
    $projectActions += [pscustomobject]@{
        action = 'project_job_started'; action_id = 'start-finished'; project = 'project-a';
        koharu_job_id = 'project-finished'; page_identity = @('page-b|b.png', 'page-a|a.png')
    }
    $jobs += [pscustomobject]@{ id = 'project-finished'; state = 'finished' }
    Assert-Equal 'finished' (Get-LauncherProjectJobState -Jobs $jobs -ReviewActions $projectActions -ProjectName 'project-a' -CurrentPages $pages) 'later exact full project completion is recognized'
    $persistedActions = @(
        [pscustomobject]@{ action = 'project_job_started'; action_id = 'persisted-start'; project = 'project-a'; koharu_job_id = 'persisted-job'; page_identity = @('page-a|a.png', 'page-b|b.png') },
        [pscustomobject]@{ action = 'project_job_finished'; start_action_id = 'persisted-start'; project = 'project-a'; koharu_job_id = 'persisted-job'; state = 'finished' }
    )
    Assert-Equal 'finished' (Get-LauncherProjectJobState -Jobs @() -ReviewActions $persistedActions -ProjectName 'project-a' -CurrentPages $pages) 'finished project state survives a Koharu restart'
    $changedPages = @($pages[0], [pscustomobject]@{ id = 'page-c'; source_asset = 'c.png' })
    Assert-Equal 'outdated' (Get-LauncherProjectJobState -Jobs @() -ReviewActions $persistedActions -ProjectName 'project-a' -CurrentPages $changedPages) 'a changed page set invalidates old completion'

    $baseStatus = [pscustomobject]@{
        healthy = $true
        recorded = $true
        project = [pscustomobject]@{ name = 'project-a' }
        jobs = @()
        review_count = 0
        project_job_state = 'finished'
    }
    Assert-Equal 'export' (Get-LauncherRecommendedAction -Status $baseStatus) 'persisted completion recommends export after restart'
    $baseStatus.review_count = 2
    Assert-Equal 'review' (Get-LauncherRecommendedAction -Status $baseStatus) 'pending review takes precedence over export'
    $baseStatus.project_job_state = 'failed'
    Assert-Equal 'run' (Get-LauncherRecommendedAction -Status $baseStatus) 'failed full-project work recommends a bounded rerun before partial reviews'
    $baseStatus.project = $null
    Assert-Equal 'prepare' (Get-LauncherRecommendedAction -Status $baseStatus) 'healthy service without a project recommends prepare'
    $baseStatus.healthy = $false
    Assert-Equal 'stop' (Get-LauncherRecommendedAction -Status $baseStatus) 'unhealthy recorded service recommends exact shutdown'
    $baseStatus.recorded = $false
    Assert-Equal 'validate' (Get-LauncherRecommendedAction -Status $baseStatus) 'unrecorded service recommends validation'
    Assert-Equal $null (Get-LauncherProjectJobState -Jobs @() -ReviewActions $persistedActions -ProjectName 'project-b') 'another project completion is not reused'
    Assert-Equal 'interrupted' (Get-LauncherProjectJobState -Jobs @() -ReviewActions @($persistedActions[0]) -ProjectName 'project-a') 'an unclosed project job is not treated as successful'
    Assert-True (& (Get-Module launcher-core) { Test-LauncherRetryFailureConsumesAttempt -Message 'UNRESOLVED_TRANSLATION' }) 'an unusable translation consumes the one retry'
    Assert-True (-not (& (Get-Module launcher-core) { Test-LauncherRetryFailureConsumesAttempt -Message 'QWEN_BUSY' })) 'shared-runtime contention does not consume the retry'
    Assert-True (-not (& (Get-Module launcher-core) { Test-LauncherRetryFailureConsumesAttempt -Message 'Pipeline job was stopped' })) 'operator cancellation does not consume the retry'
    Assert-True (-not (& (Get-Module launcher-core) { Test-LauncherRetryFailureConsumesAttempt -Message 'Another Koharu pipeline job is already running.' })) 'a preflight busy rejection does not consume the retry'

    $configDirectory = Join-Path $testRoot '.koharu'
    [void](New-Item -ItemType Directory -Path $configDirectory)
    $configPath = Join-Path $configDirectory 'config.toml'
    $originalBytes = [Text.UTF8Encoding]::new($true).GetBytes("alpha = 'β'`r`n")
    [IO.File]::WriteAllBytes($configPath, $originalBytes)
    $observedProfile = Invoke-WithKoharuSessionConfig -ServicePort 4020 -ConfigPath $configPath -ProcessLookup { @() } -Action {
        Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    }
    Assert-True ($observedProfile -match '\[pipeline.translation.model\]') 'action sees temporary session config'
    $restoredBytes = [IO.File]::ReadAllBytes($configPath)
    Assert-Equal ([Convert]::ToBase64String($originalBytes)) ([Convert]::ToBase64String($restoredBytes)) 'original config bytes are restored after success'

    try {
        Invoke-WithKoharuSessionConfig -ServicePort 4020 -ConfigPath $configPath -ProcessLookup { @() } -Action { throw 'expected action failure' }
        throw 'failure action unexpectedly succeeded'
    }
    catch {
        Assert-True ($_.Exception.Message -match 'expected action failure') 'action failure is propagated'
    }
    $restoredAfterFailure = [IO.File]::ReadAllBytes($configPath)
    Assert-Equal ([Convert]::ToBase64String($originalBytes)) ([Convert]::ToBase64String($restoredAfterFailure)) 'original config bytes are restored after failure'

    $recoveryRoot = Join-Path $testRoot 'recovery-run'
    [void](New-Item -ItemType Directory -Path $recoveryRoot)
    $recoveryConfig = Join-Path $configDirectory 'recover.toml'
    $recoveryOriginal = [Text.UTF8Encoding]::new($false).GetBytes("original = true`n")
    $recoverySession = [Text.UTF8Encoding]::new($false).GetBytes("session = true`n")
    [IO.File]::WriteAllBytes($recoveryConfig, $recoverySession)
    $recoveryId = '0123456789abcdef0123456789abcdef'
    $recoveryBackup = Join-Path $recoveryRoot "koharu-config.$recoveryId.backup"
    [IO.File]::WriteAllBytes($recoveryBackup, $recoveryOriginal)
    [pscustomobject]@{
        schema_version = 2
        config_path = [IO.Path]::GetFullPath($recoveryConfig)
        backup_path = $recoveryBackup
        original_existed = $true
        original_sha256 = (Get-FileHash -LiteralPath $recoveryBackup -Algorithm SHA256).Hash
        session_sha256 = (Get-FileHash -LiteralPath $recoveryConfig -Algorithm SHA256).Hash
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $recoveryRoot "koharu-config.$recoveryId.json") -Encoding utf8NoBOM
    $launcherModule = Get-Module launcher-core
    & $launcherModule { param($path, $root) Restore-InterruptedKoharuSessionConfig -ConfigPath $path -RunRoot $root } $recoveryConfig $recoveryRoot
    Assert-Equal ([Convert]::ToBase64String($recoveryOriginal)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($recoveryConfig))) 'interrupted session config is restored from its verified backup'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $recoveryRoot -File).Count 'successful recovery removes its transaction files'

    $inputDirectory = Join-Path $testRoot 'inputs'
    [void](New-Item -ItemType Directory -Path $inputDirectory)
    foreach ($name in @('page10.png', 'page2.png', 'page1.jpg', 'notes.txt')) {
        Set-Content -LiteralPath (Join-Path $inputDirectory $name) -Value $name -Encoding utf8NoBOM
    }
    $inputs = @(Get-SupportedInputFiles -InputPath $inputDirectory | ForEach-Object { Split-Path -Leaf $_ })
    Assert-Equal 3 $inputs.Count 'only supported files are returned'
    Assert-Equal 'page1.jpg' $inputs[0] 'natural sort first item'
    Assert-Equal 'page2.png' $inputs[1] 'natural sort second item'
    Assert-Equal 'page10.png' $inputs[2] 'natural sort third item'

    $nonemptyOutput = Join-Path $testRoot 'nonempty-output'
    [void](New-Item -ItemType Directory -Path $nonemptyOutput)
    Set-Content -LiteralPath (Join-Path $nonemptyOutput 'keep.txt') -Value 'keep' -Encoding utf8NoBOM
    $renderProbe = @{ called = $false }
    try {
        [void](Invoke-LauncherExportTransaction -Directory $nonemptyOutput -Format png -ExpectedPageCount 1 -RenderAction {
            param($staging)
            $renderProbe.called = $true
        })
        throw 'nonempty export destination unexpectedly succeeded'
    }
    catch { Assert-True ($_.Exception.Message -match 'not empty') 'nonempty export destination is rejected before rendering' }
    Assert-True (-not $renderProbe.called) 'nonempty destination does not start an export'
    Assert-Equal 'keep' ((Get-Content -LiteralPath (Join-Path $nonemptyOutput 'keep.txt') -Raw).Trim()) 'existing output is preserved'

    $failedOutput = Join-Path $testRoot 'failed-output'
    try {
        [void](Invoke-LauncherExportTransaction -Directory $failedOutput -Format png -ExpectedPageCount 2 -RenderAction {
            param($staging)
            [void](New-Item -ItemType Directory -Path $staging)
            [IO.File]::WriteAllBytes((Join-Path $staging '0001.png'), [byte[]](1, 2, 3))
            throw 'simulated render failure'
        })
        throw 'failed render unexpectedly succeeded'
    }
    catch { Assert-True ($_.Exception.Message -match 'simulated render failure') 'render failure is propagated' }
    Assert-True (-not (Test-Path -LiteralPath $failedOutput)) 'failed export publishes no destination'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $testRoot -Filter '.failed-output.koharu-export-*' -Force).Count 'failed export removes only its private staging directory'

    $publishedOutput = Join-Path $testRoot 'published-output'
    $published = Invoke-LauncherExportTransaction -Directory $publishedOutput -Format png -ExpectedPageCount 2 -RenderAction {
        param($staging)
        [void](New-Item -ItemType Directory -Path $staging)
        [IO.File]::WriteAllBytes((Join-Path $staging '0001.png'), [byte[]](1, 2, 3))
        [IO.File]::WriteAllBytes((Join-Path $staging '0002.png'), [byte[]](4, 5, 6))
    }
    Assert-True $published.exported 'complete staging is published'
    Assert-Equal 2 @(Get-ChildItem -LiteralPath $publishedOutput -File).Count 'published output contains every expected page'

    $emptyOutput = Join-Path $testRoot 'empty-output'
    [void](New-Item -ItemType Directory -Path $emptyOutput)
    $emptyPublished = Invoke-LauncherExportTransaction -Directory $emptyOutput -Format psd -ExpectedPageCount 1 -RenderAction {
        param($staging)
        [void](New-Item -ItemType Directory -Path $staging)
        [IO.File]::WriteAllBytes((Join-Path $staging '0001.psd'), [byte[]](7, 8, 9))
    }
    Assert-True $emptyPublished.exported 'an unchanged empty destination is safely replaced'
    Assert-True (Test-Path -LiteralPath (Join-Path $emptyOutput '0001.psd') -PathType Leaf) 'empty destination receives the completed export'

    $runtime = Join-Path $testRoot 'runtime'
    $model = Join-Path $runtime 'model'
    [void](New-Item -ItemType Directory -Path $model -Force)
    foreach ($name in @('python.exe', 'koharu.exe', 'lifecycle.ps1')) {
        Set-Content -LiteralPath (Join-Path $runtime $name) -Value 'test' -Encoding utf8NoBOM
    }
    $weightPath = Join-Path $model 'weights.bin'
    Set-Content -LiteralPath $weightPath -Value 'test-model' -Encoding utf8NoBOM -NoNewline
    $weight = Get-Item -LiteralPath $weightPath
    [pscustomobject]@{
        schema_version = 1
        model = 'hy-mt2-7b'
        repo_id = 'tencent/Hy-MT2-7B'
        revision = '9b0eb4e8f001def3e5ff6469a0ac96fdb39ec223'
        total_bytes = [int64]$weight.Length
        files = @([pscustomobject]@{
            path = 'weights.bin'
            size_bytes = [int64]$weight.Length
            sha256 = (Get-FileHash -LiteralPath $weightPath -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $model 'download-manifest.json') -Encoding utf8NoBOM
    $leaseDirectory = Join-Path $runtime 'coordination'
    [void](New-Item -ItemType Directory -Path $leaseDirectory)
    $settings = [pscustomobject]@{
        python_executable = (Join-Path $runtime 'python.exe')
        koharu_executable = (Join-Path $runtime 'koharu.exe')
        qwen_lifecycle_script = (Join-Path $runtime 'lifecycle.ps1')
        qwen_api = 'http://127.0.0.1:8000/v1'
        qwen_model = 'test-model'
        qwen_lease_path = (Join-Path $leaseDirectory 'qwen-use.lock')
        hy_model_directory = $model
        koharu_port = 4010
        service_port = 4020
        export_format = 'png'
    }
    $validation = Assert-LauncherSettings -Settings $settings
    Assert-True $validation.valid 'valid runtime settings pass validation'

    $mockItemA = $metadataOnlyItem.PSObject.Copy()
    $mockItemA.region_id = '00000000-0000-0000-0000-000000000011'
    $mockItemA.page_id = '00000000-0000-0000-0000-000000000021'
    $mockItemA.page_label = 'page-1'
    $mockItemA.audit_job_id = 'audit-1'
    $mockItemB = $metadataOnlyItem.PSObject.Copy()
    $mockItemB.region_id = '00000000-0000-0000-0000-000000000012'
    $mockItemB.page_id = '00000000-0000-0000-0000-000000000022'
    $mockItemB.page_label = 'page-2'
    $mockItemB.audit_job_id = 'audit-2'
    $launcherModule = Get-Module launcher-core
    & $launcherModule {
        param($items)
        $script:MetadataBatchMockItems = @($items)
        $script:MetadataBatchMockAccepted = @{}
        $script:MetadataBatchMockRevision = [int64]41
        $script:MetadataBatchMockRequests = [System.Collections.Generic.List[object]]::new()
        $script:MetadataBatchMockActions = [System.Collections.Generic.List[object]]::new()
        Set-Item -Path Function:\Get-LauncherReviewItems -Value {
            param([object]$Settings, [switch]$SkipLayerValidation)
            return @($script:MetadataBatchMockItems | Where-Object {
                -not $script:MetadataBatchMockAccepted.ContainsKey([string]$_.region_id)
            })
        }
        Set-Item -Path Function:\Invoke-KoharuApi -Value {
            param([int]$Port, [string]$Path, [string]$Method = 'GET', [object]$Body, [int]$TimeoutSeconds = 10)
            if ($Path -eq 'project') {
                return [pscustomobject]@{ name = 'project-a'; revision = $script:MetadataBatchMockRevision }
            }
            if ($Path -eq 'review/decision' -and $Method -eq 'POST') {
                if ([int64]$Body.expected_revision -ne $script:MetadataBatchMockRevision) {
                    throw 'mock revision mismatch'
                }
                $script:MetadataBatchMockRequests.Add([pscustomobject]$Body)
                $script:MetadataBatchMockRevision++
                return [pscustomobject]@{ revision = $script:MetadataBatchMockRevision }
            }
            throw "unexpected mock API request: $Method $Path"
        }
        Set-Item -Path Function:\Add-LauncherReviewAction -Value {
            param([hashtable]$Data)
            $script:MetadataBatchMockActions.Add([pscustomobject]$Data)
            if ([string]$Data.action -eq 'review_batch_accepted_existing') {
                foreach ($item in @($Data.items)) { $script:MetadataBatchMockAccepted[[string]$item.region_id] = $true }
            }
            else { $script:MetadataBatchMockAccepted[[string]$Data.region_id] = $true }
            return [pscustomobject]$Data
        }
    } @($mockItemA, $mockItemB)
    $batchProgress = [System.Collections.Generic.List[object]]::new()
    $batchResult = Approve-LauncherMetadataOnlyReviews -Settings ([pscustomobject]@{ koharu_port = 4010 }) -OnProgress {
        param($progress)
        $batchProgress.Add($progress)
    }
    Assert-Equal 2 $batchResult.applied 'metadata batch applies every eligible item once'
    Assert-Equal 0 $batchResult.remaining 'metadata batch leaves no mocked review item unresolved'
    Assert-Equal 41 $batchResult.start_revision 'metadata batch pins its starting revision'
    Assert-Equal 43 $batchResult.end_revision 'metadata batch advances the revision once per decision'
    $batchEvidence = & $launcherModule {
        [pscustomobject]@{
            requests = @($script:MetadataBatchMockRequests)
            actions = @($script:MetadataBatchMockActions)
        }
    }
    Assert-Equal 2 @($batchEvidence.requests).Count 'metadata batch sends one API request per item'
    Assert-Equal 41 $batchEvidence.requests[0].expected_revision 'first metadata decision uses the initial revision'
    Assert-Equal 42 $batchEvidence.requests[1].expected_revision 'second metadata decision uses the advanced revision'
    Assert-Equal 'Gowun Dodum' $batchEvidence.requests[0].typography.preferred_font 'metadata batch reapplies the audited exact font'
    Assert-Equal 2 @($batchEvidence.actions).Count 'metadata batch records every successful decision'
    Assert-Equal 2 @($batchProgress).Count 'metadata batch reports monotonic progress'

    $effectBatchA = $effectItem.PSObject.Copy()
    $effectBatchA.audit_job_id = 'effect-audit-1'
    $effectBatchA.page_id = '00000000-0000-0000-0000-000000000031'
    $effectBatchA.page_label = 'effect-page-1'
    $effectBatchA.region_id = '00000000-0000-0000-0000-000000000041'
    $effectBatchA.expected_revision = 50
    $effectBatchB = $effectBatchA.PSObject.Copy()
    $effectBatchB.audit_job_id = 'effect-audit-2'
    $effectBatchB.page_id = '00000000-0000-0000-0000-000000000032'
    $effectBatchB.page_label = 'effect-page-2'
    $effectBatchB.region_id = '00000000-0000-0000-0000-000000000042'
    & $launcherModule {
        param($items)
        $script:MetadataBatchMockItems = @($items)
        $script:MetadataBatchMockAccepted = @{}
        $script:MetadataBatchMockRevision = [int64]50
        $script:MetadataBatchMockRequests.Clear()
        $script:MetadataBatchMockActions.Clear()
    } @($effectBatchA, $effectBatchB)
    $sourceBatch = Preserve-LauncherUncertainSoundEffects -Settings ([pscustomobject]@{ koharu_port = 4010 })
    Assert-Equal 2 $sourceBatch.applied 'uncertain effect batch preserves every safe effect once'
    Assert-Equal 0 $sourceBatch.remaining 'uncertain effect batch resolves the mocked review list'
    $sourceEvidence = & $launcherModule {
        [pscustomobject]@{
            requests = @($script:MetadataBatchMockRequests)
            actions = @($script:MetadataBatchMockActions)
        }
    }
    Assert-Equal 2 @($sourceEvidence.requests).Count 'effect preservation sends one revision-pinned decision per region'
    Assert-True ($null -eq $sourceEvidence.requests[0].text) 'effect preservation sends no replacement text'
    Assert-True ($null -eq $sourceEvidence.requests[0].typography) 'effect preservation sends no translated typography'
    Assert-True ([bool]$sourceEvidence.requests[0].preserve_source_pixels) 'effect preservation restores original pixels'
    Assert-Equal 'source_batch_uncertain_effect' ([string]$sourceEvidence.actions[0].choice) 'effect preservation records its explicit local policy'

    $allOkA = $proseItem.PSObject.Copy()
    $allOkA.audit_job_id = 'ok-audit-1'
    $allOkA.page_id = '00000000-0000-0000-0000-000000000051'
    $allOkA.page_label = 'ok-page-1'
    $allOkA.region_id = '00000000-0000-0000-0000-000000000061'
    $allOkA.expected_revision = 61
    $allOkA.blocking_defects = @()
    $allOkB = $allOkA.PSObject.Copy()
    $allOkB.audit_job_id = 'ok-audit-2'
    $allOkB.region_id = '00000000-0000-0000-0000-000000000062'
    & $launcherModule {
        param($items)
        $script:MetadataBatchMockItems = @($items)
        $script:MetadataBatchMockAccepted = @{}
        $script:MetadataBatchMockRevision = [int64]61
        $script:MetadataBatchMockRequests.Clear()
        $script:MetadataBatchMockActions.Clear()
    } @($allOkA, $allOkB)
    $allOkResult = Approve-LauncherAllExistingReviews -Settings ([pscustomobject]@{ koharu_port = 4010 })
    Assert-Equal 2 $allOkResult.accepted 'skipping review accepts every verified live nonblocking item'
    $allOkEvidence = & $launcherModule {
        [pscustomobject]@{
            requests = @($script:MetadataBatchMockRequests)
            actions = @($script:MetadataBatchMockActions)
        }
    }
    Assert-Equal 0 @($allOkEvidence.requests).Count 'all-OK acceptance does not regenerate or mutate translations'
    Assert-Equal 1 @($allOkEvidence.actions).Count 'all-OK acceptance is one atomic audit record'
    Assert-Equal 'review_batch_accepted_existing' ([string]$allOkEvidence.actions[0].action) 'all-OK audit record has a distinct action type'
    Assert-Equal 2 @($allOkEvidence.actions[0].items).Count 'all-OK audit record retains every accepted item identity'

    $blockingAllOk = $allOkA.PSObject.Copy()
    $blockingAllOk.blocking_defects = @('empty')
    & $launcherModule {
        param($item)
        $script:MetadataBatchMockItems = @($item)
        $script:MetadataBatchMockAccepted = @{}
        $script:MetadataBatchMockRevision = [int64]61
    } $blockingAllOk
    try {
        [void](Approve-LauncherAllExistingReviews -Settings ([pscustomobject]@{ koharu_port = 4010 }))
        throw 'blocking all-OK review unexpectedly succeeded'
    }
    catch { Assert-True ($_.Exception.Message -match 'blocking defect') 'all-OK cannot conceal an empty or otherwise unusable translation' }

    & $launcherModule {
        $script:ProseRetryMockCalls = [System.Collections.Generic.List[string]]::new()
        Set-Item -Path Function:\Get-LauncherLocalResolutionPlan -Value {
            param([object]$Settings)
            return [pscustomobject]@{
                items = @('pending-a', 'pending-b')
                prose_retry_pages = @(
                    [pscustomobject]@{ page_id = 'page-a'; page_label = 'page-a' },
                    [pscustomobject]@{ page_id = 'page-b'; page_label = 'page-b' }
                )
            }
        }
        Set-Item -Path Function:\Invoke-LauncherReviewRetry -Value {
            param([object]$Settings, [string]$PageId, [scriptblock]$OnStarted, [scriptblock]$OnProgress)
            $script:ProseRetryMockCalls.Add($PageId)
            if ($PageId -ceq 'page-a') { throw 'Pipeline job failed: UNRESOLVED_TRANSLATION' }
            return [pscustomobject]@{ state = 'finished' }
        }
        Set-Item -Path Function:\Get-LauncherReviewItems -Value {
            param([object]$Settings, [switch]$SkipLayerValidation)
            return @()
        }
    }
    $proseBatch = Invoke-LauncherProseReviewRetryBatch -Settings ([pscustomobject]@{ koharu_port = 4010 })
    Assert-Equal 2 $proseBatch.attempted 'prose retry snapshots each eligible page exactly once'
    Assert-Equal 1 $proseBatch.succeeded 'a semantic failure does not prevent the next distinct page from being tried'
    Assert-Equal 1 @($proseBatch.failed).Count 'a semantic failure is returned for later manual handling'
    $proseCalls = & $launcherModule { @($script:ProseRetryMockCalls) }
    Assert-Equal 2 @($proseCalls).Count 'prose retry never loops a failed page'
    Assert-Equal 'page-a' $proseCalls[0] 'prose retry preserves deterministic page order'
    Assert-Equal 'page-b' $proseCalls[1] 'prose retry advances after one consumed semantic failure'

    'launcher-core tests passed'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
