[CmdletBinding()]
param(
    [string[]]$List,
    [string[]]$Whitelist,
    [string]$Serial,
    [string]$Wireless,
    [switch]$Pair,
    [string]$PairTarget,
    [AllowEmptyString()][string]$PairCode = "",
    [AllowEmptyString()][string]$User = "",
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$ListDevices,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$PackagePattern = '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'
$PairRequested = [bool]$Pair -or -not [string]::IsNullOrWhiteSpace($PairTarget) -or -not [string]::IsNullOrWhiteSpace($PairCode)

function Show-Help {
    Write-Host @"
Android Debloat via ADB

Usage:
  .\debloat.bat
  .\debloat.ps1
  .\debloat.ps1 -Serial R58N123456A -List samsung -User 0 -Yes
  .\debloat.ps1 -List google,samsung -Whitelist core-android,samsung-safe -User 0 -DryRun
  .\debloat.ps1 -Wireless 192.168.1.20:5555 -List samsung -User 10 -Yes
  .\debloat.ps1 -Pair -PairTarget 192.168.1.20:37123 -PairCode 123456 -Wireless 192.168.1.20:5555 -List samsung -User 0 -Yes

Options:
  -List <name|path>       Package list file. Repeat or use comma-separated values.
  -Whitelist <name|path>  Whitelist file. Defaults to all whitelist/*.txt.
  -Serial <serial>        ADB device serial to target.
  -Wireless <host:port>   Run adb connect first. Port defaults to 5555 if omitted.
  -Pair                   Run adb pair before adb connect.
  -PairTarget <host:port> Wireless debugging pairing endpoint.
  -PairCode <code>        Wireless debugging pairing code.
  -User <id>              Android user id. Default: 0.
  -DryRun                 Show actions without uninstalling.
  -Yes                    Skip confirmation prompt.
  -ListDevices            Print adb devices and exit.
"@
}

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Split-Values([string[]]$Values) {
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        foreach ($part in ($value -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed.Length -gt 0) {
                $items.Add($trimmed)
            }
        }
    }
    return $items.ToArray()
}

function Resolve-TextFile([string]$Value, [string]$Folder) {
    $candidateNames = @($Value)
    if (-not $Value.EndsWith(".txt", [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidateNames += "$Value.txt"
    }

    foreach ($candidate in $candidateNames) {
        $direct = if ([System.IO.Path]::IsPathRooted($candidate)) { $candidate } else { Join-Path $ScriptDir $candidate }
        if (Test-Path -LiteralPath $direct -PathType Leaf) {
            return (Resolve-Path -LiteralPath $direct).Path
        }

        $folderPath = Join-Path (Join-Path $ScriptDir $Folder) $candidate
        if (Test-Path -LiteralPath $folderPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $folderPath).Path
        }
    }

    Fail "File '$Value' was not found in the repository root or '$Folder' folder."
}

function Get-TextFiles([string]$Folder) {
    $folderPath = Join-Path $ScriptDir $Folder
    if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
        Fail "Folder '$Folder' was not found."
    }

    return @(Get-ChildItem -LiteralPath $folderPath -Filter "*.txt" -File | Sort-Object Name)
}

function Select-PackageLists {
    $files = @(Get-TextFiles "list")
    if ($files.Count -eq 0) {
        Fail "No .txt files were found in the 'list' folder."
    }

    Write-Host "Select debloat list:"
    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $files[$i].Name)
    }

    $selection = Read-Host "Enter number, comma-separated for multiple lists"
    $chosen = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($selection -split ',')) {
        $number = 0
        if (-not [int]::TryParse($part.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $files.Count) {
            Fail "Invalid list selection: '$part'."
        }

        $chosen.Add($files[$number - 1].FullName)
    }

    return $chosen.ToArray()
}

function Resolve-PackageLists([string[]]$Values) {
    $items = @(Split-Values $Values)
    if ($items.Count -eq 0) {
        return Select-PackageLists
    }

    return @($items | ForEach-Object { Resolve-TextFile $_ "list" })
}

function Resolve-WhitelistFiles([string[]]$Values) {
    $items = @(Split-Values $Values)
    if ($items.Count -eq 0) {
        return @((Get-TextFiles "whitelist") | ForEach-Object { $_.FullName })
    }

    return @($items | ForEach-Object { Resolve-TextFile $_ "whitelist" })
}

function Read-PackageFile([string]$Path) {
    $packages = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $Path) {
        $clean = ($line -replace "`0", "").Trim()
        if ($clean.Length -eq 0 -or $clean.StartsWith("#") -or $clean.StartsWith(";")) {
            continue
        }

        $clean = (($clean -split '\s+#|\s+;')[0]).Trim()
        if ($clean -notmatch $PackagePattern) {
            Write-Warning "Skipped invalid line in '$Path': $line"
            continue
        }

        $packages.Add($clean)
    }

    return $packages.ToArray()
}

function Build-PackageMap([string[]]$Paths) {
    $map = @{}
    foreach ($path in $Paths) {
        foreach ($package in Read-PackageFile $path) {
            if (-not $map.ContainsKey($package)) {
                $map[$package] = $path
            }
        }
    }

    return $map
}

function Get-Adb {
    $adb = Get-Command adb -ErrorAction SilentlyContinue
    if (-not $adb) {
        Fail "ADB was not found in PATH. Install Android SDK Platform Tools, then open a new terminal."
    }

    return $adb.Source
}

function Test-Yes([string]$Value) {
    return $Value.Trim() -match '^(y|yes)$'
}

function Join-AdbEndpoint([string]$HostValue, [string]$PortValue, [int]$DefaultPort) {
    if ([string]::IsNullOrWhiteSpace($HostValue)) {
        Fail "Wireless IP address cannot be empty."
    }

    $hostText = $HostValue.Trim()
    if ($hostText -match ':\d+$' -and [string]::IsNullOrWhiteSpace($PortValue)) {
        return $hostText
    }

    $portText = if ([string]::IsNullOrWhiteSpace($PortValue)) { "$DefaultPort" } else { $PortValue.Trim() }
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Fail "ADB port must be an integer between 1 and 65535."
    }

    return "${hostText}:$port"
}

function Select-ConnectionMode {
    if (-not [string]::IsNullOrWhiteSpace($Serial) -or -not [string]::IsNullOrWhiteSpace($Wireless)) {
        return
    }

    Write-Host "Select connection mode:"
    Write-Host "  1. USB"
    Write-Host "  2. Wireless"

    $mode = Read-Host "Enter connection mode number"
    switch ($mode.Trim()) {
        "1" {
            return
        }
        "2" {
            $ipAddress = Read-Host "Enter device IP address"
            $pairAnswer = Read-Host "Pair this device first? [y/N]"
            if (Test-Yes $pairAnswer) {
                $pairPort = Read-Host "Enter pairing port"
                $script:PairRequested = $true
                $script:PairTarget = Join-AdbEndpoint $ipAddress $pairPort 0
                if ([string]::IsNullOrWhiteSpace($script:PairCode)) {
                    $script:PairCode = Read-Host "Enter pairing code"
                }
            }

            $connectPort = Read-Host "Enter connect port (empty = 5555)"
            $script:Wireless = Join-AdbEndpoint $ipAddress $connectPort 5555
            return
        }
        default {
            Fail "Invalid connection mode."
        }
    }
}

function Resolve-UserId([string]$Value, [bool]$PromptWhenMissing) {
    $raw = $Value
    if ($PromptWhenMissing) {
        $raw = Read-Host "Enter Android user id (empty = 0)"
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return 0
    }

    $parsed = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$parsed) -or $parsed -lt 0) {
        Fail "Android user id must be 0 or a greater integer."
    }

    return $parsed
}

function Get-AdbDevices([string]$Adb) {
    $lines = & $Adb devices
    if ($LASTEXITCODE -ne 0) {
        Fail "Failed to run 'adb devices'."
    }

    $devices = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed -like "List of devices*") {
            continue
        }

        $parts = $trimmed -split '\s+'
        if ($parts.Count -ge 2) {
            $devices.Add([pscustomobject]@{ Serial = $parts[0]; State = $parts[1] })
        }
    }

    return $devices.ToArray()
}

function Select-AdbDevice([string]$Adb, [string]$PreferredSerial) {
    $devices = @(Get-AdbDevices $Adb)
    if ($PreferredSerial) {
        $matched = @($devices | Where-Object { $_.Serial -eq $PreferredSerial })
        if ($matched.Count -eq 0) {
            Fail "Device '$PreferredSerial' does not appear in adb devices."
        }
        if ($matched[0].State -ne "device") {
            Fail "Device '$PreferredSerial' is in '$($matched[0].State)' state, not 'device'."
        }
        return $PreferredSerial
    }

    $online = @($devices | Where-Object { $_.State -eq "device" })
    if ($online.Count -eq 0) {
        $known = if ($devices.Count -gt 0) { ($devices | ForEach-Object { "$($_.Serial)=$($_.State)" }) -join ", " } else { "none" }
        Fail "No ready ADB device was found. Detected devices: $known."
    }

    if ($online.Count -eq 1) {
        return $online[0].Serial
    }

    Write-Host "Select ADB device:"
    for ($i = 0; $i -lt $online.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $online[$i].Serial)
    }

    $selection = Read-Host "Enter device number"
    $number = 0
    if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $online.Count) {
        Fail "Invalid device selection."
    }

    return $online[$number - 1].Serial
}

function Normalize-WirelessTarget([string]$Target) {
    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $null
    }

    $trimmed = $Target.Trim()
    if ($trimmed -notmatch ':\d+$') {
        return "${trimmed}:5555"
    }

    return $trimmed
}

function Connect-Wireless([string]$Adb, [string]$Target) {
    $normalized = Normalize-WirelessTarget $Target
    if (-not $normalized) {
        return
    }

    Write-Host "Connecting ADB wireless to $normalized ..."
    $output = & $Adb connect $normalized 2>&1
    if ($LASTEXITCODE -ne 0 -or (($output -join "`n") -match "failed|unable|cannot|refused")) {
        Fail "Failed to run adb connect to $normalized. Output: $($output -join ' ')"
    }
}

function Pair-WirelessDevice([string]$Adb) {
    if (-not $script:PairRequested) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:PairTarget)) {
        $script:PairTarget = Read-Host "Enter wireless debugging pairing IP:port"
    }

    if ([string]::IsNullOrWhiteSpace($script:PairCode)) {
        $script:PairCode = Read-Host "Enter pairing code"
    }

    $target = $script:PairTarget.Trim()
    if ($target -notmatch ':\d+$') {
        Fail "Pair target must include the wireless debugging pairing port."
    }

    Write-Host "Pairing ADB wireless with $target ..."
    $output = & $Adb pair $target $script:PairCode 2>&1
    if ($LASTEXITCODE -ne 0 -or (($output -join "`n") -match "failed|unable|cannot|refused|error")) {
        Fail "Failed to run adb pair with $target. Output: $($output -join ' ')"
    }
}

function Get-InstalledPackages([string]$Adb, [string]$DeviceSerial, [int]$UserId) {
    $lines = & $Adb -s $DeviceSerial shell pm list packages --user $UserId 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "Failed to read installed packages for user $UserId. Output: $($lines -join ' ')"
    }

    $set = @{}
    foreach ($line in $lines) {
        $text = $line.ToString().Trim()
        if ($text.StartsWith("package:")) {
            $set[$text.Substring(8)] = $true
        }
    }

    return $set
}

function Invoke-Debloat([string]$Adb, [string]$DeviceSerial, [int]$UserId, [string]$PackageName, [bool]$Preview) {
    $args = @("-s", $DeviceSerial, "shell", "pm", "uninstall", "-k", "--user", "$UserId", $PackageName)
    if ($Preview) {
        Write-Host ("DRY-RUN adb {0}" -f ($args -join " "))
        return [pscustomobject]@{ Success = $true; Output = "dry-run" }
    }

    $output = & $Adb @args 2>&1
    $text = ($output -join " ").Trim()
    return [pscustomobject]@{ Success = ($LASTEXITCODE -eq 0 -and $text -match "Success"); Output = $text }
}

if ($Help) {
    Show-Help
    exit 0
}

$adbPath = Get-Adb

if ($ListDevices) {
    & $adbPath devices
    exit $LASTEXITCODE
}

Select-ConnectionMode
$listFiles = @(Resolve-PackageLists $List)
$whitelistFiles = @(Resolve-WhitelistFiles $Whitelist)
$userId = Resolve-UserId $User (-not $PSBoundParameters.ContainsKey("User"))
$targetPackages = Build-PackageMap $listFiles
$protectedPackages = Build-PackageMap $whitelistFiles

if ($targetPackages.Count -eq 0) {
    Fail "Debloat list is empty after parsing."
}

$blocked = New-Object System.Collections.Generic.List[string]
$candidates = New-Object System.Collections.Generic.List[string]

foreach ($package in ($targetPackages.Keys | Sort-Object)) {
    if ($protectedPackages.ContainsKey($package)) {
        $blocked.Add($package)
    } else {
        $candidates.Add($package)
    }
}

Write-Host "Debloat lists: $($listFiles.Count) file(s), $($targetPackages.Count) unique package(s)."
Write-Host "Whitelist: $($whitelistFiles.Count) file(s), $($protectedPackages.Count) unique package(s)."
Write-Host "Will process: $($candidates.Count). Skipped by whitelist: $($blocked.Count)."

if ($candidates.Count -eq 0) {
    Write-Host "No packages to process."
    exit 0
}

if (-not $DryRun -and -not $Yes) {
    $answer = Read-Host "Type DEBLOAT to uninstall packages for user $userId"
    if ($answer -ne "DEBLOAT") {
        Write-Host "Canceled."
        exit 0
    }
}

& $adbPath start-server | Out-Null
Pair-WirelessDevice $adbPath
Connect-Wireless $adbPath $Wireless
$device = Select-AdbDevice $adbPath $Serial
$installed = Get-InstalledPackages $adbPath $device $userId

$success = 0
$failed = 0
$notInstalled = 0

foreach ($package in $candidates) {
    if (-not $installed.ContainsKey($package)) {
        $notInstalled++
        Write-Host "SKIP not-installed $package"
        continue
    }

    $result = Invoke-Debloat $adbPath $device $userId $package ([bool]$DryRun)
    if ($result.Success) {
        $success++
        Write-Host "OK $package"
    } else {
        $failed++
        Write-Host "FAIL $package :: $($result.Output)"
    }
}

Write-Host ""
Write-Host "Done."
Write-Host "  Device: $device"
Write-Host "  User: $userId"
Write-Host "  Success: $success"
Write-Host "  Failed: $failed"
Write-Host "  Not installed: $notInstalled"
Write-Host "  Skipped by whitelist: $($blocked.Count)"

if ($failed -gt 0) {
    exit 2
}
