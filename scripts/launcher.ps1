#requires -Version 7.0
[CmdletBinding()]
param([string]$SnapshotPath, [switch]$SnapshotAdvanced)

$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
        '-NoProfile', '-STA', '-File', $PSCommandPath,
        $(if ($SnapshotPath) { '-SnapshotPath' } else { $null }),
        $(if ($SnapshotPath) { $SnapshotPath } else { $null })
    ).Where({ $null -ne $_ }) -WindowStyle Hidden -PassThru
    if ($null -eq $process) { throw 'Failed to relaunch the GUI in STA mode.' }
    return
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root = Split-Path -Parent $PSScriptRoot
$cliPath = Join-Path $PSScriptRoot 'launcher-cli.ps1'
$modulePath = Join-Path $PSScriptRoot 'launcher-core.psm1'
$settingsPath = Join-Path $root 'config\local.launcher.json'
Import-Module $modulePath -Force
$settings = Import-LauncherSettings -Path $settingsPath

function New-Label([string]$Text) {
    $control = [System.Windows.Forms.Label]::new()
    $control.Text = $Text
    $control.AutoSize = $true
    $control.Anchor = 'Left'
    return $control
}

function New-TextBox([string]$Text = '') {
    $control = [System.Windows.Forms.TextBox]::new()
    $control.Text = $Text
    $control.Dock = 'Fill'
    return $control
}

function New-Button([string]$Text, [int]$Width = 110) {
    $control = [System.Windows.Forms.Button]::new()
    $control.Text = $Text
    $control.Width = $Width
    $control.Height = 32
    $control.Margin = [System.Windows.Forms.Padding]::new(4)
    return $control
}

function Add-PathRow {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TableLayoutPanel]$Table,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][System.Windows.Forms.TextBox]$TextBox,
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Buttons
    )
    [void]$Table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$Table.Controls.Add((New-Label $Label), 0, $Row)
    [void]$Table.Controls.Add($TextBox, 1, $Row)
    [void]$Table.Controls.Add($Buttons, 2, $Row)
}

function Choose-Folder([System.Windows.Forms.TextBox]$Target, [string]$Description) {
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.UseDescriptionForTitle = $true
    if (Test-Path -LiteralPath $Target.Text -PathType Container) { $dialog.SelectedPath = $Target.Text }
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $Target.Text = $dialog.SelectedPath }
    $dialog.Dispose()
}

function Choose-File {
    param(
        [System.Windows.Forms.TextBox]$Target,
        [string]$Title,
        [string]$Filter
    )
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.CheckFileExists = $true
    if (Test-Path -LiteralPath $Target.Text -PathType Leaf) { $dialog.InitialDirectory = Split-Path -Parent $Target.Text }
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $Target.Text = $dialog.FileName }
    $dialog.Dispose()
}

function Add-Log([string]$Message) {
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $logBox.AppendText("[$timestamp] $Message`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Get-FriendlyEvent([object]$EventObject) {
    $data = $EventObject.data
    switch ([string]$EventObject.event) {
        'saved' { return '설정을 로컬 파일에 저장했습니다.' }
        'validation_progress' { return "설정 검사 진행: $($data.phase)" }
        'startup_progress' { return "서비스 시작 진행: $($data.detail)" }
        'prepare_progress' { return "프로젝트 가져오기 진행: $($data.detail)" }
        'validated' { return '실행 파일과 모델 경로 검사를 통과했습니다.' }
        'starting' { return '번역 서비스와 Koharu를 시작하는 중입니다…' }
        'started' { return '서비스가 준비되었습니다. 이제 프로젝트를 가져올 수 있습니다.' }
        'importing' { return "'$($data.project)' 프로젝트에 입력을 가져오는 중입니다…" }
        'prepared' {
            if ($data.resumed) { return "기존 프로젝트 다시 열기 완료: 페이지 $($data.pages)개. 중복 가져오기는 하지 않았습니다." }
            return "가져오기 완료: 입력 $($data.imported)개, 페이지 $($data.pages)개. 번역은 아직 시작하지 않았습니다."
        }
        'job_started' {
            $resume = if ([int]$data.resumed_pages -gt 0) { " · 완료된 $($data.resumed_pages)페이지부터 이어서" } else { '' }
            return "전체 번역 작업을 페이지별 순차 실행으로 시작했습니다$resume. 페이지: $($data.pages)개 / 실행 ID: $($data.id)"
        }
        'progress' {
            $stage = if ($data.stage) { [string]$data.stage } else { '준비' }
            $page = if ($data.serial_page_index) { "페이지 $($data.serial_page_index)/$($data.serial_page_total) · " } else { '' }
            return "진행: $page$stage / $($data.completed) / $($data.total)"
        }
        'finished' { return '전체 번역 작업이 완료되었습니다.' }
        'review_retry_started' { return '선택한 페이지의 번역만 한 번 다시 시작했습니다.' }
        'review_retry_finished' { return "페이지 재시도가 완료되었습니다. 남은 검토 항목: $([int]$data.review_count)개" }
        'prose_retry_batch_started' { return "대사·설명문 재시도: $([int]$data.page_index)/$([int]$data.page_total)페이지 · $([string]$data.page_label)" }
        'prose_retry_batch_finished' { return "대사·설명문 페이지 재시도 완료: 성공 $([int]$data.succeeded)/$([int]$data.attempted), 남은 검토 $([int]$data.review_count)개" }
        'exporting' { return "결과를 $($data.directory)에 내보내는 중입니다…" }
        'exported' { return "내보내기 완료: $($data.directory)" }
        'cancelled' { return "현재 작업에 취소 요청을 전달했습니다. Koharu 작업: $($data.koharu_job_id)" }
        'stopped' { return "안전 종료 결과: $($data.status)" }
        'status' {
            if ($data.healthy) {
                $project = if ($data.project) { [string]$data.project.name } else { '열린 프로젝트 없음' }
                $reviews = if ([int]$data.review_count -gt 0) { " / 검토 필요: $([int]$data.review_count)개" } else { '' }
                return "서비스 정상 / 프로젝트: $project / 페이지: $(@($data.pages).Count)$reviews"
            }
            if ($data.recorded) { return "시작 기록은 있으나 서비스 응답이 없습니다: $($data.error)" }
            return '서비스가 실행 중이 아닙니다.'
        }
        'error' {
            $errorMessage = [string]$data.message
            if ($errorMessage -match 'UNRESOLVED_TRANSLATION|remain unresolved') {
                return '적용할 수 없는 번역 영역이 남아 안전하게 중단했습니다. 문제 번역 검토에서 후보를 확인하거나 해당 페이지를 한 번 재시도하세요.'
            }
            return "오류: $errorMessage"
        }
        default { return ([string]$EventObject.event) }
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Koharu Hy-MT2 + Qwen 번역 도우미'
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = [System.Drawing.Size]::new(900, 700)
$form.Size = [System.Drawing.Size]::new(1040, 850)
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9)

$outer = [System.Windows.Forms.TableLayoutPanel]::new()
$outer.Dock = 'Fill'
$outer.Padding = [System.Windows.Forms.Padding]::new(16)
$outer.ColumnCount = 1
$outer.RowCount = 6
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void]$form.Controls.Add($outer)

$title = [System.Windows.Forms.Label]::new()
$title.Text = '만화 번역 작업실'
$title.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 18)
$title.AutoSize = $true
[void]$outer.Controls.Add($title, 0, 0)

$description = [System.Windows.Forms.Label]::new()
$description.Text = '폴더와 프로젝트를 고른 뒤 시작 → 가져오기 → 전체 번역 → 문제 번역 검토 → 내보내기 순서로 진행하세요. 낮은 확신의 번역은 중단하지 않고 검토 목록에 남습니다.'
$description.AutoSize = $true
$description.MaximumSize = [System.Drawing.Size]::new(960, 0)
$description.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 12)
[void]$outer.Controls.Add($description, 0, 1)

