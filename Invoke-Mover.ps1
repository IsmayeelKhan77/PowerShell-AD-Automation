<#
.SYNOPSIS
    MOVER automation (v2): transfers users between departments and fixes their access.

.DESCRIPTION
    Checkpoint 5 version. Same logic as before (add new groups, remove old
    department groups, update the account, move the OU), plus:
      - CSV validation (file, columns, blank rows, duplicate users)
      - Department names accepted in any capitalisation
      - The new department's OU and groups must really exist in AD
      - If a step fails halfway, the report says what finished and warns when
        the user may currently hold BOTH old and new access

.EXAMPLE
    .\Invoke-Mover.ps1 -WhatIf                       # DRY RUN
    .\Invoke-Mover.ps1                               # REAL RUN from Movers.csv
    .\Invoke-Mover.ps1 -Username amehta -NewDepartment Management -NewJobTitle "IT Operations Lead"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Username,
    [string]$NewDepartment,
    [string]$NewJobTitle,
    [string]$CsvPath
)

Import-Module "$PSScriptRoot\Logging-Module.psm1" -Force
Import-Module "$PSScriptRoot\Shared-Functions.psm1" -Force
. "$PSScriptRoot\Config.ps1"
Import-Module ActiveDirectory -ErrorAction Stop

$LogFile = New-LogFile -ScriptName "Mover" -LogFolder $Global:LogFolder
$stamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$today   = Get-Date -Format "yyyy-MM-dd"
Write-RunHeader -ScriptName "Mover" -LogFile $LogFile -DryRun:$WhatIfPreference

$ProtectedAccounts = @("Administrator", "Guest", "krbtgt")

# Every group that belongs to ANY department
$AllDeptGroups = @($Global:DepartmentMap.Values | ForEach-Object { $_.SecurityGroups } | Select-Object -Unique)

function New-Row {
    param($Username = "", $FullName = "", $From = "", $To = "", $Added = "", $Removed = "", $Kept = "", $Ticket = "", $Status, $Note = "")
    [pscustomobject]@{ Date = $today; Username = $Username; FullName = $FullName; From = $From; To = $To; GroupsAdded = $Added; GroupsRemoved = $Removed; OtherGroupsKept = $Kept; TicketRef = $Ticket; Status = $Status; Note = $Note }
}

$deptProblems = @{}
function Get-DeptProblems {
    param([string]$Dept)
    if (-not $deptProblems.ContainsKey($Dept)) {
        $deptProblems[$Dept] = @(Test-DepartmentConfig -Department $Dept -DepartmentMap $Global:DepartmentMap)
    }
    return $deptProblems[$Dept]
}

# --- PRE-FLIGHT: who is moving? ---------------------------------------------------
if ($Username) {
    if (-not $NewDepartment) {
        Write-Host "When using -Username you must also give -NewDepartment." -ForegroundColor Red
        exit 1
    }
    $movers = @($Username | ForEach-Object { [pscustomobject]@{ Username = $_; NewDepartment = $NewDepartment; NewJobTitle = $NewJobTitle; TicketRef = "" } })
}
else {
    if (-not $CsvPath) { $CsvPath = Join-Path $Global:CsvFolder "Movers.csv" }
    $csv = Test-CsvInput -Path $CsvPath -RequiredColumns @("Username", "NewDepartment")
    if (-not $csv.Ok) {
        Write-Log -Message $csv.Message -Level "ERROR" -LogFile $LogFile
        exit 1
    }
    $movers = $csv.Rows
}
Write-Log -Message "===== Mover run started. $(@($movers).Count) mover(s) to process =====" -Level "INFO" -LogFile $LogFile

$report = @()
$seen   = @{}
$i      = 0

