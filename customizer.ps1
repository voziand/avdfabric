#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$appsUrl = 'https://raw.githubusercontent.com/voziand/avdfabric/main/apps.json'
$optimizationsUrl = 'https://raw.githubusercontent.com/voziand/avdfabric//main/optimizations.pooled.json'
$LogFile = 'C:\Windows\Temp\InstallApps.log'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Log {
    param([string]$Message)
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Write-Host $Entry
    Add-Content -Path $LogFile -Value $Entry
}

function Install-Chocolatey {
    Write-Log 'Checking for Chocolatey...'
    $ChocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($ChocoCmd) {
        Write-Log "Chocolatey already installed at: $($ChocoCmd.Source)"
        return
    }
    Write-Log 'Installing Chocolatey...'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $ChocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue
    if (-not $ChocoCmd) {
        throw 'Chocolatey installation completed but choco.exe was not found.'
    }
    choco feature enable -n allowGlobalConfirmation
    Write-Log "Chocolatey installed at: $($ChocoCmd.Source)"
}

try {
    Install-Chocolatey
}
catch {
    Write-Log "FATAL: Failed to install Chocolatey. $_"
    throw
}
# APPLICATIONS INSTALLATION
try {
    Write-Log '========== Starting Application Installation =========='
    $ManifestFile = Join-Path $env:TEMP 'apps.json'
    Write-Log 'Downloading application manifest...'
    Invoke-WebRequest -Uri $appsUrl -OutFile $ManifestFile -UseBasicParsing
    $Manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json
    Write-Log "Packages to install: $($Manifest.packages.Count)"

    foreach ($App in $Manifest.packages) {
        try {
            Write-Log "Installing: $($App.name) (source: $($App.source))"

            switch ($App.source) {
                'chocolatey' { choco install $app.name --no-progress $app.switche }
                'custom' {
                    $extension = [System.IO.Path]::GetExtension($App.installerUrl)
                    $installerPath = Join-Path $env:TEMP "$($App.name)-installer$extension"
                    Invoke-WebRequest -Uri $App.installerUrl -OutFile $installerPath -UseBasicParsing
                    if ($extension -eq '.msi') {
                        Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$installerPath`" $($App.switches)" -Wait
                    }
                    else {
                        Start-Process -FilePath $installerPath -ArgumentList $App.switches -Wait
                    }
                }
                default {
                    Write-Log "ERROR: Unknown source '$($App.source)' for $($App.name)."
                    continue
                }
            }

            if ($LASTEXITCODE -eq 0) {
                Write-Log "Installed: $($App.name)"
            }
            elseif ($LASTEXITCODE -eq 1641 -or $LASTEXITCODE -eq 3010) {
                Write-Log "Installed (reboot pending): $($App.name)"
            }
            else {
                Write-Log "WARNING: Exit code [$LASTEXITCODE]: $($App.name)"
            }
        }
        catch {
            Write-Log "ERROR: Failed to install [$($App.name)]: $_"
        }
    }
    Write-Log '========== Application Installation Complete =========='
}
catch {
    Write-Log "FATAL ERROR: $_"
    throw
}
# IMAGE OPTIMIZATIONS
 
try {
    Write-Log '========== Starting Image Optimizations =========='
    $OptFile = Join-Path $env:TEMP 'optimizations.json'
    Write-Log 'Downloading optimization configuration...'
    Invoke-WebRequest -Uri $optimizationsUrl -OutFile $OptFile -UseBasicParsing
    $Opt = Get-Content $OptFile -Raw | ConvertFrom-Json
 
    Write-Log "Disabling $($Opt.services.Count) services..."
    foreach ($Svc in $Opt.services) {
        try {
            $existing = Get-Service -Name $Svc.name -ErrorAction SilentlyContinue
            if ($existing) {
                Set-Service -Name $Svc.name -StartupType Disabled -ErrorAction Stop
                Write-Log "  Disabled: $($Svc.name) ($($Svc.description))"
            }
        }
        catch {
            Write-Log "  WARNING: Could not disable $($Svc.name): $_"
        }
    }
 
    Write-Log "Disabling $($Opt.scheduledTasks.Count) scheduled tasks..."
    foreach ($Task in $Opt.scheduledTasks) {
        try {
            $taskObj = Get-ScheduledTask -TaskPath $Task.path -TaskName $Task.name -ErrorAction SilentlyContinue
            if ($taskObj -and $taskObj.State -ne 'Disabled') {
                Disable-ScheduledTask -InputObject $taskObj | Out-Null
                Write-Log "  Disabled: $($Task.path)\$($Task.name)"
            }
        }
        catch {
            Write-Log "  WARNING: Could not disable task $($Task.name): $_"
        }
    }
 # DEBLOAT
    Write-Log "Removing $($Opt.appxPackages.Count) AppX packages..."
    foreach ($Pkg in $Opt.appxPackages) {
        try {
            Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like "*$Pkg*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            Get-AppxPackage -AllUsers -Name "*$Pkg*" -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Write-Log "  Removed: $Pkg"
        }
        catch {
            Write-Log "  WARNING: Could not remove $Pkg`: $_"
        }
    }
 
    Write-Log "Applying $($Opt.registrySettings.Count) registry settings..."
    foreach ($Reg in $Opt.registrySettings) {
        try {
            if (-not (Test-Path $Reg.path)) {
                New-Item -Path $Reg.path -Force | Out-Null
            }
            New-ItemProperty -Path $Reg.path -Name $Reg.name -PropertyType $Reg.type -Value $Reg.value -Force | Out-Null
            Write-Log "  Set: $($Reg.path)\$($Reg.name) = $($Reg.value)"
        }
        catch {
            Write-Log "  WARNING: Could not set $($Reg.path)\$($Reg.name): $_"
        }
    }
 
    Write-Log "Disabling $($Opt.autologgers.Count) autologgers..."
    foreach ($Logger in $Opt.autologgers) {
        try {
            if (Test-Path $Logger) {
                New-ItemProperty -Path $Logger -Name 'Start' -PropertyType DWORD -Value 0 -Force | Out-Null
                Write-Log "  Disabled: $Logger"
            }
        }
        catch {
            Write-Log "  WARNING: Could not disable autologger $Logger`: $_"
        }
    }
 
    if ($Opt.diskCleanup -eq $true) {
        Write-Log 'Running disk cleanup...'
        Get-ChildItem -Path C:\ -Include *.tmp, *.dmp, *.etl, *.evtx, thumbcache*.db, *.log -File -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
        Remove-Item -Path $env:windir\Temp\* -Recurse -Force -ErrorAction SilentlyContinue -Exclude packer*.ps1
        Remove-Item -Path $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue -Exclude packer*.ps1
        Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportArchive\* -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportQueue\* -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $env:ProgramData\Microsoft\Windows\RetailDemo\* -Recurse -Force -ErrorAction SilentlyContinue
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Clear-BCCache -Force -ErrorAction SilentlyContinue
        Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet
        Write-Log 'Disk cleanup complete.'
    }
 
    Write-Log '========== Image Optimizations Complete =========='
}
catch {
    Write-Log "FATAL ERROR during optimizations: $_"
    throw
}
