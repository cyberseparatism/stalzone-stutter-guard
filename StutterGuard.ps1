param(
    [ValidateSet("gui", "scan", "restore")]
    [string]$Command = "gui"
)

$ErrorActionPreference = "Stop"
$AppVersion = "0.1.2"
$ConfigDir = Join-Path $env:LOCALAPPDATA "StalzoneStutterGuard"
$ConfigPath = Join-Path $ConfigDir "config.json"
$StatePath = Join-Path $ConfigDir "state.json"
$script:Config = $null
$script:GuardEnabled = $false
$script:GameWasRunning = $false
$script:OriginalPowerScheme = $null
$script:CpuSamples = @{}
$script:LastCpuSampleAt = $null
$script:LogicalProcessors = [Environment]::ProcessorCount
$script:LogBox = $null

function Ensure-ConfigDir {
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
}

function Get-DefaultConfig {
    [pscustomobject]@{ switchPowerPlan = $true; priority = "AboveNormal" }
}

function Load-Config {
    Ensure-ConfigDir
    if (-not (Test-Path $ConfigPath)) { return Get-DefaultConfig }
    try {
        $cfg = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json
        $priority = [string]$cfg.priority
        if ($priority -notin @("Normal", "AboveNormal", "High")) { $priority = "AboveNormal" }
        [pscustomobject]@{
            switchPowerPlan = if ($null -eq $cfg.switchPowerPlan) { $true } else { [bool]$cfg.switchPowerPlan }
            priority = $priority
        }
    } catch { Get-DefaultConfig }
}

function Save-Config([object]$Config) {
    Ensure-ConfigDir
    $Config | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $ConfigPath
}

function Save-State {
    Ensure-ConfigDir
    [pscustomobject]@{
        originalPowerScheme = $script:OriginalPowerScheme
        guardEnabled = $script:GuardEnabled
        savedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json | Set-Content -Encoding UTF8 $StatePath
}

function Clear-State {
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force -ErrorAction SilentlyContinue }
}

function Get-ActivePowerScheme {
    try {
        $raw = (& powercfg.exe /GETACTIVESCHEME 2>$null | Out-String).Trim()
        if ($raw -match '([A-Fa-f0-9-]{36})') {
            $guid = $matches[1]
            $name = ""
            if ($raw -match '\((.+)\)') { $name = $matches[1].Trim() }
            return [pscustomobject]@{ Guid = $guid; Name = $name }
        }
    } catch {}
    return $null
}

function Set-HighPerformancePowerPlan {
    if ($null -eq $script:OriginalPowerScheme) {
        $active = Get-ActivePowerScheme
        if ($null -ne $active) {
            $script:OriginalPowerScheme = $active.Guid
            Save-State
        }
    }
    try {
        & powercfg.exe /S SCHEME_MIN 2>$null | Out-Null
        return $true
    } catch { return $false }
}

function Restore-PowerPlan {
    if ([string]::IsNullOrWhiteSpace($script:OriginalPowerScheme)) { return $true }
    try {
        & powercfg.exe /S $script:OriginalPowerScheme 2>$null | Out-Null
        $script:OriginalPowerScheme = $null
        Save-State
        return $true
    } catch { return $false }
}

function Restore-RecoveryState {
    Ensure-ConfigDir
    if (-not (Test-Path $StatePath)) { return $false }
    try {
        $state = Get-Content -Raw -Encoding UTF8 $StatePath | ConvertFrom-Json
        $guid = [string]$state.originalPowerScheme
        if (-not [string]::IsNullOrWhiteSpace($guid)) { & powercfg.exe /S $guid 2>$null | Out-Null }
        Clear-State
        return $true
    } catch { return $false }
}

