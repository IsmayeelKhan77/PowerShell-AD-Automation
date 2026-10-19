<#
.SYNOPSIS
    LEAVER automation (v2): securely offboards users from Active Directory.

.DESCRIPTION
    Checkpoint 5 version. Same 8 offboarding steps as before, plus:
      - CSV is validated (file, columns, blank usernames, duplicate rows)
      - The Disabled Users OU must exist BEFORE anything starts
      - If a step fails halfway, the report says exactly which steps finished
        and which one failed, so an admin knows what to finish by hand
      - The log starts with WHO ran it, from WHERE, and in what mode

    Order of operations: disable, reset password, remove groups, write note,
    move to Disabled Users OU. The account is never deleted.

.EXAMPLE
    .\Invoke-Offboarding.ps1 -WhatIf                         # DRY RUN
    .\Invoke-Offboarding.ps1                                 # REAL RUN (asks to confirm each user)
    .\Invoke-Offboarding.ps1 -Username njoshi -Reason "Resignation"
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$Username,
    [string]$Reason = "Not specified",
    [string]$CsvPath
)

Import-Module "$PSScriptRoot\Logging-Module.psm1" -Force
Import-Module "$PSScriptRoot\Shared-Functions.psm1" -Force
. "$PSScriptRoot\Config.ps1"
Import-Module ActiveDirectory -ErrorAction Stop

$LogFile = New-LogFile -ScriptName "Offboarding" -LogFolder $Global:LogFolder
$stamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$today   = Get-Date -Format "yyyy-MM-dd"
Write-RunHeader -ScriptName "Offboarding" -LogFile $LogFile -DryRun:$WhatIfPreference

# Accounts this script must NEVER touch
$ProtectedAccounts = @("Administrator", "Guest", "krbtgt")

function New-Row {
    param($Username = "", $FullName = "", $Dept = "", $PreviousOU = "", $Removed = "", $Why = "", $Ticket = "", $Status, $Note = "")
    [pscustomobject]@{ Date = $today; Username = $Username; FullName = $FullName; Department = $Dept; PreviousOU = $PreviousOU; GroupsRemoved = $Removed; Reason = $Why; TicketRef = $Ticket; Status = $Status; Note = $Note }
}

# --- PRE-FLIGHT -----------------------------------------------------------------
if (-not (Test-OuExists -Dn $Global:DisabledOU)) {
    Write-Log -Message "Disabled Users OU not found: $($Global:DisabledOU). Fix Config.ps1 or create the OU. Nothing was changed." -Level "ERROR" -LogFile $LogFile
    exit 1
}

# Who is leaving: from -Username, or from the CSV
if ($Username) {
    $leavers = @($Username | ForEach-Object { [pscustomobject]@{ Username = $_; Reason = $Reason; TicketRef = "" } })
}
else {
    if (-not $CsvPath) { $CsvPath = Join-Path $Global:CsvFolder "Leavers.csv" }
    $csv = Test-CsvInput -Path $CsvPath -RequiredColumns @("Username")
    if (-not $csv.Ok) {
        Write-Log -Message $csv.Message -Level "ERROR" -LogFile $LogFile
        exit 1
    }
    $leavers = $csv.Rows
}
Write-Log -Message "===== Offboarding started. $(@($leavers).Count) leaver(s) to process =====" -Level "INFO" -LogFile $LogFile

$report = @()
$seen   = @{}
$i      = 0

