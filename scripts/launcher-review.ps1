# Dot-sourced by launcher-core.psm1 after shared helpers and translation policy initialization.

function Get-LauncherReviewActionPath {
    return Join-Path (Get-LauncherRoot) 'run\review-actions.jsonl'
}

function Get-LauncherReviewActions {
    $path = Get-LauncherReviewActionPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $actions = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $path -Encoding utf8) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $actions.Add(($line | ConvertFrom-Json)) }
        catch { throw "Review action history is invalid at line $lineNumber." }
    }
    return @($actions)
}

function Add-LauncherReviewAction {
    param([Parameter(Mandatory)][hashtable]$Data)

    $path = Get-LauncherReviewActionPath
    $directory = Split-Path -Parent $path
    [void](New-Item -ItemType Directory -Force -Path $directory)
    $record = [ordered]@{
        schema_version = 1
        action_id = [guid]::NewGuid().ToString()
        timestamp_utc = [datetime]::UtcNow.ToString('o')
    }
    foreach ($entry in $Data.GetEnumerator()) { $record[$entry.Key] = $entry.Value }
    $json = ([pscustomobject]$record | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
    [IO.File]::AppendAllText($path, $json, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]$record
}

function Test-LauncherRetryFailureConsumesAttempt {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    if ($Message -match 'REQUEST_CANCELLED|Pipeline job was stopped') { return $false }
    if ($Message -match 'UNRESOLVED_TRANSLATION') { return $true }
    if ($Message -match 'QWEN_|SPECIALIST_|CHILD_TIMEOUT|PROCESS_TREE_UNSAFE|PIPELINE_BUSY|KOHARU_(?:SCENE|TYPOGRAPHY)_FAILED|Another Koharu pipeline job is already running|Koharu is not ready for a review retry') {
        return $false
    }
    return $true
}

function Get-LauncherReviewItems {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [switch]$SkipLayerValidation
    )

    $port = [int]$Settings.koharu_port
    $projectBefore = Invoke-KoharuApi -Port $port -Path 'project' -TimeoutSeconds 10
    if ($null -eq $projectBefore) { throw 'No Koharu project is open.' }
    $projectRevision = [int64]$projectBefore.revision
    $pages = @((Invoke-KoharuApi -Port $port -Path 'pages' -TimeoutSeconds 10) | ForEach-Object { $_ })
    if ($pages.Count -eq 0) { return @() }
    $pageMap = @{}
    foreach ($page in $pages) { $pageMap[[string]$page.id] = $page }

    $reviewRoot = Join-Path (Get-LauncherRoot) 'run\reviews'
    if (-not (Test-Path -LiteralPath $reviewRoot -PathType Container)) { return @() }
    $latest = @{}
    $files = @(Get-ChildItem -LiteralPath $reviewRoot -Filter 'review.jsonl' -File -Recurse | Sort-Object LastWriteTimeUtc, FullName)
    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding utf8) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $record = $line | ConvertFrom-Json }
            catch { throw "Review audit is invalid: $($file.FullName), line $lineNumber." }
            $pageId = [string]$record.page_id
            $regionId = [string]$record.region_id
            if (-not $pageMap.ContainsKey($pageId) -or [string]::IsNullOrWhiteSpace($regionId)) { continue }
            $key = "$pageId|$regionId"
            $latest[$key] = [pscustomobject]@{
                audit = $record
                audit_modified_utc = $file.LastWriteTimeUtc
            }
        }
    }

    $actions = @(Get-LauncherReviewActions)
    $accepted = @{}
    $retryAttempts = @{}
    foreach ($action in $actions) {
        if ([string]$action.action -in @('translation_applied', 'review_decision_applied')) {
            $accepted["$([string]$action.audit_job_id)|$([string]$action.region_id)"] = $true
        }
        elseif ([string]$action.action -eq 'review_batch_accepted_existing') {
            foreach ($acceptedItem in @($action.items)) {
                $accepted["$([string]$acceptedItem.audit_job_id)|$([string]$acceptedItem.region_id)"] = $true
            }
        }
        elseif ([string]$action.action -eq 'page_retry_started') {
            $retryAttempts[[string]$action.koharu_job_id] = [pscustomobject]@{
                page_id = [string]$action.page_id
                state = 'started'
                consumes_retry = $true
            }
        }
        elseif ([string]$action.action -eq 'page_retry_finished') {
            $retryJobId = [string]$action.koharu_job_id
            if ($retryAttempts.ContainsKey($retryJobId)) {
                $retryAttempts[$retryJobId].state = [string]$action.state
                $retryAttempts[$retryJobId].consumes_retry = if ($null -ne $action.PSObject.Properties['consumes_retry']) {
                    [bool]$action.consumes_retry
                }
                else {
                    [string]$action.state -ne 'failed'
                }
            }
        }
    }
    $retriedPages = @{}
    foreach ($attempt in $retryAttempts.Values) {
        if ([bool]$attempt.consumes_retry) { $retriedPages[[string]$attempt.page_id] = $true }
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $latest.GetEnumerator()) {
        $record = $entry.Value.audit
        $defects = @($record.validator_defects | Where-Object { $null -ne $_ })
        $reviewRequired = if ($record.PSObject.Properties.Name -contains 'review_required') {
            [bool]$record.review_required
        }
        else {
            [string]$record.status -eq 'failed' -or $defects.Count -gt 0
        }
        if (-not $reviewRequired) { continue }
        $auditJobId = [string]$record.job_id
        $regionId = [string]$record.region_id
        if ($accepted.ContainsKey("$auditJobId|$regionId")) { continue }
        $blocking = if ($record.PSObject.Properties.Name -contains 'blocking_defects') {
            @($record.blocking_defects | Where-Object { $null -ne $_ })
        }
        else {
            @($defects | Where-Object { $_ -in @('empty', 'source_residual', 'placeholder', 'unresolved_status') })
        }
        $pageId = [string]$record.page_id
        $candidates.Add([pscustomobject]@{
            audit_job_id = $auditJobId
            page_id = $pageId
            page_label = [string]$pageMap[$pageId].label
            region_id = $regionId
            source = [string]$record.source
            first_translation = [string]$record.first_translation
            final_translation = [string]$record.final_translation
            status = [string]$record.status
            confidence = [string]$record.confidence
            semantic_role = [string]$record.semantic_role
            font_role = [string]$record.font_role
            issues = @($record.issues)
            validator_defects = $defects
            blocking_defects = $blocking
            retry_available = -not $retriedPages.ContainsKey($pageId)
            expected_revision = $projectRevision
            layer_available = $true
            availability_error = $null
            current_translation = $null
            current_typography = $null
        })
    }

    if (-not $SkipLayerValidation) {
        foreach ($pageGroup in @($candidates | Group-Object page_id)) {
            try {
                $scene = Invoke-KoharuApi -Port $port -Path "pages/$($pageGroup.Name)" -TimeoutSeconds 10
                $textLayers = @{}
                foreach ($layer in @($scene.layers)) {
                    if ([string]$layer.type -eq 'text') { $textLayers[[string]$layer.id] = $layer }
                }
                foreach ($candidate in $pageGroup.Group) {
                    $candidate.layer_available = $textLayers.ContainsKey([string]$candidate.region_id)
                    if (-not $candidate.layer_available) {
                        $candidate.availability_error = '현재 프로젝트에서 이 텍스트 영역을 찾을 수 없습니다.'
                        continue
                    }
                    $layer = $textLayers[[string]$candidate.region_id]
                    $candidate.current_translation = [string]$layer.content.translation.text
                    $candidate.current_typography = $layer.typography
                    if ([string]::IsNullOrWhiteSpace([string]$candidate.current_translation)) {
                        $candidate.layer_available = $false
                        $candidate.availability_error = '현재 텍스트 영역의 적용된 번역을 읽을 수 없습니다.'
                        continue
                    }
                    if ($null -eq $candidate.current_typography) {
                        $candidate.layer_available = $false
                        $candidate.availability_error = '현재 텍스트 영역의 글꼴 설정을 읽을 수 없습니다.'
                    }
                }
            }
            catch {
                foreach ($candidate in $pageGroup.Group) {
                    $candidate.layer_available = $false
                    $candidate.availability_error = '현재 페이지 상태를 확인하지 못했습니다.'
                }
            }
        }
    }
    $projectAfter = Invoke-KoharuApi -Port $port -Path 'project' -TimeoutSeconds 10
    if ($null -eq $projectAfter -or [int64]$projectAfter.revision -ne $projectRevision) {
        throw 'The Koharu project changed while the review list was loading. Refresh the review list.'
    }
    return @($candidates | Sort-Object page_label, region_id)
}