$basic = [System.Windows.Forms.TableLayoutPanel]::new()
$basic.Dock = 'Top'
$basic.AutoSize = $true
$basic.ColumnCount = 3
[void]$basic.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 110))
[void]$basic.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void]$basic.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$outer.Controls.Add($basic, 0, 2)

$defaultProject = if ([string]::IsNullOrWhiteSpace([string]$settings.project_name)) { 'manga-' + (Get-Date -Format 'yyyyMMdd-HHmm') } else { [string]$settings.project_name }
$projectBox = New-TextBox $defaultProject
[void]$basic.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$basic.Controls.Add((New-Label '프로젝트 이름'), 0, 0)
[void]$basic.Controls.Add($projectBox, 1, 0)
$basic.SetColumnSpan($projectBox, 2)

$inputBox = New-TextBox ([string]$settings.input_path)
$inputButtons = [System.Windows.Forms.FlowLayoutPanel]::new()
$inputButtons.AutoSize = $true
$inputButtons.WrapContents = $false
$inputFileButton = New-Button '파일 선택' 82
$inputFolderButton = New-Button '폴더 선택' 82
$inputButtons.Controls.AddRange(@($inputFileButton, $inputFolderButton))
Add-PathRow -Table $basic -Row 1 -Label '입력' -TextBox $inputBox -Buttons $inputButtons

$dataBox = New-TextBox ([string]$settings.data_directory)
$dataButton = New-Button '폴더 선택' 90
Add-PathRow -Table $basic -Row 2 -Label '작업 폴더' -TextBox $dataBox -Buttons $dataButton

$outputBox = New-TextBox ([string]$settings.output_directory)
$outputPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$outputPanel.AutoSize = $true
$outputPanel.WrapContents = $false
$formatBox = [System.Windows.Forms.ComboBox]::new()
$formatBox.DropDownStyle = 'DropDownList'
$formatBox.Items.AddRange(@('png', 'psd'))
$formatBox.SelectedItem = if ([string]$settings.export_format -eq 'psd') { 'psd' } else { 'png' }
$formatBox.Width = 65
$outputButton = New-Button '폴더 선택' 90
$outputPanel.Controls.AddRange(@($formatBox, $outputButton))
Add-PathRow -Table $basic -Row 3 -Label '결과 폴더' -TextBox $outputBox -Buttons $outputPanel

$advancedToggle = New-Button '▶ 고급 실행 설정' 150
$advancedToggle.Margin = [System.Windows.Forms.Padding]::new(0, 10, 0, 4)
[void]$outer.Controls.Add($advancedToggle, 0, 3)

$advanced = [System.Windows.Forms.TableLayoutPanel]::new()
$advanced.Dock = 'Top'
$advanced.AutoSize = $true
$advanced.Visible = $false
$advanced.Padding = [System.Windows.Forms.Padding]::new(16, 0, 0, 0)
$advanced.ColumnCount = 3
[void]$advanced.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 130))
[void]$advanced.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void]$advanced.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$outer.Controls.Add($advanced, 0, 4)

$pythonBox = New-TextBox ([string]$settings.python_executable)
$pythonButton = New-Button '파일 선택' 90
Add-PathRow -Table $advanced -Row 0 -Label 'Python 실행 파일' -TextBox $pythonBox -Buttons $pythonButton
$koharuBox = New-TextBox ([string]$settings.koharu_executable)
$koharuButton = New-Button '파일 선택' 90
Add-PathRow -Table $advanced -Row 1 -Label 'Koharu 실행 파일' -TextBox $koharuBox -Buttons $koharuButton
$modelDirBox = New-TextBox ([string]$settings.hy_model_directory)
$modelDirButton = New-Button '폴더 선택' 90
Add-PathRow -Table $advanced -Row 2 -Label 'Hy-MT2 모델 폴더' -TextBox $modelDirBox -Buttons $modelDirButton
$lifecycleBox = New-TextBox ([string]$settings.qwen_lifecycle_script)
$lifecycleButton = New-Button '파일 선택' 90
Add-PathRow -Table $advanced -Row 3 -Label 'Qwen 수명주기' -TextBox $lifecycleBox -Buttons $lifecycleButton
$qwenApiBox = New-TextBox ([string]$settings.qwen_api)
[void]$advanced.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$advanced.Controls.Add((New-Label 'Qwen API'), 0, 4)
[void]$advanced.Controls.Add($qwenApiBox, 1, 4)
$advanced.SetColumnSpan($qwenApiBox, 2)
$qwenModelBox = New-TextBox ([string]$settings.qwen_model)
[void]$advanced.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$advanced.Controls.Add((New-Label 'Qwen 모델 ID'), 0, 5)
[void]$advanced.Controls.Add($qwenModelBox, 1, 5)
$advanced.SetColumnSpan($qwenModelBox, 2)
$qwenLeaseBox = New-TextBox ([string]$settings.qwen_lease_path)
[void]$advanced.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$advanced.Controls.Add((New-Label 'Qwen 사용 잠금'), 0, 6)
[void]$advanced.Controls.Add($qwenLeaseBox, 1, 6)
$advanced.SetColumnSpan($qwenLeaseBox, 2)

$portsPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$portsPanel.AutoSize = $true
$portsPanel.WrapContents = $false
$koharuPortBox = [System.Windows.Forms.NumericUpDown]::new()
$koharuPortBox.Minimum = 1; $koharuPortBox.Maximum = 65535; $koharuPortBox.Value = [decimal][int]$settings.koharu_port; $koharuPortBox.Width = 90
$servicePortBox = [System.Windows.Forms.NumericUpDown]::new()
$servicePortBox.Minimum = 1; $servicePortBox.Maximum = 65535; $servicePortBox.Value = [decimal][int]$settings.service_port; $servicePortBox.Width = 90
$portsPanel.Controls.AddRange(@((New-Label 'Koharu'), $koharuPortBox, (New-Label '번역 서비스'), $servicePortBox))
[void]$advanced.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$advanced.Controls.Add((New-Label '포트'), 0, 7)
[void]$advanced.Controls.Add($portsPanel, 1, 7)
$advanced.SetColumnSpan($portsPanel, 2)

$workArea = [System.Windows.Forms.TableLayoutPanel]::new()
$workArea.Dock = 'Fill'
$workArea.ColumnCount = 1
$workArea.RowCount = 4
[void]$workArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$workArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$workArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$workArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void]$outer.Controls.Add($workArea, 0, 5)

$actions = [System.Windows.Forms.FlowLayoutPanel]::new()
$actions.Dock = 'Top'
$actions.AutoSize = $true
$actions.WrapContents = $true
$actions.Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 6)
$validateButton = New-Button '1. 설정 검사'
$startButton = New-Button '2. 서비스 시작' 125
$prepareButton = New-Button '3. 프로젝트 가져오기' 145
$runButton = New-Button '4. 전체 번역 실행' 135
$reviewButton = New-Button '5. 문제 번역 검토' 140
$webButton = New-Button 'Web UI 열기'
$exportButton = New-Button '6. 내보내기'
$statusButton = New-Button '상태 새로고침' 125
$cancelButton = New-Button '현재 작업 취소' 125
$cancelButton.Enabled = $false
$stopButton = New-Button '안전 종료'
$actionButtons = @($validateButton, $startButton, $prepareButton, $runButton, $reviewButton, $webButton, $exportButton, $statusButton, $cancelButton, $stopButton)
$settingsControls = @(
    $projectBox, $inputBox, $inputFileButton, $inputFolderButton, $dataBox, $dataButton,
    $outputBox, $formatBox, $outputButton, $pythonBox, $pythonButton, $koharuBox,
    $koharuButton, $modelDirBox, $modelDirButton, $lifecycleBox, $lifecycleButton,
    $qwenApiBox, $qwenModelBox, $qwenLeaseBox, $koharuPortBox, $servicePortBox
)
$actions.Controls.AddRange($actionButtons)
[void]$workArea.Controls.Add($actions, 0, 0)

