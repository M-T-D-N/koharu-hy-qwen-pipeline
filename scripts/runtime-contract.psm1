Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-LocalHttpUrl {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'http' -or -not $uri.IsLoopback) {
        throw "$Name must be an absolute loopback HTTP URL: $Value"
    }
    return $uri
}

function Read-PinnedModelManifest {
    param(
        [Parameter(Mandatory)][string]$ModelDirectory,
        [Parameter(Mandatory)][string]$LockPath
    )

    $manifestPath = Join-Path $ModelDirectory 'download-manifest.json'
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw "Model download manifest is invalid JSON: $manifestPath" }
    try { $lock = Get-Content -LiteralPath $LockPath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw "Model lock is invalid JSON: $LockPath" }

    if ([int]$manifest.schema_version -ne 1) { throw "Unsupported model manifest schema: $($manifest.schema_version)" }
    $modelName = [string]$manifest.model
    if ([string]::IsNullOrWhiteSpace($modelName) -or $null -eq $lock.models.PSObject.Properties[$modelName]) {
        throw "The model manifest is not pinned by the model lock: $modelName"
    }
    $locked = $lock.models.$modelName
    if ([string]$manifest.repo_id -cne [string]$locked.repo_id -or [string]$manifest.revision -cne [string]$locked.revision) {
        throw 'The model manifest repository or revision does not match the model lock.'
    }
    $files = @($manifest.files)
    if ($files.Count -eq 0) { throw 'The model manifest contains no files.' }
    foreach ($file in $files) {
        $relative = [string]$file.path
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
            $relative -match '(^|[\\/])\.\.([\\/]|$)' -or [int64]$file.size_bytes -lt 0 -or
            [string]$file.sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "The model manifest contains an unsafe or incomplete file record: $relative"
        }
    }
    return [pscustomobject]@{
        path = $manifestPath
        model = $modelName
        repo_id = [string]$manifest.repo_id
        revision = [string]$manifest.revision
        files = $files
        total_bytes = [int64]$manifest.total_bytes
    }
}

function Test-PinnedModelLayout {
    param(
        [Parameter(Mandatory)][string]$ModelDirectory,
        [Parameter(Mandatory)][string]$LockPath
    )

    $root = [IO.Path]::GetFullPath($ModelDirectory).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $manifest = Read-PinnedModelManifest -ModelDirectory $root -LockPath $LockPath
    $verifiedBytes = [int64]0
    foreach ($record in @($manifest.files)) {
        $path = [IO.Path]::GetFullPath((Join-Path $root ([string]$record.path)))
        if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Model file is missing or outside the model directory: $($record.path)"
        }
        $length = (Get-Item -LiteralPath $path).Length
        if ([int64]$length -ne [int64]$record.size_bytes) {
            throw "Model file size mismatch: $($record.path)"
        }
        $verifiedBytes += [int64]$length
    }
    if ($verifiedBytes -ne [int64]$manifest.total_bytes) {
        throw 'Verified model bytes do not match the manifest total.'
    }
    return [pscustomobject]@{
        root = $root
        manifest = $manifest
        files = @($manifest.files).Count
        bytes = $verifiedBytes
    }
}

function Assert-LocalQwenStatus {
    param(
        [Parameter(Mandatory)][object]$Status,
        [Parameter(Mandatory)][string]$ExpectedModel,
        [ValidateRange(1, 1048576)][int]$MinimumContext = 131072
    )

    if ($null -eq $Status.PSObject.Properties['comfyui'] -or [string]$Status.comfyui -cne 'off') {
        throw "ComfyUI must be off before startup: $($Status.comfyui)"
    }
    if ($null -eq $Status.PSObject.Properties['qwen'] -or $null -eq $Status.qwen) {
        throw 'Qwen lifecycle status did not include qwen details.'
    }
    if ($null -eq $Status.qwen.PSObject.Properties['state']) {
        throw 'Qwen lifecycle status did not include state.'
    }
    $state = [string]$Status.qwen.state
    if ($state -in @('off', 'stale_state')) { return $Status }
    if ($state -cne 'ready_owned') {
        throw "Qwen lifecycle is not safely reusable or startable: $state"
    }
    foreach ($field in @('alias', 'context')) {
        if ($null -eq $Status.qwen.PSObject.Properties[$field]) { throw "Qwen lifecycle status did not include $field." }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Status.qwen.alias) -or [string]$Status.qwen.alias -cne $ExpectedModel) {
        throw "Qwen lifecycle model mismatch: expected $ExpectedModel, observed $($Status.qwen.alias)"
    }
    if ([int64]$Status.qwen.context -lt $MinimumContext) {
        throw "Qwen requires at least $MinimumContext context tokens, observed $($Status.qwen.context)"
    }
    return $Status
}

