Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'runtime-contract.psm1') -Force
$translationPolicyPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\translation-policy.json'
try { $translationPolicy = Get-Content -LiteralPath $translationPolicyPath -Raw -Encoding utf8 | ConvertFrom-Json }
catch { throw "Translation policy is unavailable or invalid: $translationPolicyPath" }
if ([int]$translationPolicy.schema_version -ne 1) { throw 'Unsupported translation policy schema.' }
$script:LauncherReviewFontFamilies = [ordered]@{}
foreach ($role in $translationPolicy.roles.PSObject.Properties) {
    foreach ($font in @($role.Value.fonts)) {
        $fontId = [string]$font.id
        $family = [string]$font.koharu_family
        if ([string]::IsNullOrWhiteSpace($fontId) -or [string]::IsNullOrWhiteSpace($family)) {
            throw "Translation policy contains an incomplete font for role: $($role.Name)"
        }
        if ($script:LauncherReviewFontFamilies.Contains($fontId) -and
            [string]$script:LauncherReviewFontFamilies[$fontId] -cne $family) {
            throw "Translation policy maps one font ID to multiple Koharu families: $fontId"
        }
        $script:LauncherReviewFontFamilies[$fontId] = $family
    }
}
$script:LauncherReviewFonts = @($script:LauncherReviewFontFamilies.Keys)
if ($script:LauncherReviewFonts.Count -eq 0) { throw 'Translation policy contains no review fonts.' }
$script:LauncherHandwrittenEffectFonts = @(
    $translationPolicy.roles.handwritten_effect.fonts | ForEach-Object { [string]$_.id }
)
if ($script:LauncherHandwrittenEffectFonts.Count -eq 0) {
    throw 'Translation policy contains no handwritten-effect fonts.'
}

function Get-LauncherRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-DefaultLauncherSettings {
    $root = Get-LauncherRoot
    $qwenLeasePath = [Environment]::GetEnvironmentVariable('KOHARU_QWEN_LEASE_PATH', 'Process')
    [ordered]@{
        schema_version = 2
        project_name = ''
        input_path = ''
        output_directory = (Join-Path $root 'exports')
        data_directory = (Join-Path $root 'data')
        python_executable = (Join-Path $root '.venv\Scripts\python.exe')
        koharu_executable = (Join-Path $root 'vendor\koharu\target\debug\koharu.exe')
        hy_model_directory = (Join-Path $root 'models\hy-mt2-7b')
        qwen_lifecycle_script = ''
        qwen_api = 'http://127.0.0.1:8000/v1'
        qwen_model = 'dirk-qwen3.8-27b-q5'
        qwen_lease_path = [string]$qwenLeasePath
        koharu_port = 4010
        service_port = 4020
        export_format = 'png'
    }
}

function Test-LauncherModelLayout {
    param([Parameter(Mandatory)][string]$ModelDirectory)
    return Test-PinnedModelLayout -ModelDirectory $ModelDirectory -LockPath (Join-Path (Get-LauncherRoot) 'config\model-lock.json')
}

function Import-LauncherSettings {
    param([Parameter(Mandatory)][string]$Path)

    $defaults = Get-DefaultLauncherSettings
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$defaults
    }
    $loaded = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($name in @($defaults.Keys)) {
        if ($null -ne $loaded.PSObject.Properties[$name]) {
            $defaults[$name] = $loaded.$name
        }
    }
    $defaults.schema_version = 2
    return [pscustomobject]$defaults
}