$progressArea = [System.Windows.Forms.TableLayoutPanel]::new()
$progressArea.Dock = 'Top'
$progressArea.AutoSize = $true
$progressArea.ColumnCount = 3
$progressArea.RowCount = 2
$progressArea.Margin = [System.Windows.Forms.Padding]::new(4, 0, 4, 6)
[void]$progressArea.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 90))
[void]$progressArea.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void]$progressArea.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 260))
[void]$progressArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$progressArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))

$progressTitle = New-Label '현재 진행률'
$progressBar = [System.Windows.Forms.ProgressBar]::new()
$progressBar.Minimum = 0
$progressBar.Maximum = 1000
$progressBar.Value = 0
$progressBar.Dock = 'Fill'
$progressBar.Height = 22
$progressText = New-Label '0% · 대기 중'
$progressText.Margin = [System.Windows.Forms.Padding]::new(10, 3, 0, 0)
[void]$progressArea.Controls.Add($progressTitle, 0, 0)
[void]$progressArea.Controls.Add($progressBar, 1, 0)
[void]$progressArea.Controls.Add($progressText, 2, 0)

$highlightLegend = New-Label '파란색: 방금 실행한 작업   |   초록색: 다음 권장 작업   |   파란색+초록 테두리: 같은 버튼'
$highlightLegend.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$highlightLegend.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
[void]$progressArea.Controls.Add($highlightLegend, 0, 1)
$progressArea.SetColumnSpan($highlightLegend, 3)
[void]$workArea.Controls.Add($progressArea, 0, 1)

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = '대기 중'
$statusLabel.AutoSize = $true
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(45, 90, 140)
$statusLabel.Margin = [System.Windows.Forms.Padding]::new(4, 0, 0, 6)
[void]$workArea.Controls.Add($statusLabel, 0, 2)

$logBox = [System.Windows.Forms.TextBox]::new()
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Dock = 'Fill'
$logBox.Font = [System.Drawing.Font]::new('Consolas', 9)
$logBox.BackColor = [System.Drawing.Color]::White
[void]$workArea.Controls.Add($logBox, 0, 3)

$script:activeProcess = $null
$script:activeArguments = $null
$script:outputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:errorQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:processFailed = $false
$script:activeAction = ''
$script:processExitObservedAt = $null
$script:cancelProcess = $null
$script:cancelOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:cancelErrorQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:cancelRequested = $false
$script:cancelExitObservedAt = $null
$script:actualProgress = 0.0
$script:currentAction = ''
$script:nextAction = ''
$script:actionButtonMap = [ordered]@{
    validate = $validateButton
    start = $startButton
    prepare = $prepareButton
    run = $runButton
    review = $reviewButton
    retry = $reviewButton
    'retry-prose' = $reviewButton
    web = $webButton
    export = $exportButton
    status = $statusButton
    stop = $stopButton
}

function Get-ActionName([string]$Action) {
    switch ($Action) {
        'validate' { return '설정 검사' }
        'start' { return '서비스 시작' }
        'prepare' { return '프로젝트 가져오기' }
        'run' { return '전체 번역' }
        'review' { return '문제 번역 검토' }
        'retry' { return '페이지 번역 재시도' }
        'retry-prose' { return '대사·설명문 일괄 재시도' }
        'web' { return 'Web UI 열기' }
        'export' { return '내보내기' }
        'status' { return '상태 새로고침' }
        'stop' { return '안전 종료' }
        default { return $Action }
    }
}

function Get-ProgressText([double]$Percent) {
    if ([math]::Abs($Percent - [math]::Round($Percent)) -lt 0.05) { return ('{0:0}' -f $Percent) }
    return ('{0:0.0}' -f $Percent)
}

function Set-ActionProgress {
    param(
        [Parameter(Mandatory)][double]$Percent,
        [Parameter(Mandatory)][string]$Detail
    )
    $clamped = [math]::Max(0.0, [math]::Min(100.0, $Percent))
    $script:actualProgress = $clamped
    $progressBar.Value = [int][math]::Round($clamped * 10.0)
    $progressText.Text = "$(Get-ProgressText $clamped)% · $Detail"
}

function Update-ActionHighlights {
    foreach ($button in @($script:actionButtonMap.Values | Select-Object -Unique)) {
        $button.UseVisualStyleBackColor = $true
        $button.BackColor = [System.Drawing.SystemColors]::Control
        $button.ForeColor = [System.Drawing.SystemColors]::ControlText
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
        $button.FlatAppearance.BorderSize = 1
    }
    if ($script:nextAction -and $script:actionButtonMap.Contains($script:nextAction)) {
        $button = $script:actionButtonMap[$script:nextAction]
        $button.UseVisualStyleBackColor = $false
        $button.BackColor = [System.Drawing.Color]::FromArgb(168, 230, 176)
        $button.ForeColor = [System.Drawing.Color]::FromArgb(20, 65, 28)
    }
    if ($script:currentAction -and $script:actionButtonMap.Contains($script:currentAction)) {
        $button = $script:actionButtonMap[$script:currentAction]
        $button.UseVisualStyleBackColor = $false
        $button.BackColor = [System.Drawing.Color]::FromArgb(45, 105, 180)
        $button.ForeColor = [System.Drawing.Color]::White
        if ($script:nextAction -and $script:actionButtonMap.Contains($script:nextAction) -and
            [object]::ReferenceEquals($button, $script:actionButtonMap[$script:nextAction])) {
            $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(35, 155, 65)
            $button.FlatAppearance.BorderSize = 4
        }
    }
}

function Set-CurrentAction([string]$Action) {
    $script:currentAction = $Action
    Update-ActionHighlights
}

function Set-NextAction([string]$Action) {
    $script:nextAction = $Action
    Update-ActionHighlights
}

function Set-NextActionFromStatus([object]$Data) {
    Set-NextAction (Get-LauncherRecommendedAction -Status $Data)
}