function Get-GameProcesses {
    $found = @{}

    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $name = [string]$p.ProcessName

        if ($name -notmatch '(?i)stalzone|stalcraft|stalcraftx') {
            continue
        }

        if ($name -match '(?i)launcher|updater|unins|crash|cef') {
            continue
        }

        $path = ""

        try {
            $path = [string]$p.Path
        } catch {}

        if ([string]::IsNullOrWhiteSpace($path)) {
            try {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction Stop
                $path = [string]$cim.ExecutablePath
            } catch {}
        }

        $found[[int]$p.Id] = [pscustomobject]@{
            Id = [int]$p.Id
            Name = $name
            Path = $path
            WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB)
        }
    }

    try {
        foreach ($item in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            $hay = "{0} {1} {2}" -f `
                [string]$item.Name, `
                [string]$item.ExecutablePath, `
                [string]$item.CommandLine

            if ($hay -notmatch '(?i)stalcraft|stalzone|stalcraftx') {
                continue
            }

            if ($hay -match '(?i)launcher|updater|unins|crash|cef') {
                continue
            }

            $pid = [int]$item.ProcessId
            if ($found.ContainsKey($pid)) {
                continue
            }

            try {
                $p = Get-Process -Id $pid -ErrorAction Stop
                $found[$pid] = [pscustomobject]@{
                    Id = $pid
                    Name = [string]$p.ProcessName
                    Path = [string]$item.ExecutablePath
                    WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB)
                }
            } catch {}
        }
    } catch {}

    return @($found.Values | Sort-Object WorkingSetMB -Descending)
}

function Set-GamePriority([object[]]$Processes, [string]$Priority) {
    foreach ($entry in @($Processes)) {
        try {
            $p = Get-Process -Id $entry.Id -ErrorAction Stop
            if ([string]$p.PriorityClass -ne $Priority) { $p.PriorityClass = $Priority }
        } catch {}
    }
}

function Get-JavaEnvironmentIssues {
    $issues = @()
    foreach ($name in @("_JAVA_OPTIONS", "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS")) {
        foreach ($target in @("User", "Machine", "Process")) {
            try {
                $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::$target)
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $issues += [pscustomobject]@{ Name = $name; Scope = $target; Value = $value }
                }
            } catch {}
        }
    }
    @($issues)
}

function Get-RamRatedSpeed([string]$PartNumber) {
    if ([string]::IsNullOrWhiteSpace($PartNumber)) { return $null }
    $p = $PartNumber.Trim().ToUpperInvariant()
    if ($p -match '^KF(\d{4})') { return [int]$matches[1] }
    if ($p -match '(?:DDR4|DDR5)[-_ ]?(\d{4})') { return [int]$matches[1] }
    if ($p -match '(?:^|[^0-9])(2666|2800|2933|3000|3200|3333|3466|3600|3733|3800|4000|4266|4400|4800|5200|5600|6000|6200|6400|6800|7200|7600|8000)(?:[^0-9]|$)') { return [int]$matches[1] }
    return $null
}

function Get-SystemSnapshot {
    $cpu = $null; $gpu = $null; $ram = @(); $os = $null; $page = @()
    try { $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 } catch {}
    try { $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch '(?i)basic display|remote' } | Sort-Object AdapterRAM -Descending | Select-Object -First 1 } catch {}
    try { $ram = @(Get-CimInstance Win32_PhysicalMemory) } catch {}
    try { $os = Get-CimInstance Win32_OperatingSystem } catch {}
    try { $page = @(Get-CimInstance Win32_PageFileUsage) } catch {}

    $total = 0L; $configured = @(); $rated = @(); $parts = @()
    foreach ($m in $ram) {
        $total += [int64]$m.Capacity
        if ($m.ConfiguredClockSpeed) { $configured += [int]$m.ConfiguredClockSpeed }
        $part = [string]$m.PartNumber
        if (-not [string]::IsNullOrWhiteSpace($part)) {
            $parts += $part.Trim()
            $r = Get-RamRatedSpeed $part
            if ($null -ne $r) { $rated += $r }
        }
    }

    $pageMB = 0
    foreach ($x in $page) { $pageMB += [int]$x.AllocatedBaseSize }

    [pscustomobject]@{
        Cpu = if ($cpu) { [string]$cpu.Name.Trim() } else { "Не определён" }
        Cores = if ($cpu) { [int]$cpu.NumberOfCores } else { 0 }
        Threads = if ($cpu) { [int]$cpu.NumberOfLogicalProcessors } else { $script:LogicalProcessors }
        Gpu = if ($gpu) { [string]$gpu.Name.Trim() } else { "Не определена" }
        GpuDriver = if ($gpu) { [string]$gpu.DriverVersion } else { "" }
        RamGB = [math]::Round($total / 1GB)
        RamModules = $ram.Count
        RamSpeed = if ($configured.Count) { [int](($configured | Measure-Object -Minimum).Minimum) } else { 0 }
        RatedRamSpeed = if ($rated.Count) { [int](($rated | Measure-Object -Maximum).Maximum) } else { $null }
        RamParts = @($parts)
        FreeRamMB = if ($os) { [math]::Round(([int64]$os.FreePhysicalMemory) / 1024) } else { 0 }
        PageFileMB = $pageMB
    }
}

function Get-GameDriveInfo([object[]]$GameProcesses) {
    if ($GameProcesses.Count -eq 0) {
        return [pscustomobject]@{ Text = "Определится после запуска игры"; Warning = $false }
    }

    $path = [string]$GameProcesses[0].Path
    if ([string]::IsNullOrWhiteSpace($path)) {
        return [pscustomobject]@{ Text = "Путь процесса недоступен"; Warning = $false }
    }

    $letter = [System.IO.Path]::GetPathRoot($path).TrimEnd('\').TrimEnd(':')

    try {
        $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop

        $physical = Get-PhysicalDisk -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DeviceId -eq [string]$disk.Number -or
                $_.FriendlyName -eq $disk.FriendlyName
            } |
            Select-Object -First 1

        $bus = [string]$disk.BusType
        $model = [string]$disk.FriendlyName
        if ([string]::IsNullOrWhiteSpace($model)) {
            $model = [string]$disk.Model
        }

        $media = if ($null -ne $physical) { [string]$physical.MediaType } else { "" }

        $kind = ""
        if ($bus -match '(?i)NVMe') {
            $kind = "NVMe SSD"
        } elseif ($media -match '(?i)SSD') {
            $kind = "SSD"
        } elseif ($media -match '(?i)HDD') {
            $kind = "HDD"
        } elseif ($model -match '(?i)SSD|NVMe|Solid State') {
            $kind = "SSD"
        } elseif ($bus -match '(?i)USB') {
            $kind = "USB"
        } elseif (-not [string]::IsNullOrWhiteSpace($bus) -and $bus -ne "Unknown") {
            $kind = $bus
        } else {
            $kind = "тип не определён"
        }

        $display = if ([string]::IsNullOrWhiteSpace($model)) {
            "$letter`:  $kind"
        } else {
            "$letter`:  $kind · $model"
        }

        return [pscustomobject]@{
            Text = $display
            Warning = ($kind -eq "HDD")
        }
    } catch {
        return [pscustomobject]@{
            Text = "$letter`:  тип диска не определён"
            Warning = $false
        }
    }
}