function Save-LauncherSettings {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][string]$Path
    )

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    [void](New-Item -ItemType Directory -Force -Path $parent)
    $temporary = Join-Path $parent ('.launcher-settings.{0}.tmp' -f [guid]::NewGuid())
    try {
        $Settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Assert-LauncherSettings {
    param([Parameter(Mandatory)][object]$Settings)

    $leafFields = @{
        python_executable = 'Python executable'
        koharu_executable = 'Koharu executable'
        qwen_lifecycle_script = 'Qwen lifecycle script'
    }
    foreach ($entry in $leafFields.GetEnumerator()) {
        $value = [string]$Settings.($entry.Key)
        if ([string]::IsNullOrWhiteSpace($value) -or -not (Test-Path -LiteralPath $value -PathType Leaf)) {
            throw "$($entry.Value) was not found: $value"
        }
    }
    $modelDirectory = [string]$Settings.hy_model_directory
    if ([string]::IsNullOrWhiteSpace($modelDirectory) -or -not (Test-Path -LiteralPath $modelDirectory -PathType Container)) {
        throw "Hy-MT2 model directory was not found: $modelDirectory"
    }
    $manifestPath = Join-Path $modelDirectory 'download-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Hy-MT2 download manifest was not found: $manifestPath"
    }
    $modelLayout = Test-LauncherModelLayout -ModelDirectory $modelDirectory
    $manifest = $modelLayout.manifest
    [void](Assert-LocalHttpUrl -Value ([string]$Settings.qwen_api) -Name 'Qwen API')
    $qwenLeasePath = if ($null -ne $Settings.PSObject.Properties['qwen_lease_path']) { [string]$Settings.qwen_lease_path } else { '' }
    if ([string]::IsNullOrWhiteSpace($qwenLeasePath)) {
        throw 'Qwen lease path is required so concurrent local-AI work cannot be disturbed.'
    }
    $leaseParent = Split-Path -Parent ([IO.Path]::GetFullPath($qwenLeasePath))
    if (-not (Test-Path -LiteralPath $leaseParent -PathType Container)) {
        throw "Qwen lease directory was not found: $leaseParent"
    }
    foreach ($portName in @('koharu_port', 'service_port')) {
        $port = [int]$Settings.$portName
        if ($port -lt 1 -or $port -gt 65535) { throw "Invalid $portName value: $port" }
    }
    if ([int]$Settings.koharu_port -eq [int]$Settings.service_port) {
        throw 'Koharu and translation service ports must differ.'
    }
    if ([string]$Settings.export_format -notin @('png', 'psd')) {
        throw "Unsupported export format: $($Settings.export_format)"
    }
    [pscustomobject]@{
        valid = $true
        python = (Resolve-Path -LiteralPath $Settings.python_executable).Path
        koharu = (Resolve-Path -LiteralPath $Settings.koharu_executable).Path
        model = (Resolve-Path -LiteralPath $modelDirectory).Path
        model_revision = $manifest.revision
        model_files = @($manifest.files).Count
        qwen_lifecycle = (Resolve-Path -LiteralPath $Settings.qwen_lifecycle_script).Path
        qwen_api = ([uri][string]$Settings.qwen_api).AbsoluteUri.TrimEnd('/')
        qwen_lease = if ([string]::IsNullOrWhiteSpace($qwenLeasePath)) { $null } else { [IO.Path]::GetFullPath($qwenLeasePath) }
    }
}

function Invoke-LauncherProcessProbe {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 60
    )

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$info.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Failed to start runtime probe: $FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch {}
            try { $process.WaitForExit(5000) | Out-Null } catch {}
            throw "Runtime probe exceeded $TimeoutSeconds seconds: $FilePath"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = @($stderr.Trim(), $stdout.Trim()) | Where-Object { $_ } | Select-Object -First 1
            throw "Runtime probe failed with exit code $($process.ExitCode): $FilePath`n$detail"
        }
        return [pscustomobject]@{ stdout = $stdout; stderr = $stderr; exit_code = $process.ExitCode }
    }
    finally { $process.Dispose() }
}

function Test-LauncherModelFiles {
    param(
        [Parameter(Mandatory)][string]$ModelDirectory,
        [scriptblock]$OnProgress
    )

    $layout = Test-LauncherModelLayout -ModelDirectory $ModelDirectory
    $root = [string]$layout.root
    $manifest = $layout.manifest
    $verifiedBytes = [int64]0
    $files = @($manifest.files)
    for ($index = 0; $index -lt $files.Count; $index++) {
        $record = $files[$index]
        $path = [IO.Path]::GetFullPath((Join-Path $root ([string]$record.path)))
        if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The model manifest escapes the model directory: $($record.path)"
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Model file is missing: $($record.path)" }
        $file = Get-Item -LiteralPath $path
        if ([int64]$file.Length -ne [int64]$record.size_bytes) { throw "Model file size mismatch: $($record.path)" }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($hash -cne ([string]$record.sha256).ToUpperInvariant()) { throw "Model file SHA-256 mismatch: $($record.path)" }
        $verifiedBytes += [int64]$file.Length
        if ($OnProgress) {
            & $OnProgress ([pscustomobject]@{
                phase = 'model_hash'
                completed = $index + 1
                total = $files.Count
                completed_bytes = $verifiedBytes
                total_bytes = [int64]$manifest.total_bytes
                file = [string]$record.path
            })
        }
    }
    if ($verifiedBytes -ne [int64]$manifest.total_bytes) { throw 'Verified model bytes do not match the manifest total.' }
    return [pscustomobject]@{ model = $manifest.model; revision = $manifest.revision; files = $files.Count; bytes = $verifiedBytes }
}