function Update-UiFromEvent([object]$EventObject) {
    $eventName = [string]$EventObject.event
    $data = $EventObject.data
    switch ($eventName) {
        'validated' { Set-ActionProgress 100 '설정 검사 완료'; Set-NextAction 'start' }
        'started' { Set-ActionProgress 100 '서비스 준비 완료'; Set-NextAction 'prepare' }
        'prepared' {
            Set-ActionProgress 100 $(if ($data.resumed) { "프로젝트 다시 열기 완료 · $($data.pages)페이지" } else { "가져오기 완료 · $($data.pages)페이지" })
            Set-NextAction 'run'
        }
        'progress' {
            $completed = [double]$data.completed
            $total = [double]$data.total
            $fraction = if ($null -ne $data.sidecar) { [double]$data.sidecar.percent / 100.0 } else { 0.0 }
            $percent = if ($total -gt 0) { (($completed + $fraction) / $total) * 100.0 } else { 0.0 }
            $stage = if ($data.stage) { [string]$data.stage } else { '준비' }
            $page = if ($data.serial_page_index) { "페이지 $($data.serial_page_index)/$($data.serial_page_total) · " } else { '' }
            $detail = if ($null -ne $data.sidecar) { "$page$stage · $([string]$data.sidecar.detail)" } else { "$page$stage · $([int]$completed)/$([int]$total)" }
            Set-ActionProgress $percent $detail
        }
        'validation_progress' {
            $phase = [string]$data.phase
            $percent = switch ($phase) {
                'settings' { 5 }
                'model_hash' {
                    $completed = if ($null -ne $data.completed_bytes) { [double]$data.completed_bytes } else { [double]$data.completed }
                    $total = if ($null -ne $data.total_bytes) { [double]$data.total_bytes } else { [double]$data.total }
                    5 + (35 * ($completed / [math]::Max(1, $total)))
                }
                'python' { 45 }
                'koharu' { 70 }
                'lifecycle' { 90 }
                default { $script:actualProgress }
            }
            Set-ActionProgress $percent "설정 검사 · $phase"
        }
        'startup_progress' {
            $percent = 5 + (90 * ([double]$data.completed / [math]::Max(1, [double]$data.total)))
            Set-ActionProgress $percent "서비스 시작 · $([string]$data.detail)"
        }
        'prepare_progress' {
            $percent = 5 + (90 * ([double]$data.completed / [math]::Max(1, [double]$data.total)))
            Set-ActionProgress $percent "프로젝트 가져오기 · $([string]$data.detail)"
        }
        'finished' {
            Set-ActionProgress 100 '전체 번역 완료'
            Set-NextAction $(if ([int]$data.review_count -gt 0) { 'review' } else { 'export' })
        }
        'review_retry_started' { $progressText.Text = "$(Get-ProgressText $script:actualProgress)% · 페이지 번역 재시도 진행량 대기" }
        'review_retry_finished' {
            Set-ActionProgress 100 '페이지 번역 재시도 완료'
            if ([int]$data.review_count -gt 0) { Set-NextAction 'review' }
            elseif ([string]$data.project_job_state -eq 'finished') { Set-NextAction 'export' }
            else { Set-NextAction 'run' }
        }
        'prose_retry_batch_started' { $progressText.Text = "$(Get-ProgressText $script:actualProgress)% · 대사·설명문 페이지 재시도 진행 중" }
        'prose_retry_batch_finished' {
            Set-ActionProgress 100 "대사·설명문 재시도 완료 · 성공 $([int]$data.succeeded)/$([int]$data.attempted)페이지"
            if ([int]$data.review_count -gt 0) { Set-NextAction 'review' }
            elseif ([string]$data.project_job_state -eq 'finished') { Set-NextAction 'export' }
            else { Set-NextAction 'run' }
        }
        'exported' { Set-ActionProgress 100 '내보내기 완료'; Set-NextAction 'stop' }
        'stopped' { Set-ActionProgress 100 '안전 종료 완료'; Set-NextAction 'validate' }
        'saved' { Set-ActionProgress 100 '설정 저장 완료' }
        'status' { Set-ActionProgress 100 '상태 확인 완료'; Set-NextActionFromStatus $data }
        'starting' { Set-ActionProgress 5 '서비스 프로세스 시작 및 응답 확인' }
        'importing' { Set-ActionProgress 5 '입력 목록 확인 및 가져오기' }
        'job_started' {
            $percent = if ([int]$data.pages -gt 0) { 100.0 * [int]$data.resumed_pages / [int]$data.pages } else { 0 }
            Set-ActionProgress $percent "페이지별 순차 작업 시작 · $($data.resumed_pages)/$($data.pages)페이지 완료"
        }
        'exporting' { Set-ActionProgress 5 '내보내기 사전 검사 및 렌더링' }
        'cancelled' { $progressText.Text = "$(Get-ProgressText $script:actualProgress)% · 취소 요청 전달됨" }
        'error' {
            $script:processFailed = $true
            $progressText.Text = "$(Get-ProgressText $script:actualProgress)% · 실패"
        }
    }
}

function Get-CommonArguments {
    return [ordered]@{
        SettingsPath = $settingsPath
        ProjectName = $projectBox.Text.Trim()
        InputPath = $inputBox.Text.Trim()
        OutputDirectory = $outputBox.Text.Trim()
        DataDirectory = $dataBox.Text.Trim()
        PythonExecutable = $pythonBox.Text.Trim()
        KoharuExecutable = $koharuBox.Text.Trim()
        HyModelDirectory = $modelDirBox.Text.Trim()
        QwenLifecycleScript = $lifecycleBox.Text.Trim()
        QwenApi = $qwenApiBox.Text.Trim()
        QwenModel = $qwenModelBox.Text.Trim()
        QwenLeasePath = $qwenLeaseBox.Text.Trim()
        KoharuPort = [int]$koharuPortBox.Value
        ServicePort = [int]$servicePortBox.Value
        ExportFormat = [string]$formatBox.SelectedItem
    }
}

function Get-UiReviewSettings {
    return [pscustomobject]@{ koharu_port = [int]$koharuPortBox.Value; service_port = [int]$servicePortBox.Value }
}