function Get-BackgroundLoad([int[]]$ExcludePids = @()) {
    $now = Get-Date
    $elapsed = if ($null -eq $script:LastCpuSampleAt) {
        1.0
    } else {
        [math]::Max(($now - $script:LastCpuSampleAt).TotalSeconds, 0.25)
    }

    $next = @{}
    $rows = @()

    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -in $ExcludePids) { continue }
        if ($p.ProcessName -in @("Idle", "System", "Registry")) { continue }

        $cpu = 0.0
        try { $cpu = [double]$p.CPU } catch {}
        $next[$p.Id] = $cpu

        $usage = 0.0
        if ($script:CpuSamples.ContainsKey($p.Id)) {
            $delta = [math]::Max($cpu - [double]$script:CpuSamples[$p.Id], 0)
            $usage = ($delta / $elapsed) * 100 / [math]::Max($script:LogicalProcessors, 1)
        }

        if ($usage -ge 0.2 -or $p.WorkingSet64 -gt 400MB) {
            $rows += [pscustomobject]@{
                Name = $p.ProcessName
                Cpu = $usage
                Ram = ($p.WorkingSet64 / 1MB)
            }
        }
    }

    $script:CpuSamples = $next
    $script:LastCpuSampleAt = $now

    $grouped = foreach ($group in @($rows | Group-Object Name)) {
        $cpuSum = ($group.Group | Measure-Object Cpu -Sum).Sum
        $ramSum = ($group.Group | Measure-Object Ram -Sum).Sum

        [pscustomobject]@{
            Name = $group.Name
            Cpu = [math]::Round($cpuSum, 1)
            Ram = [math]::Round($ramSum)
        }
    }

    return @(
        $grouped |
        Sort-Object @{Expression="Cpu";Descending=$true}, @{Expression="Ram";Descending=$true} |
        Select-Object -First 6
    )
}

function Write-Log([string]$Text) {
    if ($null -eq $script:LogBox) { return }
    $script:LogBox.AppendText("$(Get-Date -Format 'HH:mm:ss')  $Text`r`n")
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
}

function Initialize-NativeDarkMode {
    if ("StutterGuardNativeTheme" -as [type]) { return }

    $code = @"
using System;
using System.Runtime.InteropServices;

public static class StutterGuardNativeTheme
{
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    public static void Apply(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return;
        try { SetWindowTheme(handle, "DarkMode_Explorer", null); } catch {}
    }
}
"@

    Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
}

function Set-NativeDarkTheme([System.Windows.Forms.Control]$Control) {
    if ($null -eq $Control) { return }

    try { [StutterGuardNativeTheme]::Apply($Control.Handle) } catch {}

    foreach ($child in $Control.Controls) {
        Set-NativeDarkTheme $child
    }
}

function Get-Theme {
    @{
        Bg=[System.Drawing.Color]::FromArgb(9,12,17); Header=[System.Drawing.Color]::FromArgb(12,16,23); Card=[System.Drawing.Color]::FromArgb(16,22,31)
        Card2=[System.Drawing.Color]::FromArgb(20,27,38); Border=[System.Drawing.Color]::FromArgb(37,48,65); Grid=[System.Drawing.Color]::FromArgb(30,40,54)
        Text=[System.Drawing.Color]::FromArgb(239,243,249); Muted=[System.Drawing.Color]::FromArgb(139,151,170); Accent=[System.Drawing.Color]::FromArgb(99,112,255)
        Accent2=[System.Drawing.Color]::FromArgb(82,190,255); Green=[System.Drawing.Color]::FromArgb(82,210,143); Yellow=[System.Drawing.Color]::FromArgb(245,194,73)
        Red=[System.Drawing.Color]::FromArgb(247,103,112); Select=[System.Drawing.Color]::FromArgb(45,55,91)
    }
}

