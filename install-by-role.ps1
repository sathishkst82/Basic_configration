[CmdletBinding()]
param(
    [ValidateSet('WebServer','WebAppServer','AppServer')]
    [string]$Role,

    [ValidateSet('WebServer','WebAppServer','AppServer')]
    [string[]]$Roles,

    [switch]$AllRoles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogRoot = 'C:\xDeployment'
if (-not (Test-Path $LogRoot)) {
    New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
}

# Role configuration (update paths, MSI names, and service names for your environment)
$RoleConfig = @{
    WebServer = @{
        SharePath = '\\share\Web'
        Packages  = @(
            @{ FileName = 'WebCore.msi';     Application = 'WebCore';     ApplicationShortName = 'WebCore';     MSIArguments = 'REBOOT=ReallySuppress'; ServiceName = 'W3SVC' },
            @{ FileName = 'WebTools.msi';    Application = 'WebTools';    ApplicationShortName = 'WebTools';    MSIArguments = 'REBOOT=ReallySuppress'; ServiceName = '' }
        )
    }
    WebAppServer = @{
        SharePath = '\\share\WebApp'
        Packages  = @(
            @{ FileName = 'WebAppRuntime.msi'; Application = 'WebAppRuntime'; ApplicationShortName = 'WebAppRuntime'; MSIArguments = 'REBOOT=ReallySuppress'; ServiceName = 'MyWebAppSvc' },
            @{ FileName = 'WebAppApi.msi';     Application = 'WebAppApi';     ApplicationShortName = 'WebAppApi';     MSIArguments = 'REBOOT=ReallySuppress'; ServiceName = '' }
        )
    }
    AppServer = @{
        SharePath = '\\share\App'
        Packages  = @(
            @{ FileName = 'AppCore.msi';      Application = 'AppCore';      ApplicationShortName = 'AppCore';      MSIArguments = 'REBOOT=ReallySuppress'; ServiceName = 'MyAppSvc' },
            @{ FileName = 'AppWorker.msi';    Application = 'AppWorker';    ApplicationShortName = 'AppWorker';    MSIArguments = 'REBOOT=ReallySuppress'; ServiceName = 'MyWorkerSvc' }
        )
    }
}

function Install-MsiPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MSIPath,

        [Parameter(Mandatory = $true)]
        [string]$Application,

        [Parameter(Mandatory = $true)]
        [string]$ApplicationShortName,

        [string]$MSIArguments,
        [string]$ServicePassword,
        [string]$ServiceName
    )

    try {
        if (Test-Path $MSIPath) {
            $suffix = Get-Date -Format 'yyyyMMddHHmmss'
            $logFile = Join-Path $LogRoot "install-$ApplicationShortName-$suffix.log"

            if ($ServicePassword) {
                $InstallCommand = "/i `"$MSIPath`" $MSIArguments SERVICEPASSWORD=$ServicePassword REBOOT=ReallySuppress /qn /lv `"$logFile`""
            }
            else {
                $InstallCommand = "/i `"$MSIPath`" $MSIArguments REBOOT=ReallySuppress /qn /lv `"$logFile`""
            }

            Write-Host "--- InstallCommand: $InstallCommand"
            $process = Start-Process -Wait -FilePath 'msiexec.exe' -ArgumentList $InstallCommand -PassThru
            $global:LASTEXITCODE = $process.ExitCode

            if ($process.ExitCode -eq 0) {
                Write-Host "--- Installation of $Application completed successfully!" -ForegroundColor 'DarkGreen'
            }
            else {
                Write-Host "--- Installation of $Application FAILED!" -ForegroundColor 'DarkRed'
                Write-Host 'wait 1 minutes'
                Start-Sleep -Seconds 60

                Set-Location $LogRoot

                Write-Host '------------------------------ INSTALL LOGS ------------------------------'
                Get-Content $logFile
                Write-Host '------------------------------ END INSTALL LOGS ------------------------------'

                throw $process.ExitCode
            }

            if ($ServiceName) {
                try {
                    $list = @($($ServiceName).Split(','))

                    foreach ($service in $list) {
                        Write-Host "--- Starting Windows service... Name: $service"
                        Start-Service -Name $service.Trim() -PassThru
                    }
                }
                catch {
                    Write-Host '--- Starting Windows service FAILED...' -ForegroundColor 'DarkRed'
                    throw $LASTEXITCODE
                }
            }
        }
        else {
            Write-Host "--- Installer does not exist at the specified location... $MSIPath" -ForegroundColor 'DarkRed'
            throw 1
        }
    }
    catch [Exception] {
        Write-Host 'INSTALL step Failed!' -ForegroundColor 'DarkRed'
        Write-Host $_.Exception.GetType().FullName, $_.Exception.Message
        throw $LASTEXITCODE
    }
}

# Resolve selected roles
$SelectedRoles = @()
if ($AllRoles.IsPresent) {
    $SelectedRoles = @('WebServer', 'WebAppServer', 'AppServer')
}
if ($Role) {
    $SelectedRoles += $Role
}
if ($Roles) {
    $SelectedRoles += $Roles
}

$SelectedRoles = $SelectedRoles | Select-Object -Unique
if (-not $SelectedRoles -or $SelectedRoles.Count -eq 0) {
    throw 'No roles were selected. Use -Role, -Roles, or -AllRoles.'
}

try {
    foreach ($selectedRole in $SelectedRoles) {
        Write-Host "=== Processing role: $selectedRole ==="
        $roleEntry = $RoleConfig[$selectedRole]
        if (-not $roleEntry) {
            throw "Unknown role: $selectedRole"
        }

        $sharePath = $roleEntry.SharePath
        $packages = $roleEntry.Packages

        foreach ($package in $packages) {
            $msiPath = Join-Path $sharePath $package.FileName

            Install-MsiPackage `
                -MSIPath $msiPath `
                -Application $package.Application `
                -ApplicationShortName $package.ApplicationShortName `
                -MSIArguments $package.MSIArguments `
                -ServiceName $package.ServiceName `
                -ServicePassword $package.ServicePassword
        }
    }

    exit 0
}
catch {
    Write-Host "Role-based installation failed: $($_.Exception.Message)" -ForegroundColor 'DarkRed'
    exit 1
}
