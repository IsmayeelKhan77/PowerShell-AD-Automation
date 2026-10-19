<#
.SYNOPSIS
    Reusable logging module for the AD Automation project.

.DESCRIPTION
    Import this in every script with:
        Import-Module "$PSScriptRoot\Logging-Module.psm1" -Force

    Then call:
        Write-Log -Message "Created user jdoe" -Level "INFO" -LogFile $LogFile

    Every log line is timestamped and leveled, and also echoed to the
    console with color-coding so you can watch scripts run live —
    useful for screenshots too.
#>

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",

        [Parameter(Mandatory = $true)]
        [string]$LogFile
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    # Ensure the log folder exists
    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Write to file
    Add-Content -Path $LogFile -Value $line

    # Echo to console with color
    switch ($Level) {
        "INFO"    { Write-Host $line -ForegroundColor Cyan }
        "WARNING" { Write-Host $line -ForegroundColor Yellow }
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
    }
}

function New-LogFile {
    <#
        Generates a fresh, timestamped log file path for a given script name.
        Example: New-LogFile -ScriptName "Onboarding" -LogFolder $Global:LogFolder
        -> C:\...\Logs\Onboarding_2026-09-26_143012.log
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [Parameter(Mandatory = $true)]
        [string]$LogFolder
    )

    if (-not (Test-Path $LogFolder)) {
        New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    return Join-Path $LogFolder "$ScriptName`_$stamp.log"
}

Export-ModuleMember -Function Write-Log, New-LogFile