function Test-LauncherRuntime {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [scriptblock]$OnProgress
    )

    $validation = Assert-LauncherSettings -Settings $Settings
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ phase = 'settings'; completed = 1; total = 5 }) }
    $model = Test-LauncherModelFiles -ModelDirectory ([string]$validation.model) -OnProgress $OnProgress
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ phase = 'python'; completed = 3; total = 5 }) }
    $pythonCode = @'
import json, sys
import torch, transformers, huggingface_hub
print(json.dumps({
    "python": sys.version.split()[0],
    "torch": torch.__version__,
    "transformers": transformers.__version__,
    "huggingface_hub": huggingface_hub.__version__,
    "cuda_available": bool(torch.cuda.is_available()),
    "cuda_device": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
}, ensure_ascii=False))
'@
    $pythonResult = Invoke-LauncherProcessProbe -FilePath ([string]$validation.python) -Arguments @('-c', $pythonCode) -TimeoutSeconds 60
    try { $python = ($pythonResult.stdout.Trim() | ConvertFrom-Json) }
    catch { throw "Python runtime probe returned invalid JSON: $($pythonResult.stdout.Trim())" }
    if (-not [bool]$python.cuda_available) { throw 'The configured Hy-MT2 runtime has no CUDA device; CPU fallback is not allowed.' }
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ phase = 'koharu'; completed = 4; total = 5 }) }
    $koharuResult = Invoke-LauncherProcessProbe -FilePath ([string]$validation.koharu) -Arguments @('--version') -TimeoutSeconds 30
    $koharuVersion = $koharuResult.stdout.Trim()
    if ([string]::IsNullOrWhiteSpace($koharuVersion)) { $koharuVersion = $koharuResult.stderr.Trim() }
    if ($koharuVersion -notmatch '0\.78\.1') { throw "Koharu 0.78.1 is required, but the probe reported: $koharuVersion" }
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ phase = 'lifecycle'; completed = 5; total = 5 }) }
    $lifecycleResult = Invoke-LauncherProcessProbe `
        -FilePath ([string](Get-Process -Id $PID).Path) `
        -Arguments @('-NoProfile', '-File', [string]$validation.qwen_lifecycle, '-Operation', 'status', '-Summary') `
        -TimeoutSeconds 30
    try { $lifecycle = ($lifecycleResult.stdout.Trim().Split([Environment]::NewLine)[-1] | ConvertFrom-Json) }
    catch { throw "Qwen lifecycle status returned invalid JSON: $($lifecycleResult.stdout.Trim())" }
    [void](Assert-LocalQwenStatus -Status $lifecycle -ExpectedModel ([string]$Settings.qwen_model))
    return [pscustomobject]@{
        valid = $true
        python = $python
        koharu_version = $koharuVersion
        model = $model
        qwen = $lifecycle.qwen
        qwen_lease = $validation.qwen_lease
    }
}

function Get-SupportedInputFiles {
    param([Parameter(Mandatory)][string]$InputPath)

    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Choose an input file or folder.' }
    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
    $supported = @('.png', '.jpg', '.jpeg', '.webp', '.cbz', '.zip', '.rar', '.pdf')
    if (Test-Path -LiteralPath $resolved.Path -PathType Leaf) {
        if ([IO.Path]::GetExtension($resolved.Path).ToLowerInvariant() -notin $supported) {
            throw "Unsupported input file: $($resolved.Path)"
        }
        return @($resolved.Path)
    }
    $files = @(Get-ChildItem -LiteralPath $resolved.Path -File | Where-Object {
        $_.Extension.ToLowerInvariant() -in $supported
    } | Sort-Object @{ Expression = {
        [regex]::Replace($_.Name.ToLowerInvariant(), '\d+', { param($match) $match.Value.PadLeft(20, '0') })
    } } | ForEach-Object FullName)
    if ($files.Count -eq 0) { throw "No supported images or archives were found directly in: $($resolved.Path)" }
    return $files
}

function Set-TomlSectionValue {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$TomlValue
    )

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $sectionPattern = '(?ms)(^\[' + [regex]::Escape($Section) + '\][^\r\n]*\r?\n)(.*?)(?=^\[|\z)'
    $sectionMatch = [regex]::Match($Text, $sectionPattern)
    if (-not $sectionMatch.Success) {
        $separator = if ($Text.Length -eq 0 -or $Text.EndsWith($newline)) { '' } else { $newline }
        return $Text + $separator + $newline + "[$Section]" + $newline + "$Key = $TomlValue" + $newline
    }
    $body = $sectionMatch.Groups[2].Value
    $keyPattern = '(?m)^([ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*).*$'
    if ([regex]::IsMatch($body, $keyPattern)) {
        $body = [regex]::Replace($body, $keyPattern, { param($match) $match.Groups[1].Value + $TomlValue }, 1)
    }
    else {
        if ($body.Length -gt 0 -and -not $body.EndsWith($newline)) { $body += $newline }
        $body += "$Key = $TomlValue" + $newline
    }
    return $Text.Substring(0, $sectionMatch.Groups[2].Index) + $body + $Text.Substring($sectionMatch.Groups[2].Index + $sectionMatch.Groups[2].Length)
}

function New-KoharuSessionConfig {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$OriginalText,
        [Parameter(Mandatory)][int]$ServicePort
    )

    $result = $OriginalText
    $values = @(
        @('pipeline.translation', 'target_language', '"ko-KR"'),
        @('pipeline.translation.generation', 'reasoning', 'false'),
        @('pipeline.translation.generation', 'vision', 'false'),
        @('pipeline.translation.model', 'model', '"koharu-hy-qwen-v1"'),
        @('pipeline.translation.model', 'provider', '"openai-compatible"'),
        @('pipeline.translation.model', 'reasoning', 'false'),
        @('pipeline.translation.model', 'vision', 'false'),
        @('providers.openai-compatible', 'base_url', ('"http://127.0.0.1:{0}/v1"' -f $ServicePort))
    )
    foreach ($value in $values) {
        $result = Set-TomlSectionValue -Text $result -Section $value[0] -Key $value[1] -TomlValue $value[2]
    }
    return $result
}

function Get-LauncherBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}

function Restore-InterruptedKoharuSessionConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot
    )

    $expectedConfig = [IO.Path]::GetFullPath($ConfigPath)
    $expectedRunRoot = [IO.Path]::GetFullPath($RunRoot)
    $records = @(Get-ChildItem -LiteralPath $expectedRunRoot -Filter 'koharu-config.*.json' -File -ErrorAction SilentlyContinue)
    foreach ($recordFile in $records) {
        try { $record = Get-Content -LiteralPath $recordFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json }
        catch { throw "Interrupted Koharu config record is invalid: $($recordFile.FullName)" }
        if ([int]$record.schema_version -ne 2) {
            throw "Interrupted Koharu config record requires manual recovery: $($recordFile.FullName)"
        }
        if ([IO.Path]::GetFullPath([string]$record.config_path) -cne $expectedConfig) {
            throw "Interrupted Koharu config record targets a different config path: $($recordFile.FullName)"
        }
        $match = [regex]::Match($recordFile.Name, '^koharu-config\.([0-9a-f]{32})\.json$')
        if (-not $match.Success) { throw "Interrupted Koharu config record name is invalid: $($recordFile.Name)" }
        $transactionId = $match.Groups[1].Value
        $expectedBackup = Join-Path $expectedRunRoot "koharu-config.$transactionId.backup"
        $sessionHash = [string]$record.session_sha256
        if ($sessionHash -notmatch '^[0-9A-F]{64}$') {
            throw "Interrupted Koharu config record lacks a valid session hash: $($recordFile.FullName)"
        }

        $configExists = Test-Path -LiteralPath $expectedConfig -PathType Leaf
        if ((Test-Path -LiteralPath $expectedConfig) -and -not $configExists) {
            throw "Koharu config path is no longer a file: $expectedConfig"
        }
        $currentHash = if ($configExists) { (Get-FileHash -LiteralPath $expectedConfig -Algorithm SHA256).Hash } else { $null }

        if ([bool]$record.original_existed) {
            if ([IO.Path]::GetFullPath([string]$record.backup_path) -cne [IO.Path]::GetFullPath($expectedBackup) -or
                -not (Test-Path -LiteralPath $expectedBackup -PathType Leaf)) {
                throw "Interrupted Koharu config backup is missing or outside the transaction: $expectedBackup"
            }
            $originalHash = [string]$record.original_sha256
            if ($originalHash -notmatch '^[0-9A-F]{64}$' -or
                (Get-FileHash -LiteralPath $expectedBackup -Algorithm SHA256).Hash -cne $originalHash) {
                throw "Interrupted Koharu config backup hash is invalid: $expectedBackup"
            }
            if ($currentHash -cne $originalHash) {
                if ($currentHash -cne $sessionHash) {
                    throw "Koharu config changed after an interrupted session; refusing automatic recovery: $expectedConfig"
                }
                $restoreTemporary = Join-Path (Split-Path -Parent $expectedConfig) ".config.$transactionId.recovery.tmp"
                [IO.File]::WriteAllBytes($restoreTemporary, [IO.File]::ReadAllBytes($expectedBackup))
                Move-Item -LiteralPath $restoreTemporary -Destination $expectedConfig -Force
                if ((Get-FileHash -LiteralPath $expectedConfig -Algorithm SHA256).Hash -cne $originalHash) {
                    throw "Recovered Koharu config hash does not match the backup: $expectedConfig"
                }
            }
            Remove-Item -LiteralPath $expectedBackup -Force
        }
        elseif ($configExists) {
            if ($currentHash -cne $sessionHash) {
                throw "Koharu config appeared after an interrupted session; refusing automatic removal: $expectedConfig"
            }
            Remove-Item -LiteralPath $expectedConfig -Force
        }
        Remove-Item -LiteralPath $recordFile.FullName -Force
    }
}

function Invoke-WithKoharuSessionConfig {
    param(
        [Parameter(Mandatory)][int]$ServicePort,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$ConfigPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.koharu\config.toml'),
        [scriptblock]$ProcessLookup
    )

    $existing = @(if ($ProcessLookup) { & $ProcessLookup } else { Get-Process -Name 'koharu' -ErrorAction SilentlyContinue })
    if ($existing.Count -gt 0) {
        throw "Koharu is already running (PID: $($existing.Id -join ', ')). Close it before starting this isolated session."
    }
    $root = Get-LauncherRoot
    $runRoot = Join-Path $root 'run'
    [void](New-Item -ItemType Directory -Force -Path $runRoot)
    $configDirectory = Split-Path -Parent $ConfigPath
    [void](New-Item -ItemType Directory -Force -Path $configDirectory)
    Restore-InterruptedKoharuSessionConfig -ConfigPath $ConfigPath -RunRoot $runRoot
    $transactionId = [guid]::NewGuid().ToString('N')
    $backupPath = Join-Path $runRoot "koharu-config.$transactionId.backup"
    $recordPath = Join-Path $runRoot "koharu-config.$transactionId.json"
    $hadOriginal = Test-Path -LiteralPath $ConfigPath -PathType Leaf
    $originalBytes = if ($hadOriginal) { [IO.File]::ReadAllBytes($ConfigPath) } else { [byte[]]@() }
    $originalText = if ($hadOriginal) { [Text.UTF8Encoding]::new($false, $true).GetString($originalBytes) } else { '' }
    $sessionText = New-KoharuSessionConfig -OriginalText $originalText -ServicePort $ServicePort
    $sessionBytes = [Text.UTF8Encoding]::new($false).GetBytes($sessionText)
    if ($hadOriginal) { [IO.File]::WriteAllBytes($backupPath, $originalBytes) }
    $record = [ordered]@{
        schema_version = 2
        config_path = [IO.Path]::GetFullPath($ConfigPath)
        backup_path = if ($hadOriginal) { $backupPath } else { $null }
        original_existed = $hadOriginal
        original_sha256 = if ($hadOriginal) { (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash } else { $null }
        session_sha256 = Get-LauncherBytesSha256 -Bytes $sessionBytes
        created_at = (Get-Date).ToString('o')
    }
    $recordTemporary = "$recordPath.tmp"
    $record | ConvertTo-Json | Set-Content -LiteralPath $recordTemporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $recordTemporary -Destination $recordPath

    $profileWritten = $false
    $actionError = $null
    $result = $null
    try {
        $temporary = Join-Path $configDirectory ('.config.{0}.tmp' -f $transactionId)
        [IO.File]::WriteAllBytes($temporary, $sessionBytes)
        Move-Item -LiteralPath $temporary -Destination $ConfigPath -Force
        $profileWritten = $true
        $result = & $Action
    }
    catch {
        $actionError = $_
    }
    finally {
        $restoreError = $null
        if ($profileWritten) {
            try {
                if ($hadOriginal) {
                    $restoreTemporary = Join-Path $configDirectory ('.config.{0}.restore.tmp' -f $transactionId)
                    [IO.File]::WriteAllBytes($restoreTemporary, $originalBytes)
                    Move-Item -LiteralPath $restoreTemporary -Destination $ConfigPath -Force
                    $restoredHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
                    if ($restoredHash -cne $record.original_sha256) { throw 'Restored Koharu config hash does not match the original.' }
                }
                elseif (Test-Path -LiteralPath $ConfigPath) {
                    Remove-Item -LiteralPath $ConfigPath -Force
                }
            }
            catch { $restoreError = $_ }
        }
        if ($null -eq $restoreError) {
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
            if (Test-Path -LiteralPath $recordPath) { Remove-Item -LiteralPath $recordPath -Force }
        }
        else {
            $statePath = Join-Path $runRoot 'pipeline-state.json'
            $stopError = $null
            if (Test-Path -LiteralPath $statePath) {
                try { & (Join-Path $PSScriptRoot 'stop.ps1') | Out-Null }
                catch { $stopError = $_.Exception.Message }
            }
            $message = "Koharu started, but its original config could not be restored: $($restoreError.Exception.Message). Backup retained at $backupPath."
            if ($stopError) { $message += " Exact process shutdown also failed: $stopError" }
            throw $message
        }
    }
    if ($null -ne $actionError) { throw $actionError }
    return $result
}

function Start-LauncherPipeline {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [scriptblock]$OnProgress
    )

    [void](Assert-LauncherSettings -Settings $Settings)
    $root = Get-LauncherRoot
    $statePath = Join-Path $root 'run\pipeline-state.json'
    if (Test-Path -LiteralPath $statePath) { throw 'This launcher already has a recorded pipeline session. Stop it or refresh status.' }
    $dataDirectory = [IO.Path]::GetFullPath([string]$Settings.data_directory)
    $previousModelPath = [Environment]::GetEnvironmentVariable('KOHARU_HY_MODEL_PATH', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('KOHARU_HY_MODEL_PATH', [IO.Path]::GetFullPath([string]$Settings.hy_model_directory), 'Process')
        $startAction = {
            & (Join-Path $PSScriptRoot 'start.ps1') `
                -KoharuPort ([int]$Settings.koharu_port) `
                -ServicePort ([int]$Settings.service_port) `
                -QwenLifecycleScript ([string]$Settings.qwen_lifecycle_script) `
                -KoharuExecutable ([string]$Settings.koharu_executable) `
                -PythonExecutable ([string]$Settings.python_executable) `
                -HyModelDirectory ([string]$Settings.hy_model_directory) `
                -DataDirectory $dataDirectory `
                -QwenApi ([string]$Settings.qwen_api) `
                -QwenModel ([string]$Settings.qwen_model) `
                -QwenLeasePath ([string]$Settings.qwen_lease_path) `
                -OnProgress $OnProgress | ConvertFrom-Json
        }
        return Invoke-WithKoharuSessionConfig -ServicePort ([int]$Settings.service_port) -Action $startAction
    }
    finally {
        [Environment]::SetEnvironmentVariable('KOHARU_HY_MODEL_PATH', $previousModelPath, 'Process')
    }
}