function Test-KoharuFontPolicy {
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][object[]]$FontCatalog
    )

    try { $policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw "Translation policy is unavailable or invalid: $PolicyPath" }
    if ([int]$policy.schema_version -ne 1) { throw 'Unsupported translation policy schema.' }
    $expectedRoles = @('dialogue', 'narration', 'emphasis', 'handwritten_effect')
    $observedRoles = @($policy.roles.PSObject.Properties.Name)
    if (@($expectedRoles | Where-Object { $_ -cnotin $observedRoles }).Count -gt 0 -or
        @($observedRoles | Where-Object { $_ -cnotin $expectedRoles }).Count -gt 0) {
        throw 'Translation policy must declare every supported role exactly once.'
    }
    $families = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($roleName in $expectedRoles) {
        $role = $policy.roles.$roleName
        $fontIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($font in @($role.fonts)) {
            $fontId = [string]$font.id
            $family = [string]$font.koharu_family
            if ([string]::IsNullOrWhiteSpace($fontId) -or [string]::IsNullOrWhiteSpace($family)) {
                throw "Translation policy contains an incomplete font for role: $roleName"
            }
            [void]$fontIds.Add($fontId)
            [void]$families.Add($family)
        }
        if ($fontIds.Count -eq 0 -or -not $fontIds.Contains([string]$role.default)) {
            throw "Translation policy default is not available for role: $roleName"
        }
    }
    $available = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $catalogItems = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $FontCatalog) {
        if ($entry -is [Array]) { foreach ($nested in $entry) { $catalogItems.Add($nested) } }
        else { $catalogItems.Add($entry) }
    }
    foreach ($font in $catalogItems) {
        if ($null -ne $font -and $null -ne $font.PSObject.Properties['name']) {
            [void]$available.Add([string]$font.name)
        }
    }
    $missing = @($families | Where-Object { -not $available.Contains($_) } | Sort-Object)
    if ($missing.Count -gt 0) { throw "Required Koharu font families are unavailable: $($missing -join ', ')" }
    return [pscustomobject]@{ required = $families.Count; available = $available.Count }
}

function Get-RecordedProcessIdentity {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)

    $Process.Refresh()
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)" -ErrorAction Stop
    if ($null -eq $cim) { throw "Process identity is unavailable for PID $($Process.Id)." }
    return [ordered]@{
        pid = $Process.Id
        path = $Process.Path
        start_time = $Process.StartTime.ToString('o')
        parent_pid = [int]$cim.ParentProcessId
        creation_date = ([datetime]$cim.CreationDate).ToUniversalTime().ToString('o')
        command_line = [string]$cim.CommandLine
    }
}

function Get-IdentityRecordValues {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object]$Record
    )

    $values = @{}
    foreach ($field in @('path', 'start_time', 'parent_pid', 'creation_date', 'command_line')) {
        $property = $Record.PSObject.Properties[$field]
        $value = if ($Record -is [System.Collections.IDictionary] -and $Record.Contains($field)) {
            $Record[$field]
        }
        elseif ($null -ne $property) {
            $property.Value
        }
        else {
            $null
        }
        if ($null -eq $value) {
            throw "$Name identity record is incomplete; refusing to stop PID $($Record.pid)."
        }
        $values[$field] = $value
    }
    return $values
}

function Test-RecordedProcessIdentity {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process
    )

    $values = Get-IdentityRecordValues -Name $Name -Record $Record
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)" -ErrorAction Stop
    if ($null -eq $cim) {
        if ($null -eq (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue)) { return $false }
        throw "$Name process identity is unavailable; refusing to stop PID $($Record.pid)."
    }
    if (
        [IO.Path]::GetFullPath($Process.Path) -cne [IO.Path]::GetFullPath([string]$values.path) -or
        $Process.StartTime.ToString('o') -cne ([datetime]$values.start_time).ToString('o') -or
        [int]$cim.ParentProcessId -ne [int]$values.parent_pid -or
        ([datetime]$cim.CreationDate).ToUniversalTime().ToString('o') -cne ([datetime]$values.creation_date).ToUniversalTime().ToString('o') -or
        [string]$cim.CommandLine -cne [string]$values.command_line
    ) {
        throw "$Name process identity changed; refusing to stop PID $($Record.pid)."
    }
    return $true
}

function Assert-OwnedProcessListener {
    param(
        [Parameter(Mandatory)][object]$LauncherIdentity,
        [Parameter(Mandatory)][object]$ListenerIdentity
    )

    if ([int]$ListenerIdentity.pid -eq [int]$LauncherIdentity.pid) { return }
    if ([int]$ListenerIdentity.parent_pid -ne [int]$LauncherIdentity.pid -or
        [string]$ListenerIdentity.command_line -cne [string]$LauncherIdentity.command_line) {
        throw "Port listener PID $($ListenerIdentity.pid) is not the process tree started for PID $($LauncherIdentity.pid)."
    }
}

Export-ModuleMember -Function @(
    'Assert-LocalHttpUrl', 'Read-PinnedModelManifest', 'Test-PinnedModelLayout',
    'Assert-LocalQwenStatus', 'Test-KoharuFontPolicy', 'Get-RecordedProcessIdentity', 'Test-RecordedProcessIdentity',
    'Assert-OwnedProcessListener'
)