function New-Button([string]$Text, [int]$Width, [string]$Kind = "secondary") {
    $t = Get-Theme
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Size = New-Object System.Drawing.Size($Width,38); $b.FlatStyle = "Flat"; $b.FlatAppearance.BorderSize = 1
    $b.Font = New-Object System.Drawing.Font("Segoe UI Semibold",9); $b.Cursor = [System.Windows.Forms.Cursors]::Hand; $b.UseVisualStyleBackColor = $false
    if ($Kind -eq "primary") { $b.BackColor=$t.Accent; $b.ForeColor=[System.Drawing.Color]::White; $b.FlatAppearance.BorderColor=$t.Accent }
    elseif ($Kind -eq "danger") { $b.BackColor=[System.Drawing.Color]::FromArgb(44,25,31); $b.ForeColor=$t.Red; $b.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(92,45,56) }
    else { $b.BackColor=$t.Card2; $b.ForeColor=$t.Text; $b.FlatAppearance.BorderColor=$t.Border }
    $b
}

function New-Card([System.Windows.Forms.Control]$Parent,[int]$X,[int]$Y,[int]$W,[string]$Title,[string]$Value) {
    $t=Get-Theme
    $p=New-Object System.Windows.Forms.Panel; $p.Location=New-Object System.Drawing.Point($X,$Y); $p.Size=New-Object System.Drawing.Size($W,82); $p.BackColor=$t.Card; $Parent.Controls.Add($p)
    $a=New-Object System.Windows.Forms.Panel; $a.Location=New-Object System.Drawing.Point(0,0); $a.Size=New-Object System.Drawing.Size(4,82); $a.BackColor=$t.Accent; $p.Controls.Add($a)
    $l1=New-Object System.Windows.Forms.Label; $l1.Text=$Title.ToUpperInvariant(); $l1.ForeColor=$t.Muted; $l1.Font=New-Object System.Drawing.Font("Segoe UI Semibold",8); $l1.AutoSize=$true; $l1.Location=New-Object System.Drawing.Point(16,14); $p.Controls.Add($l1)
    $l2=New-Object System.Windows.Forms.Label; $l2.Text=$Value; $l2.ForeColor=$t.Text; $l2.Font=New-Object System.Drawing.Font("Segoe UI Semibold",15); $l2.Location=New-Object System.Drawing.Point(16,39); $l2.Size=New-Object System.Drawing.Size(($W-28),29); $l2.AutoEllipsis=$true; $p.Controls.Add($l2)
    $l2
}

function Add-InfoRow([System.Windows.Forms.Control]$Parent,[int]$Y,[string]$Name) {
    $t=Get-Theme
    $n=New-Object System.Windows.Forms.Label; $n.Text=$Name; $n.ForeColor=$t.Muted; $n.Font=New-Object System.Drawing.Font("Segoe UI Semibold",8); $n.Location=New-Object System.Drawing.Point(18,$Y); $n.Size=New-Object System.Drawing.Size(120,22); $Parent.Controls.Add($n)
    $v=New-Object System.Windows.Forms.Label; $v.Text="—"; $v.ForeColor=$t.Text; $v.Font=New-Object System.Drawing.Font("Segoe UI",9); $v.Location=New-Object System.Drawing.Point(142,($Y-2)); $v.Size=New-Object System.Drawing.Size(470,25); $v.AutoEllipsis=$true; $Parent.Controls.Add($v)
    $v
}

function New-LoadGrid {
    $t=Get-Theme
    $g=New-Object System.Windows.Forms.DataGridView
    $g.AllowUserToAddRows=$false; $g.AllowUserToDeleteRows=$false; $g.AllowUserToResizeRows=$false; $g.RowHeadersVisible=$false; $g.ReadOnly=$true; $g.MultiSelect=$false; $g.SelectionMode="FullRowSelect"
    $g.BackgroundColor=$t.Card2; $g.BorderStyle="None"; $g.CellBorderStyle="SingleHorizontal"; $g.ColumnHeadersBorderStyle="None"; $g.GridColor=$t.Grid; $g.EnableHeadersVisualStyles=$false; $g.ColumnHeadersHeight=34; $g.RowTemplate.Height=30
    $g.ColumnHeadersDefaultCellStyle.BackColor=$t.Card2; $g.ColumnHeadersDefaultCellStyle.ForeColor=$t.Muted; $g.ColumnHeadersDefaultCellStyle.SelectionBackColor=$t.Card2; $g.ColumnHeadersDefaultCellStyle.SelectionForeColor=$t.Muted; $g.ColumnHeadersDefaultCellStyle.Font=New-Object System.Drawing.Font("Segoe UI Semibold",8)
    $g.DefaultCellStyle.BackColor=$t.Card2; $g.DefaultCellStyle.ForeColor=$t.Text; $g.DefaultCellStyle.SelectionBackColor=$t.Select; $g.DefaultCellStyle.SelectionForeColor=$t.Text; $g.DefaultCellStyle.Font=New-Object System.Drawing.Font("Segoe UI",8)
    $c=New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c.Name="Process"; $c.HeaderText="ПРОЦЕСС"; $c.AutoSizeMode="Fill"; [void]$g.Columns.Add($c)
    $c=New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c.Name="Cpu"; $c.HeaderText="CPU"; $c.Width=64; [void]$g.Columns.Add($c)
    $c=New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c.Name="Ram"; $c.HeaderText="RAM"; $c.Width=82; [void]$g.Columns.Add($c)
    $g
}