function Invoke-KoharuApi {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [object]$Body,
        [int]$TimeoutSeconds = 60
    )
    $parameters = @{
        Uri = "http://127.0.0.1:$Port/api/v1/$($Path.TrimStart('/'))"
        Method = $Method
        TimeoutSec = $TimeoutSeconds
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }
    return Invoke-RestMethod @parameters
}

function Invoke-LauncherServiceApi {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [object]$Body,
        [int]$TimeoutSeconds = 10
    )
    $parameters = @{
        Uri = "http://127.0.0.1:$Port/$($Path.TrimStart('/'))"
        Method = $Method
        TimeoutSec = $TimeoutSeconds
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = $Body | ConvertTo-Json -Depth 5 -Compress
    }
    return Invoke-RestMethod @parameters
}

. (Join-Path $PSScriptRoot 'launcher-review.ps1')
. (Join-Path $PSScriptRoot 'launcher-operations.ps1')

function Export-LauncherProject {
    param([Parameter(Mandatory)][object]$Settings)

    $status = Get-LauncherStatus -Settings $Settings
    if (-not $status.healthy -or $null -eq $status.project) { throw 'Koharu is not ready to export an open project.' }
    if (@($status.jobs | Where-Object { [string]$_.state -in @('queued', 'running') }).Count -gt 0) {
        throw 'A Koharu pipeline job is still active. Wait for it to finish before exporting.'
    }
    if ([string]$status.project_job_state -cne 'finished') {
        throw "The full-project translation job is not finished (state: $($status.project_job_state))."
    }
    $reviews = @(Get-LauncherReviewItems -Settings $Settings -SkipLayerValidation)
    if ($reviews.Count -gt 0) {
        throw "$($reviews.Count) review decision(s) remain. Resolve them before exporting."
    }
    $pageCount = @($status.pages).Count
    if ($pageCount -eq 0) { throw 'The open project has no pages to export.' }

    $directory = [IO.Path]::GetFullPath([string]$Settings.output_directory)
    $format = [string]$Settings.export_format
    return Invoke-LauncherExportTransaction -Directory $directory -Format $format -ExpectedPageCount $pageCount -RenderAction {
        param($staging)
        [void](Invoke-KoharuApi -Port ([int]$Settings.koharu_port) -Path 'export' -Method POST -Body @{
            directory = $staging
            pages = @()
            format = $format
        } -TimeoutSeconds 1800)
    }
}