function New-LauncherReviewTypographyRequest {
    param(
        [Parameter(Mandatory)][string]$RegionId,
        [Parameter(Mandatory)][object]$Typography,
        [Parameter(Mandatory)][string]$FontRole
    )

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($RegionId, [ref]$parsed)) { throw 'Review region ID is invalid.' }
    if ($FontRole -cnotin $script:LauncherReviewFonts) { throw "Review font role is invalid: $FontRole" }
    $copy = [ordered]@{}
    if ($Typography -is [System.Collections.IDictionary]) {
        foreach ($key in $Typography.Keys) { $copy[[string]$key] = $Typography[$key] }
    }
    else {
        foreach ($property in $Typography.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    }
    if ($copy.Count -eq 0) { throw 'Current typography is unavailable.' }
    $copy['preferred_font'] = [string]$script:LauncherReviewFontFamilies[$FontRole]
    return [ordered]@{
        updates = @([ordered]@{
            layer = $RegionId
            typography = $copy
        })
    }
}

function Resolve-LauncherReviewText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Source,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FirstTranslation,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FinalTranslation,
        [Parameter(Mandatory)][ValidateSet('first', 'final', 'manual', 'source')][string]$Choice,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Translation
    )

    if ($Choice -eq 'source') {
        if ($Translation -cne $Source) { throw 'The source text changed. Refresh the review list.' }
        return [pscustomobject]@{
            text = $null
            apply_typography = $false
            preserve_source_pixels = $true
        }
    }

    $translation = $Translation.Trim()
    if ([string]::IsNullOrWhiteSpace($translation)) { throw 'A review decision cannot apply an empty translation.' }
    $japanesePattern = if ($Choice -eq 'manual') { '[ぁ-ゖァ-ヺー]' } else { '[一-龯々〆ヵヶぁ-ゖァ-ヺー]' }
    if ($translation -match $japanesePattern) { throw 'The selected translation still contains Japanese source text.' }
    if ($translation -match '(?:<[^>]+>|\{[^}]+\}|\[UNK\]|�|☐|□)') { throw 'The selected translation still contains an unresolved placeholder.' }
    if ($Choice -eq 'first' -and $translation -cne $FirstTranslation) { throw 'The Hy-MT2 candidate changed. Refresh the review list.' }
    if ($Choice -eq 'final' -and $translation -cne $FinalTranslation) { throw 'The Qwen candidate changed. Refresh the review list.' }
    return [pscustomobject]@{
        text = $translation
        apply_typography = $true
        preserve_source_pixels = $false
    }
}

