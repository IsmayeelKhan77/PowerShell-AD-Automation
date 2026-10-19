<#
.SYNOPSIS
    Shared helper functions used by every automation script (Checkpoint 5).

.DESCRIPTION
    Before this checkpoint, New-RandomPassword was copy-pasted into two scripts.
    Duplicated code is a maintenance risk: fix a bug in one copy and the other
    copy keeps the bug. Now every script imports this ONE module instead.

    Import it with:
        Import-Module "$PSScriptRoot\Shared-Functions.psm1" -Force
#>

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module "$PSScriptRoot\Logging-Module.psm1"

# --- Random password that always meets complexity rules ------------------------
function New-RandomPassword {
    param(
        [ValidateRange(8, 64)]
        [int]$Length = 14
    )
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%&*?'
    )
    $all   = -join $sets
    $chars = foreach ($s in $sets) { $s[(Get-Random -Maximum $s.Length)] }
    $chars += 1..($Length - $sets.Count) | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    return -join ($chars | Get-Random -Count $chars.Count)
}

# --- DN helpers ------------------------------------------------------------------
# "CN=Aarav Mehta,OU=IT,DC=Project,DC=local"  ->  "OU=IT,DC=Project,DC=local"
# (handles names with an escaped comma, like "CN=Smith\, John,OU=IT,...")
function Get-ParentDn {
    param([string]$Dn)
    return [regex]::Replace($Dn, '^(?:[^,\\]|\\.)+,', '')
}

# "OU=IT,DC=Project,DC=local"  ->  "IT"
function Get-OuName {
    param([string]$Dn)
    if ($Dn -match '^OU=((?:[^,\\]|\\.)+),') { return $Matches[1] }
    return $Dn
}

# --- Validation helpers ----------------------------------------------------------
# Letters (any language), spaces, apostrophes, dots and hyphens only. No digits.
function Test-PersonName {
    param([string]$Name)
    return [bool]($Name -match '^[\p{L}][\p{L} ''\.\-]*$')
}

function Test-OuExists {
    param([string]$Dn)
    try {
        [void](Get-ADOrganizationalUnit -Identity $Dn -ErrorAction Stop)
        return $true
    }
    catch { return $false }
}

# Reads a CSV and checks it before any script touches AD.
# Returns an object: Ok (true/false), Rows, Message
function Test-CsvInput {
    param(
        [string]$Path,
        [string[]]$RequiredColumns
    )
    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{ Ok = $false; Rows = @(); Message = "CSV file not found: $Path" }
    }
    try { $rows = @(Import-Csv -Path $Path -ErrorAction Stop) }
    catch {
        return [pscustomobject]@{ Ok = $false; Rows = @(); Message = "Could not read CSV: $($_.Exception.Message)" }
    }
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Rows = @(); Message = "CSV has a header but no data rows: $Path" }
    }
    $columns = $rows[0].PSObject.Properties.Name
    $missing = @($RequiredColumns | Where-Object { $columns -notcontains $_ })
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Rows = @(); Message = "CSV is missing required column(s): $($missing -join ', ')" }
    }
    return [pscustomobject]@{ Ok = $true; Rows = $rows; Message = "OK" }
}

# Checks that a department's OU and groups from Config.ps1 really exist in AD.
# Returns a list of problems (empty list = all good).
function Test-DepartmentConfig {
    param(
        [string]$Department,
        [hashtable]$DepartmentMap
    )
    $problems = @()
    $map = $DepartmentMap[$Department]
    if (-not (Test-OuExists -Dn $map.OU)) { $problems += "OU not found: $($map.OU)" }
    foreach ($g in $map.SecurityGroups) {
        if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
            $problems += "Group not found: $g"
        }
    }
    return $problems
}

# --- Error handling helper -----------------------------------------------------
# Turns scary .NET exception names into one readable sentence for the log/report.
function Get-FriendlyAdError {
    param($ErrorRecord)
    $ex   = $ErrorRecord.Exception
    $type = $ex.GetType().Name
    switch ($type) {
        'ADIdentityAlreadyExistsException' { return "An object with this name/username already exists in AD." }
        'ADPasswordComplexityException'    { return "Password was rejected by the domain password policy." }
        'UnauthorizedAccessException'      { return "Access denied. Run PowerShell as an account allowed to manage these users." }
        'ADServerDownException'            { return "Cannot reach a domain controller." }
        'ADIdentityNotFoundException'      { return "Object not found in AD." }
        default                            { return "$($ex.Message)" }
    }
}

# --- Audit trail helper --------------------------------------------------------
# First log line of every run: WHO ran the script, WHERE, and in what mode.
function Write-RunHeader {
    param(
        [string]$ScriptName,
        [string]$LogFile,
        [switch]$DryRun
    )
    $mode = if ($DryRun) { "DRY RUN (-WhatIf, nothing will change)" } else { "LIVE" }
    Write-Log -Message "$ScriptName run by $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME | PowerShell $($PSVersionTable.PSVersion) | Mode: $mode" -Level "INFO" -LogFile $LogFile
}

Export-ModuleMember -Function New-RandomPassword, Get-ParentDn, Get-OuName, Test-PersonName, Test-OuExists, Test-CsvInput, Test-DepartmentConfig, Get-FriendlyAdError, Write-RunHeader
