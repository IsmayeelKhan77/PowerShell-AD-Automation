<#
.SYNOPSIS
    JOINER automation (v2): creates new Active Directory users in bulk from a CSV file.

.DESCRIPTION
    Checkpoint 5 version: same job as before, but it now defends itself against
    messy data. Before touching AD it checks:
      - the CSV exists, is readable, and has the required columns
      - every row has all fields filled in
      - names contain only letters, spaces, apostrophes, dots and hyphens
      - the department exists in Config.ps1 (any capitalisation is accepted)
      - the department's OU and groups really exist in AD
      - the row is not a duplicate of an earlier row
      - the username is free (if "amehta" belongs to a DIFFERENT person, the new
        hire gets "amehta2"; if it is the SAME person, the row is skipped)
    A bad row is skipped and explained in the report. It never stops the other rows.

.EXAMPLE
    .\New-BulkUsers.ps1 -WhatIf                       # DRY RUN
    .\New-BulkUsers.ps1                               # REAL RUN
    .\New-BulkUsers.ps1 -CsvPath ..\CSV\NewHires_Messy.csv -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CsvPath
)

Import-Module "$PSScriptRoot\Logging-Module.psm1" -Force
Import-Module "$PSScriptRoot\Shared-Functions.psm1" -Force
. "$PSScriptRoot\Config.ps1"
Import-Module ActiveDirectory -ErrorAction Stop

if (-not $CsvPath) { $CsvPath = Join-Path $Global:CsvFolder "NewHires.csv" }

$LogFile = New-LogFile -ScriptName "Onboarding" -LogFolder $Global:LogFolder
$stamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
Write-RunHeader -ScriptName "Onboarding" -LogFile $LogFile -DryRun:$WhatIfPreference

# --- Helpers specific to this script -------------------------------------------
# First initial + last name, lowercase, letters/digits only, max 18 characters
# (AD allows 20, we keep 2 spare for a number if the name is taken)
function New-UserName {
    param([string]$First, [string]$Last)
    $name = ($First.Substring(0, 1) + $Last).ToLower() -replace '[^a-z0-9]', ''
    if ($name.Length -gt 18) { $name = $name.Substring(0, 18) }
    return $name
}

# Finds a username for this person. Returns State = Free / Exists / None
function Resolve-UserName {
    param([string]$Base, [string]$FullName, [hashtable]$UsedThisRun)
    for ($n = 1; $n -le 99; $n++) {
        $candidate = if ($n -eq 1) { $Base } else { "$Base$n" }
        $existing  = Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.Name -eq $FullName) { return [pscustomobject]@{ Username = $candidate; State = "Exists" } }
            continue    # taken by a different person, try the next number
        }
        if ($UsedThisRun.ContainsKey($candidate)) { continue }
        return [pscustomobject]@{ Username = $candidate; State = "Free" }
    }
    return [pscustomobject]@{ Username = $null; State = "None" }
}

function New-Row {
    param($Username = "", $FullName = "", $Dept = "", $Title = "", $Groups = "", $Status, $Note = "")
    [pscustomobject]@{ Username = $Username; FullName = $FullName; Department = $Dept; JobTitle = $Title; Groups = $Groups; Status = $Status; Note = $Note }
}

$deptProblems = @{}
function Get-DeptProblems {
    param([string]$Dept)
    if (-not $deptProblems.ContainsKey($Dept)) {
        $deptProblems[$Dept] = @(Test-DepartmentConfig -Department $Dept -DepartmentMap $Global:DepartmentMap)
    }
    return $deptProblems[$Dept]
}

# --- PRE-FLIGHT: check the CSV before doing anything ---------------------------
$csv = Test-CsvInput -Path $CsvPath -RequiredColumns @("FirstName", "LastName", "Department", "JobTitle")
if (-not $csv.Ok) {
    Write-Log -Message $csv.Message -Level "ERROR" -LogFile $LogFile
    exit 1
}
$hires = $csv.Rows
Write-Log -Message "===== Onboarding started. $($hires.Count) data row(s) in $CsvPath =====" -Level "INFO" -LogFile $LogFile