function Show-ReviewDialog {
    $reviewSettings = Get-UiReviewSettings
    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = '문제 번역 검토'
    $dialog.StartPosition = 'CenterParent'
    $dialog.MinimumSize = [System.Drawing.Size]::new(980, 650)
    $dialog.Size = [System.Drawing.Size]::new(1250, 780)
    $dialog.Font = $form.Font

    $layout = [System.Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock = 'Fill'
    $layout.Padding = [System.Windows.Forms.Padding]::new(12)
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 35))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 65))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$dialog.Controls.Add($layout)

    $defaultReviewHelp = '검토 항목을 자동 확정·불확실 효과음 원본 유지·대사/설명문 페이지별 1회 재시도의 세 묶음으로 줄입니다. 아래 목록에는 자동 확정 항목을 숨기고 실제 예외만 표시합니다.'
    $help = New-Label $defaultReviewHelp
    $help.MaximumSize = [System.Drawing.Size]::new(1180, 0)
    $help.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 8)
    [void]$layout.Controls.Add($help, 0, 0)

    $grid = [System.Windows.Forms.DataGridView]::new()
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.MultiSelect = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.AutoGenerateColumns = $false
    foreach ($spec in @(
        @('페이지', 150), @('상태', 80), @('확신', 65), @('검증 결과', 340), @('현재 적용 가능', 120)
    )) {
        $column = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $column.HeaderText = $spec[0]
        $column.Width = $spec[1]
        if ($spec[0] -eq '검증 결과') { $column.AutoSizeMode = 'Fill' }
        [void]$grid.Columns.Add($column)
    }
    [void]$layout.Controls.Add($grid, 0, 1)

    $candidatePanel = [System.Windows.Forms.TableLayoutPanel]::new()
    $candidatePanel.Dock = 'Fill'
    $candidatePanel.ColumnCount = 4
    $candidatePanel.RowCount = 2
    for ($columnIndex = 0; $columnIndex -lt 4; $columnIndex++) {
        [void]$candidatePanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 25))
    }
    [void]$candidatePanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$candidatePanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    $candidateLabels = @('일본어 원문', 'Hy-MT2 초벌', 'Qwen 검토본', '직접 수정')
    $candidateBoxes = @()
    for ($columnIndex = 0; $columnIndex -lt 4; $columnIndex++) {
        [void]$candidatePanel.Controls.Add((New-Label $candidateLabels[$columnIndex]), $columnIndex, 0)
        $box = [System.Windows.Forms.TextBox]::new()
        $box.Multiline = $true
        $box.ScrollBars = 'Vertical'
        $box.Dock = 'Fill'
        $box.Margin = [System.Windows.Forms.Padding]::new(3, 4, 6, 3)
        if ($columnIndex -lt 3) { $box.ReadOnly = $true; $box.BackColor = [System.Drawing.Color]::White }
        [void]$candidatePanel.Controls.Add($box, $columnIndex, 1)
        $candidateBoxes += $box
    }
    $sourcePreview, $firstPreview, $finalPreview, $manualPreview = $candidateBoxes
    [void]$layout.Controls.Add($candidatePanel, 0, 2)

    $buttons = [System.Windows.Forms.FlowLayoutPanel]::new()
    $buttons.Dock = 'Top'
    $buttons.AutoSize = $true
    $buttons.WrapContents = $true
    $applyFirstButton = New-Button 'Hy 초벌 적용' 115
    $applyFinalButton = New-Button 'Qwen 검토본 적용' 135
    $applyManualButton = New-Button '직접 수정 적용' 120
    $keepSourceButton = New-Button '원본 그림 유지' 120
    $metadataBatchButton = New-Button '문제 없는 항목 자동 확정' 205
    $effectBatchButton = New-Button '불확실 효과음 원본 유지' 205
    $retryProseButton = New-Button '대사·설명문 페이지 재시도' 210
    $retryPageButton = New-Button '이 페이지 번역 1회 재시도' 190
    $closeReviewButton = New-Button '닫기' 80
    $buttons.Controls.AddRange(@($applyFirstButton, $applyFinalButton, $applyManualButton, $keepSourceButton, $metadataBatchButton, $effectBatchButton, $retryProseButton, $retryPageButton, $closeReviewButton))
    [void]$layout.Controls.Add($buttons, 0, 3)

    $script:reviewDialogItems = @()
    $script:reviewResolutionPlan = $null
    $script:reviewRetryPageId = ''
    $script:reviewRetryProse = $false
    $getSelected = {
        if ($null -eq $grid.CurrentRow) { return $null }
        return $grid.CurrentRow.Tag
    }
    $updateSelection = {
        $item = & $getSelected
        if ($null -eq $item) {
            foreach ($box in $candidateBoxes) { $box.Text = '' }
            foreach ($button in @($applyFirstButton, $applyFinalButton, $applyManualButton, $keepSourceButton, $retryPageButton)) { $button.Enabled = $false }
            return
        }
        $sourcePreview.Text = [string]$item.source
        $firstPreview.Text = [string]$item.first_translation
        $finalPreview.Text = [string]$item.final_translation
        $manualPreview.Text = [string]$item.final_translation
        $applyFirstButton.Enabled = [bool]$item.layer_available
        $applyFinalButton.Enabled = [bool]$item.layer_available
        $applyManualButton.Enabled = [bool]$item.layer_available
        $keepSourceButton.Enabled = [bool]$item.layer_available
        $retryPageButton.Enabled = [bool]$item.retry_available -and [bool]$item.layer_available
    }
    $refreshRows = {
        $script:reviewResolutionPlan = Get-LauncherLocalResolutionPlan -Settings $reviewSettings
        $script:reviewDialogItems = @($script:reviewResolutionPlan.items)
        $grid.Rows.Clear()
        foreach ($item in @($script:reviewResolutionPlan.effect_items) + @($script:reviewResolutionPlan.prose_items) + @($script:reviewResolutionPlan.unavailable_items)) {
            $defectText = if (@($item.validator_defects).Count) { @($item.validator_defects) -join ', ' } else { '검토 필요' }
            $availability = if ($item.layer_available) { '가능' } else { [string]$item.availability_error }
            $rowIndex = $grid.Rows.Add([object[]]@(
                [string]$item.page_label, [string]$item.status, [string]$item.confidence, $defectText, $availability
            ))
            $grid.Rows[$rowIndex].Tag = $item
        }
        $metadataCount = @($script:reviewResolutionPlan.metadata_items).Count
        $effectCount = @($script:reviewResolutionPlan.effect_items).Count
        $effectReadyCount = @($script:reviewResolutionPlan.effect_ready_items).Count
        $effectDeferredCount = @($script:reviewResolutionPlan.effect_deferred_items).Count
        $proseCount = @($script:reviewResolutionPlan.prose_items).Count
        $prosePageCount = @($script:reviewResolutionPlan.prose_retry_pages).Count
        $unavailableCount = @($script:reviewResolutionPlan.unavailable_items).Count
        $metadataBatchButton.Text = if ($metadataCount -gt 0) { "문제 없는 $metadataCount`개 자동 확정" } else { '자동 확정 대상 없음' }
        $metadataBatchButton.Enabled = $metadataCount -gt 0
        $effectBatchButton.Text = if ($effectReadyCount -gt 0) { "불확실 효과음 $effectReadyCount`개 원본 유지" } else { '지금 유지할 효과음 없음' }
        $effectBatchButton.Enabled = $effectReadyCount -gt 0
        $retryProseButton.Text = if ($prosePageCount -gt 0) { "대사·설명문 $prosePageCount`페이지 재시도" } else { '재시도할 대사 페이지 없음' }
        $retryProseButton.Enabled = $prosePageCount -gt 0
        $deferredText = if ($effectDeferredCount -gt 0) { " 효과음 $effectDeferredCount`개는 섞인 대사 페이지를 재시도한 뒤 원본 유지할 수 있습니다." } else { '' }
        $unavailableText = if ($unavailableCount -gt 0) { " 현재 레이어 확인 불가 $unavailableCount`개는 일괄 작업에서 제외했습니다. 상태를 새로 고치세요." } else { '' }
        $help.Text = "전체 $($script:reviewDialogItems.Count)개: 자동 확정 $metadataCount`개(목록에서 숨김), 불확실 효과음 $effectCount`개, 대사·설명문 $proseCount`개/$prosePageCount`페이지.$deferredText$unavailableText"
        if ($grid.Rows.Count -gt 0) { $grid.Rows[0].Selected = $true; $grid.CurrentCell = $grid.Rows[0].Cells[0] }
        & $updateSelection
    }
    $applyDecision = {
        param([string]$Choice, [string]$Translation)
        $item = & $getSelected
        if ($null -eq $item) { return }
        try {
            [void](Set-LauncherReviewTranslation -Settings $reviewSettings -AuditJobId ([string]$item.audit_job_id) -RegionId ([string]$item.region_id) -Choice $Choice -Translation $Translation)
            Add-Log '사용자가 문제 번역 한 개를 검토해 적용했습니다.'
            & $refreshRows
            if ($script:reviewDialogItems.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show($dialog, '현재 프로젝트의 검토 항목을 모두 처리했습니다.', '문제 번역 검토', 'OK', 'Information') | Out-Null
                $dialog.Close()
            }
        }
        catch { [System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, '번역 적용 실패', 'OK', 'Error') | Out-Null }
    }

    $grid.Add_SelectionChanged({ & $updateSelection })
    $applyFirstButton.Add_Click({ & $applyDecision 'first' $firstPreview.Text })
    $applyFinalButton.Add_Click({ & $applyDecision 'final' $finalPreview.Text })
    $applyManualButton.Add_Click({ & $applyDecision 'manual' $manualPreview.Text })
    $keepSourceButton.Add_Click({ & $applyDecision 'source' $sourcePreview.Text })
    $metadataBatchButton.Add_Click({
        $targets = @($script:reviewDialogItems | Where-Object { Test-LauncherMetadataOnlyReviewItem -Item $_ })
        if ($targets.Count -eq 0) { return }
        $remainingConcrete = $script:reviewDialogItems.Count - $targets.Count
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $dialog,
            "구체적 issue가 없고 차단 결함도 없으며, 현재 Koharu 번역이 감사 결과와 일치하는 $($targets.Count)개를 빠르게 승인합니다.`r`n`r`n각 항목은 Koharu revision을 확인하며 현재 번역과 정확한 글꼴을 다시 적용합니다. 번역 품질을 자동 판정하는 기능은 아니며, 실제 문제가 표시된 $remainingConcrete`개는 그대로 남습니다. 계속할까요?",
            '구체적 문제 없는 항목 빠른 승인',
            'YesNo',
            'Question'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $batchControls = @($applyFirstButton, $applyFinalButton, $applyManualButton, $keepSourceButton, $metadataBatchButton, $effectBatchButton, $retryProseButton, $retryPageButton, $closeReviewButton)
        foreach ($control in $batchControls) { $control.Enabled = $false }
        $grid.Enabled = $false
        $dialog.ControlBox = $false
        $result = $null
        $failure = $null
        try {
            $result = Approve-LauncherMetadataOnlyReviews -Settings $reviewSettings -OnProgress {
                param($progress)
                $help.Text = "빠른 승인 진행: $($progress.applied)/$($progress.total) · $($progress.page_label)"
                $dialog.Text = "문제 번역 검토 · 빠른 승인 $($progress.applied)/$($progress.total)"
                [System.Windows.Forms.Application]::DoEvents()
            }
            Add-Log "구체적 문제 없는 번역 $([int]$result.applied)개를 사용자가 일괄 승인했습니다."
        }
        catch {
            $failure = $_.Exception.Message
            Add-Log $failure
        }
        finally {
            $dialog.Text = '문제 번역 검토'
            $dialog.ControlBox = $true
            $grid.Enabled = $true
            & $refreshRows
        }
        if ($failure) {
            [System.Windows.Forms.MessageBox]::Show($dialog, "$failure`r`n`r`n완료된 항목은 보존됐습니다. 목록을 새로 불러왔으므로 남은 항목부터 계속할 수 있습니다.", '빠른 승인 중단', 'OK', 'Error') | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show($dialog, "$([int]$result.applied)개를 승인했습니다. 실제 문제가 표시된 $([int]$result.remaining)개만 남았습니다.", '빠른 승인 완료', 'OK', 'Information') | Out-Null
        }
    })
    $effectBatchButton.Add_Click({
        $targets = @($script:reviewResolutionPlan.effect_ready_items)
        if ($targets.Count -eq 0) { return }
        $deferred = @($script:reviewResolutionPlan.effect_deferred_items).Count
        $deferredNotice = if ($deferred -gt 0) { "`r`n`r`n대사 재시도 페이지와 겹치는 $deferred`개는 덮어쓰기를 막기 위해 이번에는 보류합니다." } else { '' }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $dialog,
            "번역이 불확실한 효과음 $($targets.Count)개의 번역 레이어와 해당 영역 cleanup을 제거해 원본 페이지 픽셀을 보이게 합니다.$deferredNotice 계속할까요?",
            '불확실 효과음 원본 유지',
            'YesNo',
            'Question'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $batchControls = @($applyFirstButton, $applyFinalButton, $applyManualButton, $keepSourceButton, $metadataBatchButton, $effectBatchButton, $retryProseButton, $retryPageButton, $closeReviewButton)
        foreach ($control in $batchControls) { $control.Enabled = $false }
        $grid.Enabled = $false
        $dialog.ControlBox = $false
        $result = $null
        $failure = $null
        try {
            $result = Preserve-LauncherUncertainSoundEffects -Settings $reviewSettings -OnProgress {
                param($progress)
                $help.Text = "효과음 원본 유지: $($progress.applied)/$($progress.total) · $($progress.page_label)"
                $dialog.Text = "문제 번역 검토 · 원본 유지 $($progress.applied)/$($progress.total)"
                [System.Windows.Forms.Application]::DoEvents()
            }
            Add-Log "불확실한 효과음 $([int]$result.applied)개를 원본 그림으로 유지했습니다."
        }
        catch { $failure = $_.Exception.Message; Add-Log $failure }
        finally {
            $dialog.Text = '문제 번역 검토'
            $dialog.ControlBox = $true
            $grid.Enabled = $true
            & $refreshRows
        }
        if ($failure) {
            [System.Windows.Forms.MessageBox]::Show($dialog, "$failure`r`n`r`n완료된 원본 유지 결정은 보존됐습니다.", '효과음 원본 유지 중단', 'OK', 'Error') | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show($dialog, "$([int]$result.applied)개를 원본 그림으로 유지했습니다. 재시도 뒤 처리할 효과음: $([int]$result.deferred)개", '효과음 원본 유지 완료', 'OK', 'Information') | Out-Null
        }
    })
    $retryProseButton.Add_Click({
        $pages = @($script:reviewResolutionPlan.prose_retry_pages)
        if ($pages.Count -eq 0) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $dialog,
            "대사·설명문 문제가 남은 $($pages.Count)페이지의 번역 단계만 페이지당 한 번 실행합니다. 감지와 OCR은 반복하지 않고 같은 페이지를 자동으로 다시 재시도하지 않습니다. 의미상 실패한 페이지는 기록하고 다음 페이지로 진행하지만, 실행 환경 오류가 나면 즉시 중단합니다. 계속할까요?",
            '대사·설명문 페이지별 1회 재시도',
            'YesNo',
            'Question'
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:reviewRetryProse = $true
            $dialog.Close()
        }
    })
    $retryPageButton.Add_Click({
        $item = & $getSelected
        if ($null -eq $item) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $dialog,
            '이 페이지의 번역 단계만 한 번 다시 실행합니다. 감지와 OCR은 다시 실행하지 않으며, 성공한 뒤에는 두 번째 재시도가 허용되지 않습니다. 실행 준비 오류는 횟수에서 제외됩니다. 계속할까요?',
            '페이지 번역 1회 재시도',
            'YesNo',
            'Question'
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:reviewRetryPageId = [string]$item.page_id
            $dialog.Close()
        }
    })
    $closeReviewButton.Add_Click({ $dialog.Close() })

    try {
        & $refreshRows
        if ($script:reviewDialogItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($form, '현재 프로젝트에는 검토가 필요한 번역이 없습니다.', '문제 번역 검토', 'OK', 'Information') | Out-Null
            return [pscustomobject]@{ remaining = 0; retry_page_id = ''; retry_prose = $false }
        }
        [void]$dialog.ShowDialog($form)
        $remaining = @(Get-LauncherReviewItems -Settings $reviewSettings -SkipLayerValidation).Count
        return [pscustomobject]@{ remaining = $remaining; retry_page_id = $script:reviewRetryPageId; retry_prose = $script:reviewRetryProse }
    }
    finally {
        $dialog.Dispose()
        $script:reviewDialogItems = @()
        $script:reviewResolutionPlan = $null
        $script:reviewRetryPageId = ''
        $script:reviewRetryProse = $false
    }
}