function New-LauncherReviewDecisionRequest {
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$RegionId,
        [Parameter(Mandatory)][object]$Decision
    )

    $typography = $null
    if ([bool]$Decision.apply_typography) {
        $typographyRequest = New-LauncherReviewTypographyRequest `
            -RegionId $RegionId `
            -Typography $Item.current_typography `
            -FontRole ([string]$Item.font_role)
        $typography = $typographyRequest.updates[0].typography
    }
    return [ordered]@{
        expected_revision = [int64]$Item.expected_revision
        layer = $RegionId
        text = $Decision.text
        typography = $typography
        preserve_source_pixels = [bool]$Decision.preserve_source_pixels
    }
}

function Set-LauncherReviewTranslation {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][string]$AuditJobId,
        [Parameter(Mandatory)][string]$RegionId,
        [Parameter(Mandatory)][ValidateSet('first', 'final', 'manual', 'source')][string]$Choice,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Translation
    )

    $item = Get-LauncherReviewItems -Settings $Settings | Where-Object {
        [string]$_.audit_job_id -ceq $AuditJobId -and [string]$_.region_id -ceq $RegionId
    } | Select-Object -First 1
    if ($null -eq $item) { throw 'This review item is stale or already resolved. Refresh the review list.' }
    if (-not $item.layer_available) { throw $item.availability_error }
    $decision = Resolve-LauncherReviewText `
        -Source ([string]$item.source) `
        -FirstTranslation ([string]$item.first_translation) `
        -FinalTranslation ([string]$item.final_translation) `
        -Choice $Choice `
        -Translation $Translation

    $request = New-LauncherReviewDecisionRequest -Item $item -RegionId $RegionId -Decision $decision
    [void](Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'review/decision' -Method POST -Body $request -TimeoutSeconds 30)
    $project = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'project' -TimeoutSeconds 5
    [void](Add-LauncherReviewAction -Data @{
        action = 'review_decision_applied'
        project = [string]$project.name
        page_id = [string]$item.page_id
        region_id = $RegionId
        audit_job_id = $AuditJobId
        choice = $Choice
        expected_revision = [int64]$item.expected_revision
        applied_revision = [int64]$project.revision
        preserve_source_pixels = [bool]$decision.preserve_source_pixels
    })
    return [pscustomobject]@{
        applied = $true
        page_id = [string]$item.page_id
        region_id = $RegionId
        choice = $Choice
        typography_applied = [bool]$decision.apply_typography
    }
}