$report      = @()   # safe to share: no passwords
$handoff     = @()   # contains temp passwords: NEVER commit to GitHub
$usedThisRun = @{}   # usernames handed out in this run
$seenRows    = @{}   # to catch duplicate rows
$i           = 0

# --- Main loop -------------------------------------------------------------------
foreach ($h in $hires) {
    $i++
    $first    = "$($h.FirstName)".Trim()
    $last     = "$($h.LastName)".Trim()
    $dept     = "$($h.Department)".Trim()
    $title    = "$($h.JobTitle)".Trim()
    $fullName = "$first $last".Trim()
    $label    = "[Row $i] $fullName"

    # Check 1: all fields present?
    $missing = @()
    if (-not $first) { $missing += "FirstName" }
    if (-not $last)  { $missing += "LastName" }
    if (-not $dept)  { $missing += "Department" }
    if (-not $title) { $missing += "JobTitle" }
    if ($missing.Count -gt 0) {
        Write-Log -Message "$label Missing value(s): $($missing -join ', '). Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username "" -FullName $fullName -Dept $dept -Title $title -Status "Skipped - invalid row" -Note "Missing: $($missing -join ', ')"
        continue
    }

    # Check 2: sensible names?
    if (-not (Test-PersonName $first) -or -not (Test-PersonName $last)) {
        Write-Log -Message "$label Name contains invalid characters. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -FullName $fullName -Dept $dept -Title $title -Status "Skipped - invalid name" -Note "Names may only contain letters, spaces, apostrophes, dots and hyphens"
        continue
    }

    # Check 3: known department? (accept any capitalisation, use the Config spelling)
    $deptKey = $Global:DepartmentMap.Keys | Where-Object { $_ -ieq $dept } | Select-Object -First 1
    if (-not $deptKey) {
        Write-Log -Message "$label Unknown department '$dept'. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -FullName $fullName -Dept $dept -Title $title -Status "Skipped - unknown department" -Note "Valid departments: $($Global:DepartmentMap.Keys -join ', ')"
        continue
    }
    $dept = $deptKey
    $map  = $Global:DepartmentMap[$dept]

    # Check 4: duplicate row in the CSV?
    $rowKey = "$first|$last|$dept".ToLower()
    if ($seenRows.ContainsKey($rowKey)) {
        Write-Log -Message "$label Duplicate of an earlier row. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -FullName $fullName -Dept $dept -Title $title -Status "Skipped - duplicate row" -Note "Same person appears earlier in the CSV"
        continue
    }
    $seenRows[$rowKey] = $true

    # Check 5: does the department's OU / groups really exist in AD?
    $problems = @(Get-DeptProblems -Dept $dept)
    if ($problems.Count -gt 0) {
        Write-Log -Message "$label Config problem for $dept : $($problems -join ' | '). Skipped." -Level "ERROR" -LogFile $LogFile
        $report += New-Row -FullName $fullName -Dept $dept -Title $title -Status "Skipped - config problem" -Note ($problems -join "; ")
        continue
    }

    # Check 6: find a free username (or detect the person already exists)
    $base = New-UserName -First $first -Last $last
    $res  = Resolve-UserName -Base $base -FullName $fullName -UsedThisRun $usedThisRun
    if ($res.State -eq "Exists") {
        Write-Log -Message "$label Already exists as '$($res.Username)'. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $res.Username -FullName $fullName -Dept $dept -Title $title -Status "Skipped - already exists" -Note "Account already in AD"
        continue
    }
    if ($res.State -eq "None") {
        Write-Log -Message "$label Could not find a free username based on '$base'. Skipped." -Level "ERROR" -LogFile $LogFile
        $report += New-Row -FullName $fullName -Dept $dept -Title $title -Status "Skipped - no free username" -Note "Tried $base, ${base}2 ... ${base}99, all taken"
        continue
    }
    $username = $res.Username
    $usedThisRun[$username] = $true
    $note = ""
    if ($username -ne $base) {
        $note = "Username '$base' belongs to another user, so '$username' was used"
        Write-Log -Message "$label $note" -Level "INFO" -LogFile $LogFile
    }

    $password = New-RandomPassword -Length $map.PasswordLength
    $upn      = "$username$($Global:DefaultDomainSuffix)"
    $groupsTxt = $map.SecurityGroups -join "; "

    # ShouldProcess powers -WhatIf (dry run)
    if ($PSCmdlet.ShouldProcess($fullName, "Create AD user '$username' in $($map.OU)")) {
        try {
            New-ADUser -Name $fullName `
                       -GivenName $first -Surname $last -DisplayName $fullName `
                       -SamAccountName $username -UserPrincipalName $upn `
                       -Department $dept -Title $title `
                       -Path $map.OU `
                       -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force) `
                       -ChangePasswordAtLogon $true `
                       -Enabled $true `
                       -ErrorAction Stop
            Write-Log -Message "$label Created '$username' in $($map.OU)" -Level "SUCCESS" -LogFile $LogFile
        }
        catch {
            $msg = Get-FriendlyAdError -ErrorRecord $_
            Write-Log -Message "$label FAILED to create '$username': $msg" -Level "ERROR" -LogFile $LogFile
            $report += New-Row -Username $username -FullName $fullName -Dept $dept -Title $title -Status "Failed" -Note $msg
            continue
        }

        # Group membership: each group is handled separately so one failure is visible
        $groupErrors = @()
        foreach ($g in $map.SecurityGroups) {
            try {
                Add-ADGroupMember -Identity $g -Members $username -ErrorAction Stop
                Write-Log -Message "$label Added '$username' to group '$g'" -Level "SUCCESS" -LogFile $LogFile
            }
            catch {
                $msg = Get-FriendlyAdError -ErrorRecord $_
                $groupErrors += "$g ($msg)"
                Write-Log -Message "$label FAILED adding '$username' to '$g': $msg" -Level "ERROR" -LogFile $LogFile
            }
        }
        $handoff += [pscustomobject]@{ Username = $username; FullName = $fullName; TempPassword = $password }

        if ($groupErrors.Count -gt 0) {
            $report += New-Row -Username $username -FullName $fullName -Dept $dept -Title $title -Groups $groupsTxt -Status "Created - group error" -Note "Account exists but NOT added to: $($groupErrors -join '; '). Fix manually."
        }
        else {
            $report += New-Row -Username $username -FullName $fullName -Dept $dept -Title $title -Groups $groupsTxt -Status "Created" -Note $note
        }
    }
    else {
        Write-Log -Message "$label DRY RUN: would create '$username' in $($map.OU) and add to $($map.SecurityGroups -join ', ')" -Level "INFO" -LogFile $LogFile
        $report += New-Row -Username $username -FullName $fullName -Dept $dept -Title $title -Groups $groupsTxt -Status "DryRun" -Note $note
    }
}