function Assert-UiInput([string]$Action) {
    if ($Action -eq 'prepare') {
        if ([string]::IsNullOrWhiteSpace($projectBox.Text)) { throw '프로젝트 이름을 입력하세요.' }
        if ([string]::IsNullOrWhiteSpace($inputBox.Text) -or -not (Test-Path -LiteralPath $inputBox.Text)) { throw '존재하는 입력 파일이나 폴더를 선택하세요.' }
    }
    if ($Action -eq 'export' -and [string]::IsNullOrWhiteSpace($outputBox.Text)) { throw '결과 폴더를 선택하세요.' }
    if ($Action -in @('validate', 'start')) {
        foreach ($pair in @(
            @($pythonBox.Text, 'Python 실행 파일'), @($koharuBox.Text, 'Koharu 실행 파일'),
            @($modelDirBox.Text, 'Hy-MT2 모델 폴더'), @($lifecycleBox.Text, 'Qwen 수명주기 스크립트'),
            @($qwenLeaseBox.Text, 'Qwen 사용 잠금 파일')
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$pair[0])) { throw "$($pair[1]) 경로를 선택하세요." }
        }
    }
}

function Set-Busy([bool]$Busy, [string]$Action = '') {
    foreach ($button in $actionButtons) { $button.Enabled = -not $Busy }
    foreach ($control in $settingsControls) { $control.Enabled = -not $Busy }
    $cancelButton.Enabled = $Busy -and $Action -in @('run', 'retry', 'retry-prose') -and $null -eq $script:cancelProcess
    if ($Busy -and $script:currentAction -and $script:actionButtonMap.Contains($script:currentAction)) {
        # Keep the current button visibly blue. Its click is harmless while a backend process is active.
        $script:actionButtonMap[$script:currentAction].Enabled = $true
    }
    $advancedToggle.Enabled = -not $Busy
    $statusLabel.Text = if ($Busy) { "$(Get-ActionName $Action) 작업 중…" } else { '대기 중' }
    $form.UseWaitCursor = $Busy
    Update-ActionHighlights
}

