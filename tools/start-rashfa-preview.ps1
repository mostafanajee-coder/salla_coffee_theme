#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [string]$Store = "",
    [string]$Browser = "chrome"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location -Path $repoRoot
Write-Host "Repository root set to: $repoRoot"

if (-not (Test-Path "twilight.json")) {
    throw "twilight.json not found in the repository root. Ensure you are running this in the theme directory."
}

if (-not (Get-Command salla -ErrorAction SilentlyContinue)) {
    throw "The 'salla' command is not available. Please install the Salla CLI."
}

$hnsOriginalState = (Get-Service -Name "hns" -ErrorAction SilentlyContinue).Status
$winnatOriginalState = (Get-Service -Name "WinNAT" -ErrorAction SilentlyContinue).Status

Write-Host "Original hns state: $hnsOriginalState"
Write-Host "Original WinNAT state: $winnatOriginalState"

function Test-TcpBind {
    param([int]$Port)
    $ip = [System.Net.IPAddress]::Any
    $listener = [System.Net.Sockets.TcpListener]::new($ip, $Port)
    try {
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener -ne $null) {
            $listener.Stop()
        }
    }
}

$primaryError = $null
$cleanupErrors = @()

try {
    Write-Host "Checking for wsl.exe..."
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        Write-Host "Shutting down WSL..."
        & wsl.exe --shutdown
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: wsl.exe --shutdown exited with code $LASTEXITCODE" -ForegroundColor Yellow
        }
    }

    if ($winnatOriginalState -eq 'Running') {
        Write-Host "Stopping WinNAT service..."
        Stop-Service -Name "WinNAT" -Force
        (Get-Service -Name "WinNAT").WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [timespan]::FromSeconds(30))
    }

    if ($hnsOriginalState -eq 'Running') {
        Write-Host "Stopping hns service..."
        Stop-Service -Name "hns" -Force
        (Get-Service -Name "hns").WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [timespan]::FromSeconds(30))
    }

    Write-Host "Testing port 8000 bind..."
    if (-not (Test-TcpBind -Port 8000)) {
        throw "Failed to bind to port 8000. It may be excluded or in use."
    }
    Write-Host "Port 8000 is available."

    Write-Host "Testing port 8001 bind..."
    if (-not (Test-TcpBind -Port 8001)) {
        throw "Failed to bind to port 8001. It may be excluded or in use."
    }
    Write-Host "Port 8001 is available."

    $previewArguments = @(
        "theme",
        "preview",
        "--with-editor",
        "--browser=$Browser"
    )

    if (-not [string]::IsNullOrWhiteSpace($Store)) {
        $previewArguments += "--store=$Store"
    } else {
        Write-Host "No store was specified. Select a demo store from the currently authenticated Salla Partners account."
    }

    & salla @previewArguments
    $exitCode = $LASTEXITCODE

    Write-Host "Preview exited with code $exitCode."
    if ($exitCode -ne 0) {
        throw "Salla preview exited with non-zero code: $exitCode"
    }
} catch {
    $primaryError = $_
} finally {
    Write-Host "Starting service restoration..."
    
    if ($hnsOriginalState -eq 'Running') {
        try {
            Write-Host "Restoring hns service..."
            Start-Service -Name "hns"
            (Get-Service -Name "hns").WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [timespan]::FromSeconds(30))
        } catch {
            $cleanupErrors += "Failed to restore hns: $_"
        }
    }

    if ($winnatOriginalState -eq 'Running') {
        try {
            Write-Host "Restoring WinNAT service..."
            Start-Service -Name "WinNAT"
            (Get-Service -Name "WinNAT").WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [timespan]::FromSeconds(30))
        } catch {
            $cleanupErrors += "Failed to restore WinNAT: $_"
        }
    }
}

if ($primaryError -and $cleanupErrors.Count -gt 0) {
    $combinedMsg = "Primary Error: $($primaryError.Exception.Message)`nCleanup Errors:`n" + ($cleanupErrors -join "`n")
    throw [System.Exception]::new($combinedMsg, $primaryError.Exception)
} elseif ($primaryError) {
    throw $primaryError
} elseif ($cleanupErrors.Count -gt 0) {
    throw ($cleanupErrors -join "`n")
}

Write-Host "Rashfa preview session completed and Windows services were restored."