function Stop-LauncherPipeline {
    $statePath = Join-Path (Get-LauncherRoot) 'run\pipeline-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [pscustomobject]@{ status = 'not_running'; state_removed = $false }
    }
    return (& (Join-Path $PSScriptRoot 'stop.ps1') | ConvertFrom-Json)
}

Export-ModuleMember -Function @(
    'Get-DefaultLauncherSettings', 'Import-LauncherSettings', 'Save-LauncherSettings',
    'Assert-LauncherSettings', 'Test-LauncherModelFiles', 'Test-LauncherRuntime', 'Get-SupportedInputFiles', 'New-KoharuSessionConfig',
    'Invoke-WithKoharuSessionConfig', 'Start-LauncherPipeline', 'Get-LauncherStatus',
    'Initialize-LauncherProject', 'Start-LauncherJob', 'Wait-LauncherJob', 'New-LauncherFullPageRequest',
    'ConvertTo-LauncherSerialProgress', 'Get-LauncherResumePageIds', 'Invoke-LauncherSerialProjectJob', 'Get-LauncherSerialRunState',
    'Get-LauncherReviewItems', 'New-LauncherReviewTypographyRequest', 'Resolve-LauncherReviewText', 'New-LauncherReviewDecisionRequest', 'Set-LauncherReviewTranslation',
    'Test-LauncherMetadataOnlyReviewItem', 'Get-LauncherMetadataOnlyReviewItems', 'Approve-LauncherMetadataOnlyReviews',
    'Test-LauncherUncertainSoundEffectReviewItem', 'Get-LauncherLocalResolutionPlan', 'Preserve-LauncherUncertainSoundEffects', 'Approve-LauncherAllExistingReviews',
    'New-LauncherReviewRetryRequest', 'Get-LauncherProjectJobState', 'Get-LauncherRecommendedAction', 'Invoke-LauncherReviewRetry', 'Invoke-LauncherProseReviewRetryBatch',
    'Invoke-LauncherExportTransaction', 'Export-LauncherProject', 'Stop-LauncherCurrentJob', 'Stop-LauncherPipeline'
)
