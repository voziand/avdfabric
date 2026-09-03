#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install applications on an AVD golden image using Chocolatey.

.DESCRIPTION
    This script does the following operations:
    1. Set TLS 1.2 (required for all HTTPS endpoints).
    2. Install Chocolatey (works natively in SYSTEM context).
    3. Download an application list from a remote URL.
    4. Install each application from the list.

    Windows Updates, restarts, and AppX cleanup are handled by the
    Image Builder template (Bicep). This script only installs applications.
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$AppsListUrl = 'https://raw.githubusercontent.com/voziand/avdfabric/main/apps.txt'
$LogFile     = 'C:\Windows\Temp\InstallApps.log'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Write-Host $Entry
    Add-Content -Path $LogFile -Value $Entry
}

# ---------------------------------------------------------------------------
# Install Chocolatey
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Install-Chocolatey
}
catch {
    Write-Log "FATAL: Failed to install Chocolatey. $_"
    throw
}

try {
    Write-Log '========== Starting Application Installation =========='

    $AppsFile = Join-Path $env:TEMP 'apps.txt'
    Write-Log 'Downloading application list...'
    Invoke-WebRequest -Uri $AppsListUrl -OutFile $AppsFile -UseBasicParsing

    $Applications = Get-Content $AppsFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }

    Write-Log "Packages to install: $($Applications.Count)"

    foreach ($Package in $Applications) {
        try {
            Write-Log "Installing: $Package"
            $Output = choco install $Package --yes --no-progress --limit-output 2>&1
            $Output | ForEach-Object { Write-Log "  [choco] $_" }

            if ($LASTEXITCODE -eq 0) {
                Write-Log "Installed: $Package"
            }
            elseif ($LASTEXITCODE -eq 1641 -or $LASTEXITCODE -eq 3010) {
                Write-Log "Installed (reboot pending): $Package"
            }
            else {
                Write-Log "WARNING: Exit code [$LASTEXITCODE]: $Package"
            }
        }
        catch {
            Write-Log "ERROR: Failed to install [$Package]: $_"
        }
    }

    Write-Log '========== Application Installation Complete =========='
}
catch {
    Write-Log "FATAL ERROR: $_"
    throw
}