function Start-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $recovered=Restore-RecoveryState; $script:Config=Load-Config; $snapshot=Get-SystemSnapshot; $t=Get-Theme

    $form=New-Object System.Windows.Forms.Form; $form.Text="STALZONE // STUTTER GUARD — v$AppVersion"; $form.StartPosition="CenterScreen"; $form.Size=New-Object System.Drawing.Size(1180,790); $form.MinimumSize=New-Object System.Drawing.Size(1080,730); $form.AutoScaleMode="Dpi"; $form.Font=New-Object System.Drawing.Font("Segoe UI",9); $form.BackColor=$t.Bg; $form.ForeColor=$t.Text
    $header=New-Object System.Windows.Forms.Panel; $header.Dock="Top"; $header.Height=82; $header.BackColor=$t.Header; $form.Controls.Add($header)
    $mark=New-Object System.Windows.Forms.Panel; $mark.Location=New-Object System.Drawing.Point(22,20); $mark.Size=New-Object System.Drawing.Size(5,41); $mark.BackColor=$t.Accent; $header.Controls.Add($mark)
    $title=New-Object System.Windows.Forms.Label; $title.Text="STALZONE // STUTTER GUARD"; $title.Font=New-Object System.Drawing.Font("Segoe UI Semibold",18); $title.ForeColor=$t.Text; $title.AutoSize=$true; $title.Location=New-Object System.Drawing.Point(39,14); $header.Controls.Add($title)
    $sub=New-Object System.Windows.Forms.Label; $sub.Text="Контроль среды Windows для стабильной игровой сессии"; $sub.ForeColor=$t.Muted; $sub.AutoSize=$true; $sub.Location=New-Object System.Drawing.Point(41,49); $header.Controls.Add($sub)
    $badge=New-Object System.Windows.Forms.Label; $badge.Text="ИНСТРУМЕНТ СООБЩЕСТВА"; $badge.ForeColor=$t.Accent2; $badge.Font=New-Object System.Drawing.Font("Segoe UI Semibold",8); $badge.AutoSize=$true; $badge.Anchor="Top,Right"; $badge.Location=New-Object System.Drawing.Point(970,12); $header.Controls.Add($badge)
    foreach ($item in @(@("Discord: cyberseparatism",32),@("Telegram: @cyberseparatism",51))) { $l=New-Object System.Windows.Forms.Label; $l.Text=$item[0]; $l.ForeColor=$t.Muted; $l.Font=New-Object System.Drawing.Font("Segoe UI",8); $l.AutoSize=$true; $l.Anchor="Top,Right"; $l.Location=New-Object System.Drawing.Point(970,[int]$item[1]); $header.Controls.Add($l) }

    $cardGame=New-Card $form 22 98 250 "Игра" "НЕ ЗАПУЩЕНА"
    $cardGuard=New-Card $form 282 98 250 "Stutter Guard" "ВЫКЛЮЧЕН"
    $cardRam=New-Card $form 542 98 285 "Оперативная память" "$($snapshot.RamGB) ГБ · $($snapshot.RamSpeed) MT/s"
    $cardPower=New-Card $form 837 98 303 "План питания" "—"; $cardPower.Font=New-Object System.Drawing.Font("Segoe UI Semibold",11)

    $left=New-Object System.Windows.Forms.Panel; $left.Location=New-Object System.Drawing.Point(22,195); $left.Size=New-Object System.Drawing.Size(665,500); $left.Anchor="Top,Bottom,Left,Right"; $left.BackColor=$t.Card; $form.Controls.Add($left)
    $lt=New-Object System.Windows.Forms.Label; $lt.Text="СИСТЕМА"; $lt.ForeColor=$t.Text; $lt.Font=New-Object System.Drawing.Font("Segoe UI Semibold",11); $lt.AutoSize=$true; $lt.Location=New-Object System.Drawing.Point(18,16); $left.Controls.Add($lt)
    $cpuValue=Add-InfoRow $left 56 "ПРОЦЕССОР"; $gpuValue=Add-InfoRow $left 88 "ВИДЕОКАРТА"; $ramValue=Add-InfoRow $left 120 "ОЗУ"; $pageValue=Add-InfoRow $left 152 "ФАЙЛ ПОДКАЧКИ"; $driveValue=Add-InfoRow $left 184 "ДИСК ИГРЫ"; $gameValue=Add-InfoRow $left 216 "ПРОЦЕСС ИГРЫ"
    $priorityValue=Add-InfoRow $left 248 "ПРИОРИТЕТ"
    $ct=New-Object System.Windows.Forms.Label; $ct.Text="ПРОВЕРКИ"; $ct.ForeColor=$t.Text; $ct.Font=New-Object System.Drawing.Font("Segoe UI Semibold",11); $ct.AutoSize=$true; $ct.Location=New-Object System.Drawing.Point(18,298); $left.Controls.Add($ct)
    $checkRam=New-Object System.Windows.Forms.Label; $checkRam.Size=New-Object System.Drawing.Size(610,42); $checkRam.Location=New-Object System.Drawing.Point(18,299); $left.Controls.Add($checkRam)
    $checkJava=New-Object System.Windows.Forms.Label; $checkJava.Size=New-Object System.Drawing.Size(610,46); $checkJava.Location=New-Object System.Drawing.Point(18,344); $left.Controls.Add($checkJava)
    $checkMemory=New-Object System.Windows.Forms.Label; $checkMemory.Size=New-Object System.Drawing.Size(610,42); $checkMemory.Location=New-Object System.Drawing.Point(18,393); $left.Controls.Add($checkMemory)

    $right=New-Object System.Windows.Forms.Panel; $right.Location=New-Object System.Drawing.Point(705,195); $right.Size=New-Object System.Drawing.Size(435,500); $right.Anchor="Top,Bottom,Right"; $right.BackColor=$t.Card; $form.Controls.Add($right)
    $rt=New-Object System.Windows.Forms.Label; $rt.Text="ПРОФИЛЬ GUARD"; $rt.ForeColor=$t.Text; $rt.Font=New-Object System.Drawing.Font("Segoe UI Semibold",11); $rt.AutoSize=$true; $rt.Location=New-Object System.Drawing.Point(18,16); $right.Controls.Add($rt)
    $chkPower=New-Object System.Windows.Forms.CheckBox; $chkPower.Text="Переключать Windows на высокую производительность"; $chkPower.ForeColor=$t.Text; $chkPower.BackColor=$t.Card; $chkPower.Checked=[bool]$script:Config.switchPowerPlan; $chkPower.Location=New-Object System.Drawing.Point(20,51); $chkPower.Size=New-Object System.Drawing.Size(390,26); $right.Controls.Add($chkPower)
    $pl=New-Object System.Windows.Forms.Label; $pl.Text="ПРИОРИТЕТ ПРОЦЕССА"; $pl.ForeColor=$t.Muted; $pl.Font=New-Object System.Drawing.Font("Segoe UI Semibold",8); $pl.AutoSize=$true; $pl.Location=New-Object System.Drawing.Point(20,88); $right.Controls.Add($pl)
    $cmb=New-Object System.Windows.Forms.ComboBox; $cmb.DropDownStyle="DropDownList"; $cmb.BackColor=$t.Card2; $cmb.ForeColor=$t.Text; $cmb.FlatStyle="Flat"; $cmb.Location=New-Object System.Drawing.Point(20,108); $cmb.Size=New-Object System.Drawing.Size(395,28); [void]$cmb.Items.Add("Обычный"); [void]$cmb.Items.Add("Выше обычного"); [void]$cmb.Items.Add("Высокий"); $cmb.SelectedIndex=if($script:Config.priority -eq "Normal"){0}elseif($script:Config.priority -eq "High"){2}else{1}; $right.Controls.Add($cmb)
    $btnGuard=New-Button "ВКЛЮЧИТЬ STUTTER GUARD" 395 "primary"; $btnGuard.Location=New-Object System.Drawing.Point(20,151); $right.Controls.Add($btnGuard)
    $btnRestore=New-Button "ВОССТАНОВИТЬ НАСТРОЙКИ WINDOWS" 395; $btnRestore.Location=New-Object System.Drawing.Point(20,197); $right.Controls.Add($btnRestore)
    $loadTitle=New-Object System.Windows.Forms.Label; $loadTitle.Text="ФОНОВАЯ НАГРУЗКА"; $loadTitle.ForeColor=$t.Text; $loadTitle.Font=New-Object System.Drawing.Font("Segoe UI Semibold",11); $loadTitle.AutoSize=$true; $loadTitle.Location=New-Object System.Drawing.Point(18,253); $right.Controls.Add($loadTitle)
    $loadSub=New-Object System.Windows.Forms.Label; $loadSub.Text="Процессы с заметной нагрузкой на CPU или память"; $loadSub.ForeColor=$t.Muted; $loadSub.Font=New-Object System.Drawing.Font("Segoe UI",8); $loadSub.AutoSize=$true; $loadSub.Location=New-Object System.Drawing.Point(20,276); $right.Controls.Add($loadSub)
    $loadGrid=New-LoadGrid; $loadGrid.Location=New-Object System.Drawing.Point(20,302); $loadGrid.Size=New-Object System.Drawing.Size(395,180); $loadGrid.Anchor="Top,Bottom,Left,Right"; $right.Controls.Add($loadGrid)

    $logTitle=New-Object System.Windows.Forms.Label; $logTitle.Text="ЖУРНАЛ"; $logTitle.ForeColor=$t.Muted; $logTitle.Font=New-Object System.Drawing.Font("Segoe UI Semibold",8); $logTitle.AutoSize=$true; $logTitle.Location=New-Object System.Drawing.Point(22,711); $logTitle.Anchor="Bottom,Left"; $form.Controls.Add($logTitle)
    $script:LogBox=New-Object System.Windows.Forms.TextBox; $script:LogBox.Multiline=$true; $script:LogBox.ReadOnly=$true; $script:LogBox.BorderStyle="None"; $script:LogBox.ScrollBars="None"; $script:LogBox.BackColor=$t.Bg; $script:LogBox.ForeColor=$t.Muted; $script:LogBox.Font=New-Object System.Drawing.Font("Consolas",8); $script:LogBox.Location=New-Object System.Drawing.Point(82,706); $script:LogBox.Size=New-Object System.Drawing.Size(600,40); $script:LogBox.Anchor="Bottom,Left,Right"; $form.Controls.Add($script:LogBox)
    $footer=New-Object System.Windows.Forms.Label; $footer.Text="v$AppVersion  •  НЕОФИЦИАЛЬНЫЙ ПРОЕКТ СООБЩЕСТВА  •  НЕ СВЯЗАН С EXBO"; $footer.ForeColor=[System.Drawing.Color]::FromArgb(75,86,104); $footer.Font=New-Object System.Drawing.Font("Segoe UI",8); $footer.AutoSize=$false; $footer.TextAlign=[System.Drawing.ContentAlignment]::MiddleRight; $footer.Location=New-Object System.Drawing.Point(690,706); $footer.Size=New-Object System.Drawing.Size(450,40); $footer.Anchor="Bottom,Right"; $form.Controls.Add($footer)

    $cpuValue.Text="$($snapshot.Cpu)  ·  $($snapshot.Cores) ядер / $($snapshot.Threads) потоков"
    $gpuValue.Text=if([string]::IsNullOrWhiteSpace($snapshot.GpuDriver)){$snapshot.Gpu}else{"$($snapshot.Gpu)  ·  драйвер $($snapshot.GpuDriver)"}
    $part=if($snapshot.RamParts.Count){"  ·  "+(($snapshot.RamParts|Select-Object -Unique)-join ", ")}else{""}
    $ramValue.Text="$($snapshot.RamGB) ГБ  ·  $($snapshot.RamModules) мод.  ·  $($snapshot.RamSpeed) MT/s$part"
    $pageValue.Text=if($snapshot.PageFileMB -gt 0){"$([math]::Round($snapshot.PageFileMB/1024,1)) ГБ"}else{"НЕ ОБНАРУЖЕН"}

    if($null -ne $snapshot.RatedRamSpeed -and $snapshot.RamSpeed -gt 0 -and $snapshot.RamSpeed -lt ($snapshot.RatedRamSpeed-100)) { $checkRam.Text="⚠  Память работает на $($snapshot.RamSpeed) MT/s, в маркировке модулей найдено $($snapshot.RatedRamSpeed) MT/s. Проверь XMP/EXPO в BIOS."; $checkRam.ForeColor=$t.Yellow } else { $checkRam.Text="✓  Частота памяти не выглядит заниженной по данным модулей."; $checkRam.ForeColor=$t.Green }
    $java=@(Get-JavaEnvironmentIssues)
    if($java.Count){ $checkJava.Text="⚠  Найдены глобальные Java-переменные: $(($java.Name|Select-Object -Unique)-join ', '). Они могут менять JVM-параметры игры."; $checkJava.ForeColor=$t.Yellow } else { $checkJava.Text="✓  Глобальные _JAVA_OPTIONS / JAVA_TOOL_OPTIONS / JDK_JAVA_OPTIONS не заданы."; $checkJava.ForeColor=$t.Green }
    if($snapshot.PageFileMB -le 0){$checkMemory.Text="⚠  Файл подкачки не обнаружен. Для игры и JVM лучше не отключать его полностью.";$checkMemory.ForeColor=$t.Yellow}elseif($snapshot.FreeRamMB -lt 2048){$checkMemory.Text="⚠  Свободной памяти меньше 2 ГБ. Закрой тяжёлые фоновые приложения.";$checkMemory.ForeColor=$t.Yellow}else{$checkMemory.Text="✓  Файл подкачки включён, критической нехватки памяти сейчас нет.";$checkMemory.ForeColor=$t.Green}

    $update={
        $game=@(Get-GameProcesses); $pids=@($game|ForEach-Object{$_.Id})
        if($game.Count){
            $cardGame.Text="ЗАПУЩЕНА"; $cardGame.ForeColor=$t.Green; $gameValue.Text="$($game[0].Name).exe  ·  PID $($game[0].Id)  ·  $($game[0].WorkingSetMB) МБ"
            $drive=Get-GameDriveInfo $game; $driveValue.Text=$drive.Text; $driveValue.ForeColor=if($drive.Warning){$t.Yellow}else{$t.Text}
            if($script:GuardEnabled){
                if(-not $script:GameWasRunning){ if($chkPower.Checked){ if(Set-HighPerformancePowerPlan){Write-Log "Игра обнаружена. Включён производительный план питания."}else{Write-Log "Не удалось переключить план питания."} } else { Write-Log "Игра обнаружена." } }
                $priority=if($cmb.SelectedIndex -eq 0){"Normal"}elseif($cmb.SelectedIndex -eq 2){"High"}else{"AboveNormal"}
                Set-GamePriority $game $priority
                $priorityValue.Text=if($priority -eq "Normal"){"Обычный"}elseif($priority -eq "High"){"Высокий"}else{"Выше обычного"}
                $priorityValue.ForeColor=$t.Green
                $cardGuard.Text="АКТИВЕН"; $cardGuard.ForeColor=$t.Green
            }
            $script:GameWasRunning=$true
        } else {
            $cardGame.Text="НЕ ЗАПУЩЕНА"; $cardGame.ForeColor=$t.Muted; $gameValue.Text="STALZONE / STALCRAFT не обнаружен"; $priorityValue.Text="—"; $priorityValue.ForeColor=$t.Muted; $driveValue.Text="Определится после запуска игры"; $driveValue.ForeColor=$t.Muted
            if($script:GuardEnabled){ $cardGuard.Text="ОЖИДАНИЕ ИГРЫ"; $cardGuard.ForeColor=$t.Yellow; if($script:GameWasRunning){ if(Restore-PowerPlan){Write-Log "Игра закрыта. План питания Windows восстановлен."} } }
            $script:GameWasRunning=$false
        }
        if(-not $script:GuardEnabled){$cardGuard.Text="ВЫКЛЮЧЕН";$cardGuard.ForeColor=$t.Muted}
        $active=Get-ActivePowerScheme; $cardPower.Text=if($active){if([string]::IsNullOrWhiteSpace($active.Name)){$active.Guid.Substring(0,8)}else{$active.Name}}else{"НЕ ОПРЕДЕЛЁН"}
        $load=@(Get-BackgroundLoad $pids); $loadGrid.Rows.Clear()
        foreach($row in $load){$idx=$loadGrid.Rows.Add($row.Name,("{0:N1}%" -f $row.Cpu),("{0} МБ" -f $row.Ram)); if($row.Cpu -ge 15){$loadGrid.Rows[$idx].Cells["Cpu"].Style.ForeColor=$t.Yellow}}
        $loadGrid.ClearSelection()
    }

    $btnGuard.Add_Click({
        $priority=if($cmb.SelectedIndex -eq 0){"Normal"}elseif($cmb.SelectedIndex -eq 2){"High"}else{"AboveNormal"}
        $script:Config=[pscustomobject]@{switchPowerPlan=[bool]$chkPower.Checked;priority=$priority}; Save-Config $script:Config
        if(-not $script:GuardEnabled){$script:GuardEnabled=$true;Save-State;$btnGuard.Text="ОТКЛЮЧИТЬ STUTTER GUARD";Write-Log "Stutter Guard включён. Ожидаю запуск игры."}else{$script:GuardEnabled=$false;[void](Restore-PowerPlan);Clear-State;$btnGuard.Text="ВКЛЮЧИТЬ STUTTER GUARD";Write-Log "Stutter Guard выключен. Настройки Windows восстановлены."}
        & $update
    })
    $btnRestore.Add_Click({$script:GuardEnabled=$false;$btnGuard.Text="ВКЛЮЧИТЬ STUTTER GUARD";if(Restore-PowerPlan){Clear-State;Write-Log "План питания Windows восстановлен."}else{Write-Log "Не удалось восстановить план питания."};& $update})
    $timer=New-Object System.Windows.Forms.Timer; $timer.Interval=1200; $timer.Add_Tick({try{& $update}catch{}})
    $form.Add_Shown({Initialize-NativeDarkMode;Set-NativeDarkTheme $form;if($recovered){Write-Log "Восстановлен план питания после прошлого завершения программы."};Write-Log "Запуск v$AppVersion.";& $update;$timer.Start()})
    $form.Add_FormClosing({$timer.Stop();if($script:GuardEnabled){[void](Restore-PowerPlan)};Clear-State})
    [void]$form.ShowDialog()
}

function Show-ConsoleScan {
    $s=Get-SystemSnapshot; $j=@(Get-JavaEnvironmentIssues); $g=@(Get-GameProcesses); $p=Get-ActivePowerScheme
    [pscustomobject]@{CPU=$s.Cpu;GPU=$s.Gpu;RAM_GB=$s.RamGB;RAM_MT_s=$s.RamSpeed;RAM_Rated_MT_s=$s.RatedRamSpeed;PageFile_MB=$s.PageFileMB;JavaEnvironmentIssues=(($j.Name|Select-Object -Unique)-join ", ");GameProcesses=(($g.Name|Select-Object -Unique)-join ", ");PowerPlan=if($p){$p.Name}else{""}} | Format-List
}

switch($Command){
    "gui" { Start-Gui }
    "scan" { Show-ConsoleScan }
    "restore" { if(Restore-RecoveryState){Write-Host "Настройки Windows восстановлены."}else{Write-Host "Сохранённое состояние не найдено."} }
}
