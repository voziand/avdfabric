#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ManifestUrl = 'https://raw.githubusercontent.com/voziand/avdfabric/main/apps.json'
$LogFile     = 'C:\Windows\Temp\InstallApps.log'
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

try {
    Write-Log '========== Starting Application Installation =========='
    $ManifestFile = Join-Path $env:TEMP 'apps.json'
    Write-Log 'Downloading application manifest...'
    Invoke-WebRequest -Uri $ManifestUrl -OutFile $ManifestFile -UseBasicParsing
    $Manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json
    Write-Log "Packages to install: $($Manifest.packages.Count)"

    foreach ($App in $Manifest.packages) {
        try {
            Write-Log "Installing: $($App.name) (source: $($App.source))"

            switch ($App.source) {
                'chocolatey' {
                    choco install $app.name --no-progress $app.switches
                }
                'custom' {
                    $extension = [System.IO.Path]::GetExtension($App.installerUrl)
                    $installerPath = Join-Path $env:TEMP "$($App.name)-installer$extension"
                    Invoke-WebRequest -Uri $App.installerUrl -OutFile $installerPath -UseBasicParsing
                    if ($extension -eq '.msi') {
                        Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$installerPath`" $($App.switches)" -Wait
                    } else {
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