# --- Main loop -------------------------------------------------------------------
foreach ($m in $movers) {
    $i++
    $sam      = "$($m.Username)".Trim()
    $newDept  = "$($m.NewDepartment)".Trim()
    $newTitle = if ($m.NewJobTitle) { "$($m.NewJobTitle)".Trim() } else { "" }
    $ticket   = if ($m.TicketRef) { "$($m.TicketRef)".Trim() } else { "" }
    $label    = "[Row $i] $sam"

    # Check 1: blank fields
    if (-not $sam -or -not $newDept) {
        Write-Log -Message "$label Username or NewDepartment is blank. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -To $newDept -Ticket $ticket -Status "Skipped - invalid row" -Note "Username and NewDepartment are both required"
        continue
    }

    # Check 2: same user already handled by an earlier valid row?
    if ($seen.ContainsKey($sam.ToLower())) {
        Write-Log -Message "$label Duplicate of an earlier row. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -To $newDept -Ticket $ticket -Status "Skipped - duplicate row" -Note "Username already handled by an earlier row in the CSV"
        continue
    }

    # Check 3: protected accounts
    if ($ProtectedAccounts -contains $sam) {
        Write-Log -Message "$label Protected account. Refused." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -To $newDept -Ticket $ticket -Status "Refused - protected account" -Note "Built-in accounts are never moved by this script"
        continue
    }

    # Check 4: known department? (any capitalisation)
    $deptKey = $Global:DepartmentMap.Keys | Where-Object { $_ -ieq $newDept } | Select-Object -First 1
    if (-not $deptKey) {
        Write-Log -Message "$label Unknown department '$newDept'. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -To $newDept -Ticket $ticket -Status "Skipped - unknown department" -Note "Valid departments: $($Global:DepartmentMap.Keys -join ', ')"
        continue
    }
    $newDept = $deptKey
    $map     = $Global:DepartmentMap[$newDept]

    # Check 5: do the new department's OU and groups exist in AD?
    $problems = @(Get-DeptProblems -Dept $newDept)
    if ($problems.Count -gt 0) {
        Write-Log -Message "$label Config problem for $newDept : $($problems -join ' | '). Skipped." -Level "ERROR" -LogFile $LogFile
        $report += New-Row -Username $sam -To $newDept -Ticket $ticket -Status "Skipped - config problem" -Note ($problems -join "; ")
        continue
    }

    # This row passed the basic checks, so later rows for the same user count as duplicates
    $seen[$sam.ToLower()] = $true

    # Check 6: does the user exist?
    $user = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Properties Department, Title, Enabled -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Log -Message "$label User not found in AD. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -To $newDept -Ticket $ticket -Status "Skipped - not found" -Note "No such username in AD"
        continue
    }
    $fullName = $user.Name
    $fromOU   = Get-ParentDn -Dn $user.DistinguishedName
    $fromName = Get-OuName -Dn $fromOU
    $label    = "[Row $i] $fullName"

    # Check 7: never move a disabled / offboarded account
    if ((-not $user.Enabled) -or ($user.DistinguishedName -like "*$($Global:DisabledOU)")) {
        Write-Log -Message "$label Account is disabled/offboarded. Refused." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -FullName $fullName -From $fromName -To $newDept -Ticket $ticket -Status "Refused - account disabled" -Note "Disabled accounts are not moved between departments"
        continue
    }

    # Check 8: already in the new department?
    if ($fromOU -eq $map.OU) {
        Write-Log -Message "$label Already in the $newDept OU. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -FullName $fullName -From $fromName -To $newDept -Ticket $ticket -Status "Skipped - already in department" -Note "Nothing to change"
        continue
    }

    # Work out exactly what needs to change
    $newGroups    = @($map.SecurityGroups)
    $currentNames = @(Get-ADPrincipalGroupMembership -Identity $user | Where-Object { $_.Name -ne "Domain Users" } | ForEach-Object { $_.Name })
    $toAdd        = @($newGroups | Where-Object { $currentNames -notcontains $_ })
    $toRemove     = @($currentNames | Where-Object { ($AllDeptGroups -contains $_) -and ($newGroups -notcontains $_) })
    $otherKept    = @($currentNames | Where-Object { $AllDeptGroups -notcontains $_ })
    $added        = $toAdd -join "; "
    $removed      = $toRemove -join "; "
    $kept         = $otherKept -join "; "

    if ($otherKept.Count -gt 0) {
        Write-Log -Message "$label Non-department groups kept, MANAGER REVIEW NEEDED: $kept" -Level "WARNING" -LogFile $LogFile
    }

    if ($PSCmdlet.ShouldProcess("$fullName ($sam)", "MOVE from $fromName to $newDept (add: $added | remove: $removed)")) {
        $steps = @()
        try {
            # 1. Add the new department groups FIRST (no gap in access)
            foreach ($g in $toAdd) {
                Add-ADGroupMember -Identity $g -Members $user -ErrorAction Stop
                $steps += "added to $g"
                Write-Log -Message "$label Added to group '$g'" -Level "SUCCESS" -LogFile $LogFile
            }

            # 2. Remove the OLD department groups (least privilege)
            foreach ($g in $toRemove) {
                Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false -ErrorAction Stop
                $steps += "removed from $g"
                Write-Log -Message "$label Removed from group '$g'" -Level "SUCCESS" -LogFile $LogFile
            }

            # 3. Update the Department (and Title if given)
            $set = @{ Identity = $user; Department = $newDept }
            if ($newTitle) { $set.Title = $newTitle }
            Set-ADUser @set -ErrorAction Stop
            $steps += "department/title updated"
            Write-Log -Message "$label Department set to '$newDept'$(if ($newTitle) { ", title set to '$newTitle'" })" -Level "SUCCESS" -LogFile $LogFile

            # 4. Move to the new department OU (LAST, it changes the account's path)
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $map.OU -ErrorAction Stop
            $steps += "moved"
            Write-Log -Message "$label Moved from '$fromName' to '$newDept' OU" -Level "SUCCESS" -LogFile $LogFile

            $report += New-Row -Username $sam -FullName $fullName -From $fromName -To $newDept -Added $added -Removed $removed -Kept $kept -Ticket $ticket -Status "Moved" -Note "All steps completed"
        }
        catch {
            $msg  = Get-FriendlyAdError -ErrorRecord $_
            $done = if ($steps.Count -gt 0) { $steps -join ", " } else { "nothing" }
            Write-Log -Message "$label FAILED after [$done]: $msg | CHECK THIS USER'S ACCESS MANUALLY." -Level "ERROR" -LogFile $LogFile
            $report += New-Row -Username $sam -FullName $fullName -From $fromName -To $newDept -Added $added -Removed $removed -Kept $kept -Ticket $ticket -Status "Failed" -Note "Completed before failure: $done. Error: $msg | User may hold BOTH old and new access, check manually."
        }
    }
    else {
        Write-Log -Message "$label DRY RUN: would move $fromName -> $newDept | add [$added] | remove [$removed] | keep other [$kept]" -Level "INFO" -LogFile $LogFile
        $report += New-Row -Username $sam -FullName $fullName -From $fromName -To $newDept -Added $added -Removed $removed -Kept $kept -Ticket $ticket -Status "DryRun / Not confirmed" -Note "No changes made"
    }
}

# --- Wrap up ------------------------------------------------------------------------
$done    = @($report | Where-Object { $_.Status -eq "Moved" }).Count
$skipped = @($report | Where-Object { $_.Status -like "Skipped*" -or $_.Status -like "Refused*" }).Count
$failed  = @($report | Where-Object { $_.Status -eq "Failed" }).Count
$dry     = @($report | Where-Object { $_.Status -like "DryRun*" }).Count
Write-Log -Message "===== Mover run finished. Moved: $done | Skipped/Refused: $skipped | Failed: $failed | Dry run/Not confirmed: $dry =====" -Level "INFO" -LogFile $LogFile

$reportFile = Join-Path $Global:LogFolder "Mover_Report_$stamp.csv"
$report | Export-Csv -Path $reportFile -NoTypeInformation
Write-Host "`nMover report:" -ForegroundColor Magenta
$report | Format-Table Username, FullName, From, To, GroupsAdded, GroupsRemoved, Status, Note -AutoSize -Wrap
Write-Host "Report saved to: $reportFile" -ForegroundColor Magenta
Write-Host "Log saved to:    $LogFile" -ForegroundColor Magenta