# --- Wrap up ------------------------------------------------------------------------
$created = @($report | Where-Object { $_.Status -like "Created*" }).Count
$skipped = @($report | Where-Object { $_.Status -like "Skipped*" }).Count
$failed  = @($report | Where-Object { $_.Status -eq "Failed" -or $_.Status -like "*error" }).Count
$dry     = @($report | Where-Object { $_.Status -eq "DryRun" }).Count
Write-Log -Message "===== Onboarding finished. Created: $created | Skipped: $skipped | Failed/errors: $failed | Dry run: $dry =====" -Level "INFO" -LogFile $LogFile

$reportFile = Join-Path $Global:LogFolder "Onboarding_Report_$stamp.csv"
$report | Export-Csv -Path $reportFile -NoTypeInformation
Write-Host "`nOnboarding report:" -ForegroundColor Magenta
$report | Format-Table Username, FullName, Department, Status, Note -AutoSize -Wrap

if ($handoff.Count -gt 0) {
    $handoffFile = Join-Path $Global:LogFolder "HANDOFF_$stamp.csv"
    $handoff | Export-Csv -Path $handoffFile -NoTypeInformation
    Write-Host "Temp passwords saved to: $handoffFile (do NOT upload this file to GitHub)" -ForegroundColor Yellow
}
Write-Host "Report saved to: $reportFile" -ForegroundColor Magenta
Write-Host "Log saved to:    $LogFile" -ForegroundColor Magenta
