<#
.SYNOPSIS
Install multiple MSI packages from one folder in a strict, predefined order.

.DESCRIPTION
Pass -ApplicationOrder as an ordered list of MSI file patterns.
The script will take each pattern in sequence, find matching files in -MSIPath,
install them, and stop immediately on any failure.

.EXAMPLE
.\install-multiple-msi.ps1   -MSIPath "C:\xDeployment\MSI"   -ApplicationOrder @("jabe*.msi","instller*.msi",".net*.msi")   -WebPoolDomain "CONTOSO"   -WebPoolUser "svc-web"   -WebPoolPassword "P@ssw0rd!"   -ServicePassword "SvcP@ssw0rd!"

.EXAMPLE
# Run without ServicePassword
.\install-multiple-msi.ps1   -MSIPath "C:\xDeployment\MSI"   -ApplicationOrder @("appserv-core*.msi","appserv-feature*.msi","appserv-config*.msi")   -WebPoolDomain "CONTOSO"   -WebPoolUser "svc-web"   -WebPoolPassword "P@ssw0rd!"

.NOTES
- Must run in elevated PowerShell session.
- Designed for non-interactive automation (Ansible).
- Log per package: C:\xDeployment\install-<ApplicationShortName>-<timestamp>.log
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MSIPath,

    [Parameter(Mandatory = $true)]
    [string[]]$ApplicationOrder = @(),

    [Parameter(Mandatory = $false)]
    [string]$WebPoolDomain,

    [Parameter(Mandatory = $false)]
    [string]$WebPoolUser,

    [Parameter(Mandatory = $false)]
    [string]$WebPoolPassword,

    [Parameter(Mandatory = $false)]
    [string]$ServicePassword
)

$ErrorActionPreference = 'Stop'

Write-Host "-------------------------------------- STEP INSTALL --------------------------------------"

$suffix = Get-Date -Format 'yyyyMMdd-HHmmss'
$MSIArguments = "ADDDEFAULT=WebServicesFeature,WebSvcVirtualDirectoryFeature,WebSvcFirstTimeInstallationFeature WEBSVC_APP_POOL_DOMAIN=$WebPoolDomain WEBSVC_APP_POOL_USERNAME=$WebPoolUser WEBSVC_APP_POOL_PASSWORD=$WebPoolPassword"

if (-not (Test-Path -Path $MSIPath -PathType Container)) {
    throw "MSIPath directory does not exist: $MSIPath"
}

if (-not $ApplicationOrder -or $ApplicationOrder.Count -eq 0) {
    throw 'ApplicationOrder is required. Provide ordered MSI patterns such as @("jabe*.msi","instller*.msi",".net*.msi").'
}

$orderedMsiFiles = @()
$alreadySelected = @{}

foreach ($appPattern in $ApplicationOrder) {
    $patternMatches = Get-ChildItem -Path $MSIPath -Filter $appPattern -File | Sort-Object -Property Name

    if (-not $patternMatches -or $patternMatches.Count -eq 0) {
        throw "No MSI file found in '$MSIPath' for ordered pattern '$appPattern'."
    }

    foreach ($msi in $patternMatches) {
        if (-not $alreadySelected.ContainsKey($msi.FullName)) {
            $orderedMsiFiles += $msi
            $alreadySelected[$msi.FullName] = $true
        }
    }
}

foreach ($msi in $orderedMsiFiles) {
    $currentMsiPath = $msi.FullName
    $ApplicationShortName = [System.IO.Path]::GetFileNameWithoutExtension($msi.Name)
    $Application = $ApplicationShortName

    Write-Host "--- Installing $ApplicationShortName from $currentMsiPath"

    if (Test-Path $currentMsiPath) {
        if ($ServicePassword) {
            $InstallCommand = "/i `"$currentMsiPath`" $MSIArguments SERVICE_PASSWORD=$ServicePassword REBOOT=ReallySuppress /qn /lv c:\xDeployment\install-$ApplicationShortName-$suffix.log"
            Write-Host "--- InstallCommand: $InstallCommand"
        }
        else {
            $InstallCommand = "/i `"$currentMsiPath`" $MSIArguments REBOOT=ReallySuppress /qn /lv c:\xDeployment\install-$ApplicationShortName-$suffix.log"
            Write-Host "--- InstallCommand: $InstallCommand"
        }

        Start-Process -Wait -FilePath 'msiexec.exe' -ArgumentList $InstallCommand
    }

    # Check if install completed successfully
    $RegistryApplication = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.DisplayName -match "$Application" }

    if (-not $RegistryApplication) {
        Write-Host '--- Getting registry from Wow6432Node...'
        $RegistryApplication = Get-ChildItem 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall' |
            ForEach-Object { Get-ItemProperty $_.PSPath } |
            Where-Object { $_.DisplayName -match "$Application" }
    }

    if ($RegistryApplication -and ($RegistryApplication.DisplayName -match "$Application")) {
        Write-Host "--- Installation of $Application completed successfully!" -ForegroundColor 'DarkGreen'
    }
    else {
        Write-Host "--- Installation of $Application FAILED!" -ForegroundColor 'DarkRed'
        Write-Host 'wait 1 minutes'
        Start-Sleep -Seconds 60

        Set-Location 'c:\xDeployment'

        Write-Host '# Visibly separate logs from error'
        Write-Host '------------------------------ INSTALL LOGS ------------------------------'

        Get-Content "install-$ApplicationShortName-$suffix.log"

        Write-Host '------------------------------ END INSTALL LOGS ------------------------------'
        Write-Host '# Visibly separate logs from error'

        throw $LASTEXITCODE
    }
}

Write-Host '--- All MSI packages installed successfully.' -ForegroundColor 'DarkGreen'