# --- Main loop -------------------------------------------------------------------
foreach ($l in $leavers) {
    $i++
    $sam    = "$($l.Username)".Trim()
    $why    = if ($l.Reason) { "$($l.Reason)".Trim() } else { "Not specified" }
    $ticket = if ($l.TicketRef) { "$($l.TicketRef)".Trim() } else { "" }
    $label  = "[Row $i] $sam"

    # Check 1: blank username
    if (-not $sam) {
        Write-Log -Message "$label Username is blank. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Why $why -Ticket $ticket -Status "Skipped - invalid row" -Note "Username is blank"
        continue
    }

    # Check 2: same user listed twice
    if ($seen.ContainsKey($sam.ToLower())) {
        Write-Log -Message "$label Duplicate of an earlier row. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -Why $why -Ticket $ticket -Status "Skipped - duplicate row" -Note "Username appears earlier in the CSV"
        continue
    }
    $seen[$sam.ToLower()] = $true

    # Check 3: protected accounts
    if ($ProtectedAccounts -contains $sam) {
        Write-Log -Message "$label Protected account. Refused." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -Why $why -Ticket $ticket -Status "Refused - protected account" -Note "Built-in accounts are never offboarded by this script"
        continue
    }

    # Check 4: does the user exist?
    $user = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Properties Department, Title, Enabled -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Log -Message "$label User not found in AD. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -Why $why -Ticket $ticket -Status "Skipped - not found" -Note "No such username in AD"
        continue
    }
    $fullName = $user.Name
    $dept     = $user.Department
    $fromOU   = Get-ParentDn -Dn $user.DistinguishedName
    $label    = "[Row $i] $fullName"

    # Check 5: already offboarded?
    if ($user.DistinguishedName -like "*$($Global:DisabledOU)") {
        Write-Log -Message "$label Already in Disabled Users OU. Skipped." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -FullName $fullName -Dept $dept -PreviousOU $fromOU -Why $why -Ticket $ticket -Status "Skipped - already offboarded" -Note "Account is already in Disabled Users"
        continue
    }

    # Record the BEFORE state
    $groups     = @(Get-ADPrincipalGroupMembership -Identity $user | Where-Object { $_.Name -ne "Domain Users" })
    $groupNames = @($groups | ForEach-Object { $_.Name })
    $removedTxt = $groupNames -join "; "

    # Check 6: never auto-offboard a domain admin
    if ($groupNames -contains "Domain Admins") {
        Write-Log -Message "$label Member of Domain Admins. Refused (handle manually)." -Level "WARNING" -LogFile $LogFile
        $report += New-Row -Username $sam -FullName $fullName -Dept $dept -PreviousOU $fromOU -Why $why -Ticket $ticket -Status "Refused - Domain Admin" -Note "Offboard privileged accounts manually"
        continue
    }

    # ShouldProcess powers -WhatIf (dry run) and the Y/N confirmation prompt
    if ($PSCmdlet.ShouldProcess("$fullName ($sam)", "OFFBOARD: disable, reset password, remove $($groups.Count) group(s), move to Disabled Users")) {
        $steps = @()
        try {
            # 1. Disable FIRST so access stops instantly, even if a later step fails
            Disable-ADAccount -Identity $user -ErrorAction Stop
            $steps += "disabled"
            Write-Log -Message "$label Account disabled" -Level "SUCCESS" -LogFile $LogFile

            # 2. Reset the password to a random value nobody knows (not stored anywhere)
            $newPw = New-RandomPassword -Length 24
            Set-ADAccountPassword -Identity $user -Reset -NewPassword (ConvertTo-SecureString $newPw -AsPlainText -Force) -ErrorAction Stop
            $steps += "password reset"
            Write-Log -Message "$label Password reset to a random value" -Level "SUCCESS" -LogFile $LogFile

            # 3. Remove every group membership
            foreach ($g in $groups) {
                Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false -ErrorAction Stop
                $steps += "removed from $($g.Name)"
                Write-Log -Message "$label Removed from group '$($g.Name)'" -Level "SUCCESS" -LogFile $LogFile
            }

            # 4. Leave a note on the account: when and why
            $descr = "Disabled $today | Reason: $why"
            if ($ticket) { $descr += " | Ticket: $ticket" }
            Set-ADUser -Identity $user -Description $descr -ErrorAction Stop
            $steps += "description set"
            Write-Log -Message "$label Description set: $descr" -Level "SUCCESS" -LogFile $LogFile

            # 5. Move to Disabled Users OU (LAST, it changes the account's path)
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $Global:DisabledOU -ErrorAction Stop
            $steps += "moved"
            Write-Log -Message "$label Moved from '$fromOU' to Disabled Users OU" -Level "SUCCESS" -LogFile $LogFile

            $report += New-Row -Username $sam -FullName $fullName -Dept $dept -PreviousOU $fromOU -Removed $removedTxt -Why $why -Ticket $ticket -Status "Offboarded" -Note "All steps completed"
        }
        catch {
            $msg  = Get-FriendlyAdError -ErrorRecord $_
            $done = if ($steps.Count -gt 0) { $steps -join ", " } else { "nothing" }
            Write-Log -Message "$label FAILED after [$done]: $msg" -Level "ERROR" -LogFile $LogFile
            $report += New-Row -Username $sam -FullName $fullName -Dept $dept -PreviousOU $fromOU -Removed $removedTxt -Why $why -Ticket $ticket -Status "Failed" -Note "Completed before failure: $done. Error: $msg | FINISH MANUALLY."
        }
    }
    else {
        Write-Log -Message "$label NOT changed (dry run or answered No). Would disable, remove $($groups.Count) group(s) [$removedTxt], move to Disabled Users." -Level "INFO" -LogFile $LogFile
        $report += New-Row -Username $sam -FullName $fullName -Dept $dept -PreviousOU $fromOU -Removed $removedTxt -Why $why -Ticket $ticket -Status "DryRun / Not confirmed" -Note "No changes made"
    }
}

# --- Wrap up ------------------------------------------------------------------------
$done    = @($report | Where-Object { $_.Status -eq "Offboarded" }).Count
$skipped = @($report | Where-Object { $_.Status -like "Skipped*" -or $_.Status -like "Refused*" }).Count
$failed  = @($report | Where-Object { $_.Status -eq "Failed" }).Count
$dry     = @($report | Where-Object { $_.Status -like "DryRun*" }).Count
Write-Log -Message "===== Offboarding finished. Offboarded: $done | Skipped/Refused: $skipped | Failed: $failed | Dry run/Not confirmed: $dry =====" -Level "INFO" -LogFile $LogFile

$reportFile = Join-Path $Global:LogFolder "Offboarding_Report_$stamp.csv"
$report | Export-Csv -Path $reportFile -NoTypeInformation
Write-Host "`nDeprovisioning report:" -ForegroundColor Magenta
$report | Format-Table Username, FullName, @{ n = 'PreviousOU'; e = { Get-OuName $_.PreviousOU } }, GroupsRemoved, Status, Note -AutoSize -Wrap
Write-Host "Report saved to: $reportFile" -ForegroundColor Magenta
Write-Host "Log saved to:    $LogFile" -ForegroundColor Magenta