function Start-BackendAction {
    param(
        [Parameter(Mandatory)][string]$Action,
        [switch]$UserInitiated,
        [hashtable]$ExtraArguments
    )
    if ($null -ne $script:activeProcess) { return }
    if ($UserInitiated -or -not $script:currentAction) { Set-CurrentAction $Action }
    Set-ActionProgress 0 "$(Get-ActionName $Action) 시작"
    try { Assert-UiInput $Action }
    catch {
        $statusLabel.Text = "$(Get-ActionName $Action) 입력 확인 필요 (0%)"
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '입력 확인', 'OK', 'Warning') | Out-Null
        return
    }
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Process -Id $PID).Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $root
    foreach ($argument in @('-NoProfile', '-File', $cliPath, '-Action', $Action)) { [void]$info.ArgumentList.Add([string]$argument) }
    $commonArguments = Get-CommonArguments
    foreach ($entry in $commonArguments.GetEnumerator()) {
        [void]$info.ArgumentList.Add("-$($entry.Key)")
        [void]$info.ArgumentList.Add([string]$entry.Value)
    }
    if ($ExtraArguments) {
        foreach ($entry in $ExtraArguments.GetEnumerator()) {
            [void]$info.ArgumentList.Add("-$($entry.Key)")
            [void]$info.ArgumentList.Add([string]$entry.Value)
        }
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    $process.SynchronizingObject = $form
    $script:outputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $script:errorQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $outputQueue = $script:outputQueue
    $errorQueue = $script:errorQueue
    $process.add_OutputDataReceived([System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) { $outputQueue.Enqueue($eventArgs.Data) }
    })
    $process.add_ErrorDataReceived([System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) { $errorQueue.Enqueue($eventArgs.Data) }
    })
    if (-not $process.Start()) { throw '백엔드 PowerShell을 시작하지 못했습니다.' }
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    $script:activeProcess = $process
    $script:activeArguments = $commonArguments
    $script:activeAction = $Action
    $script:processFailed = $false
    $script:processExitObservedAt = $null
    Add-Log "[$Action] 요청을 시작했습니다."
    Set-Busy $true $Action
    $pollTimer.Start()
}

function Start-CancelAction {
    if ($null -eq $script:activeProcess -or $script:activeAction -notin @('run', 'retry', 'retry-prose') -or $null -ne $script:cancelProcess) { return }
    if ($null -eq $script:activeArguments) { throw '현재 작업의 고정된 실행 설정을 찾을 수 없어 취소하지 않았습니다.' }
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Process -Id $PID).Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $root
    foreach ($argument in @('-NoProfile', '-File', $cliPath, '-Action', 'cancel')) { [void]$info.ArgumentList.Add([string]$argument) }
    foreach ($entry in $script:activeArguments.GetEnumerator()) {
        [void]$info.ArgumentList.Add("-$($entry.Key)")
        [void]$info.ArgumentList.Add([string]$entry.Value)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    $process.SynchronizingObject = $form
    $script:cancelOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $script:cancelErrorQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $outputQueue = $script:cancelOutputQueue
    $errorQueue = $script:cancelErrorQueue
    $process.add_OutputDataReceived([System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) { $outputQueue.Enqueue($eventArgs.Data) }
    })
    $process.add_ErrorDataReceived([System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) { $errorQueue.Enqueue($eventArgs.Data) }
    })
    if (-not $process.Start()) { throw '취소 백엔드를 시작하지 못했습니다.' }
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    $script:cancelProcess = $process
    $script:cancelExitObservedAt = $null
    $cancelButton.Enabled = $false
    Add-Log '현재 작업에 bounded 취소를 요청하는 중입니다.'
}

$pollTimer = [System.Windows.Forms.Timer]::new()
$pollTimer.Interval = 200
$pollTimer.Add_Tick({
    $line = $null
    while ($script:cancelOutputQueue.TryDequeue([ref]$line)) {
        try {
            $eventObject = $line | ConvertFrom-Json
            if ([string]$eventObject.event -eq 'cancelled') {
                $script:cancelRequested = $true
                Update-UiFromEvent $eventObject
                Add-Log (Get-FriendlyEvent $eventObject)
                $statusLabel.Text = '현재 작업 취소 처리 중…'
            }
            else { Add-Log (Get-FriendlyEvent $eventObject) }
        }
        catch { Add-Log $line }
    }
    while ($script:cancelErrorQueue.TryDequeue([ref]$line)) { if ($line) { Add-Log "취소 진단: $line" } }
    if ($null -ne $script:cancelProcess -and $script:cancelProcess.HasExited) {
        if ($null -eq $script:cancelExitObservedAt) { $script:cancelExitObservedAt = [datetime]::UtcNow }
        elseif (([datetime]::UtcNow - $script:cancelExitObservedAt).TotalMilliseconds -ge 500) {
            try { $script:cancelProcess.CancelOutputRead() } catch {}
            try { $script:cancelProcess.CancelErrorRead() } catch {}
            $cancelExitCode = $script:cancelProcess.ExitCode
            $script:cancelProcess.Dispose()
            $script:cancelProcess = $null
            $script:cancelExitObservedAt = $null
            if ($cancelExitCode -ne 0) {
                Add-Log "취소 요청을 완료하지 못했습니다 (종료 코드 $cancelExitCode)."
                $cancelButton.Enabled = $null -ne $script:activeProcess -and $script:activeAction -in @('run', 'retry', 'retry-prose')
            }
            if ($null -eq $script:activeProcess) { $pollTimer.Stop() }
        }
    }
    while ($script:outputQueue.TryDequeue([ref]$line)) {
        try {
            $eventObject = $line | ConvertFrom-Json
            Update-UiFromEvent $eventObject
            $message = Get-FriendlyEvent $eventObject
            Add-Log $message
        }
        catch { Add-Log $line }
    }
    while ($script:errorQueue.TryDequeue([ref]$line)) { if ($line) { Add-Log "진단: $line" } }
    if ($null -ne $script:activeProcess -and $script:activeProcess.HasExited) {
        if ($null -eq $script:processExitObservedAt) {
            $script:processExitObservedAt = [datetime]::UtcNow
            return
        }
        if (([datetime]::UtcNow - $script:processExitObservedAt).TotalMilliseconds -lt 500) { return }
        # WaitForExit would deadlock here because output callbacks are marshalled to this UI thread.
        try { $script:activeProcess.CancelOutputRead() } catch {}
        try { $script:activeProcess.CancelErrorRead() } catch {}
        while ($script:outputQueue.TryDequeue([ref]$line)) {
            try {
                $eventObject = $line | ConvertFrom-Json
                Update-UiFromEvent $eventObject
                Add-Log (Get-FriendlyEvent $eventObject)
            }
            catch { Add-Log $line }
        }
        while ($script:errorQueue.TryDequeue([ref]$line)) { if ($line) { Add-Log "진단: $line" } }
        $exitCode = $script:activeProcess.ExitCode
        $completedAction = $script:activeAction
        $script:activeProcess.Dispose()
        $script:activeProcess = $null
        $script:activeAction = ''
        $script:activeArguments = $null
        $script:processExitObservedAt = $null
        if ($null -eq $script:cancelProcess) { $pollTimer.Stop() }
        Set-Busy $false
        if ($exitCode -eq 0 -and -not $script:processFailed) {
            if ($script:actualProgress -lt 100) { Set-ActionProgress 100 "$(Get-ActionName $completedAction) 완료" }
            $statusLabel.Text = "$(Get-ActionName $completedAction) 완료 (100%)"
        }
        else {
            if ($script:cancelRequested) {
                $statusLabel.Text = "$(Get-ActionName $completedAction) 취소 완료 ($(Get-ProgressText $script:actualProgress)%)"
                Set-NextAction 'run'
            }
            else {
                $statusLabel.Text = "$(Get-ActionName $completedAction) 실패 ($(Get-ProgressText $script:actualProgress)%, 종료 코드 $exitCode)"
                try {
                    $currentStatus = Get-LauncherStatus -Settings (Get-UiReviewSettings)
                    Set-NextActionFromStatus $currentStatus
                }
                catch {
                    Set-NextAction $completedAction
                    Add-Log "실패 후 권장 단계를 확인하지 못해 같은 단계를 다시 표시합니다: $($_.Exception.Message)"
                }
                [System.Windows.Forms.MessageBox]::Show($form, '작업이 완료되지 않았습니다. 아래 로그의 오류 내용을 확인하세요.', 'Koharu 번역 도우미', 'OK', 'Error') | Out-Null
            }
        }
        $script:cancelRequested = $false
    }
})