function Test-LauncherMetadataOnlyReviewItem {
    param([Parameter(Mandatory)][object]$Item)

    if (-not [bool]$Item.layer_available) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Item.final_translation)) { return $false }
    if ([string]$Item.current_translation -cne [string]$Item.final_translation) { return $false }
    $issues = @($Item.issues | Where-Object { $null -ne $_ })
    if ($issues.Count -ne 1 -or [string]$issues[0] -cne 'none') { return $false }
    if (@($Item.blocking_defects | Where-Object { $null -ne $_ }).Count -gt 0) { return $false }
    $allowedDefects = @('failed', 'low_confidence', 'review_metadata')
    if (@($Item.validator_defects | Where-Object { $null -ne $_ -and [string]$_ -cnotin $allowedDefects }).Count -gt 0) {
        return $false
    }
    try {
        $decision = Resolve-LauncherReviewText `
            -Source ([string]$Item.source) `
            -FirstTranslation ([string]$Item.first_translation) `
            -FinalTranslation ([string]$Item.final_translation) `
            -Choice final `
            -Translation ([string]$Item.final_translation)
        [void](New-LauncherReviewDecisionRequest -Item $Item -RegionId ([string]$Item.region_id) -Decision $decision)
    }
    catch { return $false }
    return $true
}

function Get-LauncherMetadataOnlyReviewItems {
    param([Parameter(Mandatory)][object]$Settings)

    return @(Get-LauncherReviewItems -Settings $Settings | Where-Object { Test-LauncherMetadataOnlyReviewItem -Item $_ })
}

function Test-LauncherUncertainSoundEffectReviewItem {
    param([Parameter(Mandatory)][object]$Item)

    # A clean, live-matched translation is metadata-only even when it uses an
    # effect font. It should not be discarded merely because of its lettering.
    if (Test-LauncherMetadataOnlyReviewItem -Item $Item) { return $false }
    $issues = @($Item.issues | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    $defects = @($Item.validator_defects | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    $isEffect = [string]$Item.semantic_role -ceq 'handwritten_effect' -or
        [string]$Item.font_role -cin $script:LauncherHandwrittenEffectFonts -or
        'sound_effect' -cin $issues
    if (-not $isEffect) { return $false }

    return [string]$Item.status -ceq 'failed' -or
        [string]$Item.confidence -ceq 'low' -or
        @($issues | Where-Object { $_ -cin @('sound_effect', 'source_residual', 'ocr_uncertain') }).Count -gt 0 -or
        @($defects | Where-Object { $_ -cin @('source_residual', 'placeholder', 'failed', 'low_confidence') }).Count -gt 0
}

function ConvertTo-LauncherLocalResolutionPlan {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)

    $items = @($Items)
    $unavailable = @($items | Where-Object { -not [bool]$_.layer_available })
    $available = @($items | Where-Object { [bool]$_.layer_available })
    $metadata = @($available | Where-Object { Test-LauncherMetadataOnlyReviewItem -Item $_ })
    $metadataKeys = @{}
    foreach ($item in $metadata) { $metadataKeys["$([string]$item.audit_job_id)|$([string]$item.region_id)"] = $true }

    $effects = @($available | Where-Object {
        -not $metadataKeys.ContainsKey("$([string]$_.audit_job_id)|$([string]$_.region_id)") -and
        (Test-LauncherUncertainSoundEffectReviewItem -Item $_)
    })
    $effectKeys = @{}
    foreach ($item in $effects) { $effectKeys["$([string]$item.audit_job_id)|$([string]$item.region_id)"] = $true }

    $prose = @($available | Where-Object {
        $key = "$([string]$_.audit_job_id)|$([string]$_.region_id)"
        -not $metadataKeys.ContainsKey($key) -and -not $effectKeys.ContainsKey($key)
    })
    $retryPages = @(
        $prose |
            Where-Object { [bool]$_.retry_available } |
            Group-Object page_id |
            ForEach-Object {
                [pscustomobject]@{
                    page_id = [string]$_.Name
                    page_label = [string]($_.Group | Select-Object -First 1).page_label
                    item_count = @($_.Group).Count
                }
            } |
            Sort-Object page_label, page_id
    )
    $retryPageIds = @{}
    foreach ($page in $retryPages) { $retryPageIds[[string]$page.page_id] = $true }
    $effectReady = @($effects | Where-Object {
        [bool]$_.layer_available -and -not $retryPageIds.ContainsKey([string]$_.page_id)
    })
    $effectDeferred = @($effects | Where-Object {
        -not [bool]$_.layer_available -or $retryPageIds.ContainsKey([string]$_.page_id)
    })

    return [pscustomobject]@{
        items = $items
        metadata_items = $metadata
        effect_items = $effects
        effect_ready_items = $effectReady
        effect_deferred_items = $effectDeferred
        prose_items = $prose
        prose_retry_pages = $retryPages
        unavailable_items = $unavailable
    }
}

function Get-LauncherLocalResolutionPlan {
    param([Parameter(Mandatory)][object]$Settings)

    return ConvertTo-LauncherLocalResolutionPlan -Items @(Get-LauncherReviewItems -Settings $Settings)
}

function Approve-LauncherMetadataOnlyReviews {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [scriptblock]$OnProgress
    )

    $items = @(Get-LauncherMetadataOnlyReviewItems -Settings $Settings)
    if ($items.Count -eq 0) {
        $remaining = @(Get-LauncherReviewItems -Settings $Settings -SkipLayerValidation).Count
        return [pscustomobject]@{ applied = 0; total = 0; remaining = $remaining; start_revision = $null; end_revision = $null }
    }
    $project = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'project' -TimeoutSeconds 10
    if ($null -eq $project) { throw 'No Koharu project is open.' }
    $projectName = [string]$project.name
    $currentRevision = [int64]$project.revision
    $startRevision = $currentRevision
    if (@($items | Where-Object { [int64]$_.expected_revision -ne $startRevision }).Count -gt 0) {
        throw 'The Koharu project changed before fast review began. Refresh the review list.'
    }

    $applied = 0
    foreach ($item in $items) {
        try {
            $item.expected_revision = $currentRevision
            $decision = Resolve-LauncherReviewText `
                -Source ([string]$item.source) `
                -FirstTranslation ([string]$item.first_translation) `
                -FinalTranslation ([string]$item.final_translation) `
                -Choice final `
                -Translation ([string]$item.final_translation)
            $request = New-LauncherReviewDecisionRequest -Item $item -RegionId ([string]$item.region_id) -Decision $decision
            if ([string]$request.text -cne [string]$item.current_translation) {
                throw 'The live Koharu translation no longer matches the audited translation.'
            }
            [void](Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'review/decision' -Method POST -Body $request -TimeoutSeconds 30)
            $updatedProject = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'project' -TimeoutSeconds 10
            if ($null -eq $updatedProject -or [string]$updatedProject.name -cne $projectName -or [int64]$updatedProject.revision -le $currentRevision) {
                throw 'Koharu did not report the expected project revision after applying the review decision.'
            }
            [void](Add-LauncherReviewAction -Data @{
                action = 'review_decision_applied'
                project = $projectName
                page_id = [string]$item.page_id
                region_id = [string]$item.region_id
                audit_job_id = [string]$item.audit_job_id
                choice = 'metadata_batch_final'
                expected_revision = $currentRevision
                applied_revision = [int64]$updatedProject.revision
                preserve_source_pixels = $false
                live_translation_verified = $true
            })
            $currentRevision = [int64]$updatedProject.revision
            $applied++
            if ($null -ne $OnProgress) {
                & $OnProgress ([pscustomobject]@{
                    applied = $applied
                    total = $items.Count
                    page_id = [string]$item.page_id
                    page_label = [string]$item.page_label
                    revision = $currentRevision
                })
            }
        }
        catch {
            throw "Fast review stopped after $applied/$($items.Count) item(s): $($_.Exception.Message)"
        }
    }
    $remaining = @(Get-LauncherReviewItems -Settings $Settings -SkipLayerValidation).Count
    return [pscustomobject]@{
        applied = $applied
        total = $items.Count
        remaining = $remaining
        start_revision = $startRevision
        end_revision = $currentRevision
    }
}

