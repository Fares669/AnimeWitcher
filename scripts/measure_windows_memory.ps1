#requires -Version 5.1
<#
.SYNOPSIS
  Samples the exact Windows AnimeWitcher process launched by this run.
.DESCRIPTION
  Run in an interactive console. Hit Enter only at the requested transition.
  No process is killed, no setting is modified, and no capture leaves this PC.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppExe,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateSet('A', 'B')][string]$Variant,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$Revision,
    [Parameter(Mandatory)][ValidateSet('standard', 'high')][string]$ArtworkQuality,
    [Parameter(Mandatory)][ValidateSet('profile', 'release')][string]$BuildMode,
    [ValidateRange(5, 600)][int]$IdleSeconds = 60,
    [ValidateRange(3, 60)][int]$SettleSeconds = 10,
    [ValidateRange(1, 20)][int]$LoopCount = 3,
    [ValidateRange(100, 1000)][int]$SampleMillis = 500,
    [ValidateRange(10, 600)][int]$ActionTimeoutSeconds = 120
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This collector is Windows-only. Other hosts must not report these counters as Windows measurements.'
}
if ([Console]::IsInputRedirected -or $Host.Name -ne 'ConsoleHost') {
    throw 'Run this script in an interactive PowerShell console.'
}
$exe = Get-Item -LiteralPath $AppExe
if ($exe -isnot [IO.FileInfo] -or $exe.Name -ne 'animewitcher.exe') {
    throw 'Pass the path to animewitcher.exe in the complete build directory.'
}
if (Get-Process -Name 'animewitcher' -ErrorAction SilentlyContinue) {
    throw 'Close existing AnimeWitcher instances yourself before starting a capture.'
}
$aot = Get-Item -LiteralPath (Join-Path $exe.DirectoryName 'data/app.so')
if ($aot -isnot [IO.FileInfo]) { throw 'The profile/release AOT bundle is missing data/app.so.' }
$outDir = New-Item -ItemType Directory -Path $OutputDirectory
$culture = [Globalization.CultureInfo]::InvariantCulture
$metadata = [ordered]@{
    schema = 1
    hostOs = 'Windows'
    osVersion = [Environment]::OSVersion.VersionString
    logicalProcessors = [Environment]::ProcessorCount
    variant = $Variant
    revision = $Revision.ToLowerInvariant()
    artworkQuality = $ArtworkQuality
    buildMode = $BuildMode
    executableSha256 = (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    aotSha256 = (Get-FileHash -LiteralPath $aot.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    executableFileVersion = $exe.VersionInfo.FileVersion
    idleSeconds = $IdleSeconds
    settleSeconds = $SettleSeconds
    loopCount = $LoopCount
    sampleMillis = $SampleMillis
    actionTimeoutSeconds = $ActionTimeoutSeconds
    startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    processId = $null
    complete = $false
}
$clock = [Diagnostics.Stopwatch]::new()
$runState = @{
    events = [Collections.Generic.List[object]]::new()
    sampleCount = 0
}
$log = $null
$app = $null

function Write-Sample([string]$Phase, [double]$PhaseStart) {
    $app.Refresh()
    if ($app.HasExited) { throw 'The launched app exited early. This run is incomplete.' }
    $now = $clock.Elapsed.TotalSeconds
    $line = [string]::Format($culture, '{0:F6},{1},{2:F6},{3},{4},{5},{6},{7}',
        [object[]]@($now, $Phase, ($now - $PhaseStart), $app.Id,
        $app.WorkingSet64, $app.PrivateMemorySize64,
        $app.TotalProcessorTime.Ticks, [DateTimeOffset]::UtcNow.ToString('o')))
    $log.WriteLine($line)
    $runState.sampleCount += 1
}

function Read-ConsoleEnter {
    $confirmed = $false
    while ([Console]::KeyAvailable) {
        if ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Enter) {
            $confirmed = $true
        }
    }
    return $confirmed
}

function Measure-Phase([string]$Name, [double]$Duration, [string]$Prompt = '') {
    $interactive = $Prompt.Length -gt 0
    $start = $clock.Elapsed.TotalSeconds
    $event = [ordered]@{ phase = $Name; startSeconds = $start }
    $runState.events.Add($event)
    if ($interactive) {
        [void](Read-ConsoleEnter)
        Write-Host $Prompt
    }
    # Obtain a sample at the start and end of each phase, even for quick transitions.
    # CPU at a phase is thus a delta of actual timestamped counters, not a poll average.
    Write-Sample $Name $start
    $nextSample = $clock.Elapsed.TotalSeconds + $SampleMillis / 1000.0
    while ($true) {
        $now = $clock.Elapsed.TotalSeconds
        if ($interactive -and (Read-ConsoleEnter)) { break }
        if ($now - $start -ge $Duration) {
            if ($interactive) { throw "Timed out waiting for Enter in ${Name}." }
            break
        }
        if ($now -ge $nextSample) {
            Write-Sample $Name $start
            $nextSample = $now + $SampleMillis / 1000.0
        }
        Start-Sleep -Milliseconds 20
    }
    Write-Sample $Name $start
    $event['endSeconds'] = $clock.Elapsed.TotalSeconds
}

try {
    $log = [IO.StreamWriter]::new((Join-Path $outDir.FullName 'samples.csv'), $false)
    $log.AutoFlush = $true
    $log.WriteLine('elapsed_seconds,phase,phase_seconds,pid,working_set_bytes,private_bytes,cpu_ticks,timestamp_utc')
    Write-Host 'Opening AnimeWitcher. Keep the console visible beside the app.'
    $clock.Start()
    $app = Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
    $metadata.processId = $app.Id
    Measure-Phase 'startup' $ActionTimeoutSeconds 'When Home is usable, focus this console and press Enter.'
    Write-Host "Home idle: leave the app untouched for $IdleSeconds seconds."
    Measure-Phase 'home_idle' $IdleSeconds
    for ($i = 1; $i -le $LoopCount; $i++) {
        $prompt = "Loop ${i}: open the predetermined title, wait for Details to load, return to Home, then press Enter."
        Measure-Phase "details_${i}_active" $ActionTimeoutSeconds $prompt
        Write-Host "Leave Home untouched for $SettleSeconds seconds."
        Measure-Phase "details_${i}_settle" $SettleSeconds
    }
    $metadata.complete = $true
    Write-Host 'Capture complete. You can close the app now.'
} finally {
    if ($null -ne $log) { $log.Dispose() }
    if ($null -ne $app) { $app.Dispose() }
    $metadata['events'] = $runState.events.ToArray()
    $metadata['sampleCount'] = $runState.sampleCount
    $json = $metadata | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $outDir.FullName 'run.json'), $json)
}