$advancedToggle.Add_Click({
    $advanced.Visible = -not $advanced.Visible
    $advancedToggle.Text = if ($advanced.Visible) { '▼ 고급 실행 설정' } else { '▶ 고급 실행 설정' }
})
$inputFileButton.Add_Click({ Choose-File $inputBox '만화 이미지 또는 압축/PDF 선택' '지원 파일|*.png;*.jpg;*.jpeg;*.webp;*.cbz;*.zip;*.rar;*.pdf|모든 파일|*.*' })
$inputFolderButton.Add_Click({ Choose-Folder $inputBox '만화 이미지가 들어 있는 폴더 선택' })
$dataButton.Add_Click({ Choose-Folder $dataBox 'Koharu 프로젝트 작업 폴더 선택' })
$outputButton.Add_Click({ Choose-Folder $outputBox '번역 결과를 저장할 폴더 선택' })
$pythonButton.Add_Click({ Choose-File $pythonBox 'Python 실행 파일 선택' 'Python|python.exe|실행 파일|*.exe' })
$koharuButton.Add_Click({ Choose-File $koharuBox 'Koharu 실행 파일 선택' 'Koharu|koharu.exe|실행 파일|*.exe' })
$modelDirButton.Add_Click({ Choose-Folder $modelDirBox 'Hy-MT2 모델 폴더 선택' })
$lifecycleButton.Add_Click({ Choose-File $lifecycleBox 'Qwen 수명주기 PowerShell 스크립트 선택' 'PowerShell|*.ps1|모든 파일|*.*' })
$validateButton.Add_Click({ Start-BackendAction 'validate' -UserInitiated })
$startButton.Add_Click({ Start-BackendAction 'start' -UserInitiated })
$prepareButton.Add_Click({ Start-BackendAction 'prepare' -UserInitiated })
$runButton.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show($form, '현재 프로젝트의 모든 페이지에서 전체 번역 파이프라인을 실행할까요? GPU 작업이 시작됩니다.', '전체 번역 실행', 'YesNo', 'Question')
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Start-BackendAction 'run' -UserInitiated }
})
$reviewButton.Add_Click({
    if ($null -ne $script:activeProcess) { return }
    Set-CurrentAction 'review'
    Set-ActionProgress 0 '검토 항목 불러오는 중'
    try {
        $result = Show-ReviewDialog
        if (-not [string]::IsNullOrWhiteSpace([string]$result.retry_page_id)) {
            Start-BackendAction 'retry' -UserInitiated -ExtraArguments @{ ReviewPageId = [string]$result.retry_page_id }
            return
        }
        if ([bool]$result.retry_prose) {
            Start-BackendAction 'retry-prose' -UserInitiated
            return
        }
        Set-ActionProgress 100 "검토 화면 닫힘 · 남은 항목 $([int]$result.remaining)개"
        $statusLabel.Text = "문제 번역 검토 완료 · 남은 항목 $([int]$result.remaining)개"
        $currentStatus = Get-LauncherStatus -Settings (Get-UiReviewSettings)
        Set-NextActionFromStatus $currentStatus
    }
    catch {
        $progressText.Text = "$(Get-ProgressText $script:actualProgress)% · 검토 화면 오류"
        $statusLabel.Text = '문제 번역 검토 화면을 열지 못했습니다.'
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '문제 번역 검토', 'OK', 'Error') | Out-Null
    }
})
$webButton.Add_Click({
    $url = "http://127.0.0.1:$([int]$koharuPortBox.Value)/"
    $wasRecommended = $script:nextAction -eq 'web'
    Set-CurrentAction 'web'
    Set-ActionProgress 0 'Web UI 열기 시작'
    try {
        Start-Process $url
        Set-ActionProgress 100 'Web UI 열기 완료'
        $statusLabel.Text = 'Web UI 열기 완료 (100%)'
        if ($wasRecommended) { Set-NextAction 'run' }
    }
    catch {
        $statusLabel.Text = 'Web UI 열기 실패 (0%)'
        Add-Log "Web UI를 열지 못했습니다: $($_.Exception.Message)"
    }
})
$exportButton.Add_Click({
    if ($null -ne $script:activeProcess) { return }
    try {
        $reviewSettings = Get-UiReviewSettings
        $currentStatus = Get-LauncherStatus -Settings $reviewSettings
        if ([int]$currentStatus.review_count -gt 0) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $form,
                "검토 단계에 남은 $([int]$currentStatus.review_count)개를 따로 열지 않고, 현재 프로젝트에 실제 적용된 번역을 모두 OK로 승인한 뒤 내보냅니다.`r`n`r`n번역을 다시 생성하거나 바꾸지는 않습니다. 빈 번역이나 레이어 유실처럼 기계적으로 확인되는 오류는 자동 승인을 중단하지만, 두 로컬 모델이 놓친 의미 오역 가능성은 그대로 수용하게 됩니다. 계속할까요?",
                '검토 생략 후 현재 번역 모두 승인',
                'YesNo',
                'Question'
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $accepted = Approve-LauncherAllExistingReviews -Settings $reviewSettings
            Add-Log "사용자가 검토 단계를 생략해 현재 적용된 번역 $([int]$accepted.accepted)개를 모두 OK로 승인했습니다."
        }
        Start-BackendAction 'export' -UserInitiated
    }
    catch {
        Add-Log "검토 생략 또는 내보내기 준비 실패: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '내보내기 준비 실패', 'OK', 'Error') | Out-Null
    }
})
$statusButton.Add_Click({ Start-BackendAction 'status' -UserInitiated })
$cancelButton.Add_Click({ Start-CancelAction })
$stopButton.Add_Click({ Start-BackendAction 'stop' -UserInitiated })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($null -ne $script:activeProcess -or $null -ne $script:cancelProcess) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show($form, '백엔드 작업이 진행 중입니다. 완료될 때까지 창을 닫지 마세요.', '작업 진행 중', 'OK', 'Information') | Out-Null
    }
})
$script:nextAction = 'validate'
Update-ActionHighlights
$form.Add_Shown({
    if ($SnapshotPath) {
        if ($SnapshotAdvanced) {
            $advanced.Visible = $true
            $advancedToggle.Text = '▼ 고급 실행 설정'
        }
        $snapshotDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($SnapshotPath))
        [void](New-Item -ItemType Directory -Force -Path $snapshotDirectory)
        $form.Refresh()
        $bitmap = [System.Drawing.Bitmap]::new($form.ClientSize.Width, $form.ClientSize.Height)
        try {
            $form.DrawToBitmap($bitmap, [System.Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height))
            $bitmap.Save($SnapshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $bitmap.Dispose() }
        $form.Close()
        return
    }
    Add-Log 'GUI가 준비되었습니다. 먼저 고급 실행 설정을 확인하고 설정 검사를 실행하세요.'
    Start-BackendAction 'status'
})

[void][System.Windows.Forms.Application]::Run($form)