function Preserve-LauncherUncertainSoundEffects {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [scriptblock]$OnProgress
    )

    $plan = Get-LauncherLocalResolutionPlan -Settings $Settings
    $items = @($plan.effect_ready_items)
    if ($items.Count -eq 0) {
        return [pscustomobject]@{
            applied = 0
            total = 0
            deferred = @($plan.effect_deferred_items).Count
            remaining = @($plan.items).Count
            start_revision = $null
            end_revision = $null
        }
    }
    $project = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'project' -TimeoutSeconds 10
    if ($null -eq $project) { throw 'No Koharu project is open.' }
    $projectName = [string]$project.name
    $currentRevision = [int64]$project.revision
    $startRevision = $currentRevision
    if (@($items | Where-Object { [int64]$_.expected_revision -ne $startRevision }).Count -gt 0) {
        throw 'The Koharu project changed before source preservation began. Refresh the review list.'
    }

    $applied = 0
    foreach ($item in $items) {
        try {
            $item.expected_revision = $currentRevision
            $decision = Resolve-LauncherReviewText `
                -Source ([string]$item.source) `
                -FirstTranslation ([string]$item.first_translation) `
                -FinalTranslation ([string]$item.final_translation) `
                -Choice source `
                -Translation ([string]$item.source)
            $request = New-LauncherReviewDecisionRequest -Item $item -RegionId ([string]$item.region_id) -Decision $decision
            if ($null -ne $request.text -or $null -ne $request.typography -or -not [bool]$request.preserve_source_pixels) {
                throw 'The source-preservation request is not safe.'
            }
            [void](Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'review/decision' -Method POST -Body $request -TimeoutSeconds 30)
            $updatedProject = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'project' -TimeoutSeconds 10
            if ($null -eq $updatedProject -or [string]$updatedProject.name -cne $projectName -or [int64]$updatedProject.revision -le $currentRevision) {
                throw 'Koharu did not report the expected project revision after preserving source pixels.'
            }
            [void](Add-LauncherReviewAction -Data @{
                action = 'review_decision_applied'
                project = $projectName
                page_id = [string]$item.page_id
                region_id = [string]$item.region_id
                audit_job_id = [string]$item.audit_job_id
                choice = 'source_batch_uncertain_effect'
                expected_revision = $currentRevision
                applied_revision = [int64]$updatedProject.revision
                preserve_source_pixels = $true
                local_completion_policy = 'uncertain_sound_effect_original'
            })
            $currentRevision = [int64]$updatedProject.revision
            $applied++
            if ($null -ne $OnProgress) {
                & $OnProgress ([pscustomobject]@{
                    applied = $applied
                    total = $items.Count
                    page_id = [string]$item.page_id
                    page_label = [string]$item.page_label
                    revision = $currentRevision
                })
            }
        }
        catch {
            throw "Source preservation stopped after $applied/$($items.Count) item(s): $($_.Exception.Message)"
        }
    }
    $remainingPlan = Get-LauncherLocalResolutionPlan -Settings $Settings
    return [pscustomobject]@{
        applied = $applied
        total = $items.Count
        deferred = @($remainingPlan.effect_deferred_items).Count
        remaining = @($remainingPlan.items).Count
        start_revision = $startRevision
        end_revision = $currentRevision
    }
}

function Approve-LauncherAllExistingReviews {
    param([Parameter(Mandatory)][object]$Settings)

    $items = @(Get-LauncherReviewItems -Settings $Settings)
    if ($items.Count -eq 0) { return [pscustomobject]@{ accepted = 0; remaining = 0; revision = $null } }
    $unavailable = @($items | Where-Object { -not [bool]$_.layer_available })
    if ($unavailable.Count -gt 0) {
        throw "$($unavailable.Count) review item(s) do not have a usable live text layer and cannot be accepted as-is."
    }
    $blocking = @($items | Where-Object { @($_.blocking_defects | Where-Object { $null -ne $_ }).Count -gt 0 })
    if ($blocking.Count -gt 0) {
        throw "$($blocking.Count) review item(s) contain an unusable blocking defect and cannot be accepted as-is."
    }
    $project = Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'project' -TimeoutSeconds 10
    if ($null -eq $project) { throw 'No Koharu project is open.' }
    $revision = [int64]$project.revision
    if (@($items | Where-Object { [int64]$_.expected_revision -ne $revision }).Count -gt 0) {
        throw 'The Koharu project changed before the existing translations were accepted. Refresh and try again.'
    }
    [void](Add-LauncherReviewAction -Data @{
        action = 'review_batch_accepted_existing'
        project = [string]$project.name
        expected_revision = $revision
        applied_revision = $revision
        choice = 'all_ok_existing'
        live_layers_verified = $true
        item_count = $items.Count
        items = @($items | ForEach-Object {
            [ordered]@{
                audit_job_id = [string]$_.audit_job_id
                page_id = [string]$_.page_id
                region_id = [string]$_.region_id
            }
        })
    })
    $remaining = @(Get-LauncherReviewItems -Settings $Settings -SkipLayerValidation).Count
    if ($remaining -ne 0) { throw "The all-OK decision was recorded, but $remaining review item(s) remain." }
    return [pscustomobject]@{ accepted = $items.Count; remaining = 0; revision = $revision }
}

function New-LauncherReviewRetryRequest {
    param([Parameter(Mandatory)][string]$PageId)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($PageId, [ref]$parsed)) { throw 'Review page ID is invalid.' }
    return [ordered]@{
        scope = [ordered]@{ scope = 'pages'; value = @($PageId) }
        operation = [ordered]@{ operation = 'only'; stage = 'translation' }
    }
}
