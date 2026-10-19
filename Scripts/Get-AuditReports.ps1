<#
.SYNOPSIS
    Access-review toolkit (v2): runs 4 audit reports against Active Directory.

.DESCRIPTION
    READ-ONLY. This script never changes anything in AD. It produces:
      1. Inactive users          - enabled accounts with no recent logon
      2. Locked-out accounts     - who is locked out right now
      3. Password expiry         - expired, expiring soon, and never-expiring passwords
      4. Group membership audit  - disabled users still in groups, and users sitting
                                   in a department group but outside that department's OU

    Checkpoint 5 change: each report runs inside its own error handler, so if one
    report fails (for example a permissions problem) the other three still run,
    and the failure is logged instead of crashing the whole script.

.EXAMPLE
    .\Get-AuditReports.ps1
    .\Get-AuditReports.ps1 -InactiveDays 7 -WarnDays 30
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 3650)][int]$InactiveDays = 30,    # no logon for this many days = inactive
    [ValidateRange(1, 365)][int]$WarnDays      = 14     # password expires within this many days = "Expiring soon"
)

Import-Module "$PSScriptRoot\Logging-Module.psm1" -Force
Import-Module "$PSScriptRoot\Shared-Functions.psm1" -Force
. "$PSScriptRoot\Config.ps1"
Import-Module ActiveDirectory -ErrorAction Stop

$LogFile = New-LogFile -ScriptName "AuditReports" -LogFolder $Global:LogFolder
$stamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$now     = Get-Date
Write-RunHeader -ScriptName "AuditReports" -LogFile $LogFile

function Save-Report {
    param($Data, [string]$Name)
    $path = Join-Path $Global:LogFolder "Audit_${Name}_$stamp.csv"
    if (@($Data).Count -gt 0) {
        $Data | Export-Csv -Path $path -NoTypeInformation
        return $path
    }
    return $null
}

function Show-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Magenta
}

Write-Log -Message "===== Audit reports started (InactiveDays=$InactiveDays, WarnDays=$WarnDays) =====" -Level "INFO" -LogFile $LogFile
$reportsOk = 0
$f1 = $f2 = $f3 = $f4 = $null

# ======================================================================
# REPORT 1: Inactive users
# Note: LastLogonDate comes from lastLogonTimestamp, which AD only updates about
# every 14 days. Accurate enough for access reviews, not for real-time checks.
# ======================================================================
Show-Header "REPORT 1: Inactive users (no logon in $InactiveDays+ days)"
try {
    $cutoff       = $now.AddDays(-$InactiveDays)
    $enabledUsers = Get-ADUser -Filter 'Enabled -eq $true' -Properties LastLogonDate, WhenCreated, Department -ErrorAction Stop

    $inactive = @(foreach ($u in $enabledUsers) {
        if (-not $u.LastLogonDate) {
            $category = "Never logged on"
            $days     = $null
        }
        elseif ($u.LastLogonDate -lt $cutoff) {
            $category = "Inactive"
            $days     = [int]($now - $u.LastLogonDate).TotalDays
        }
        else { continue }

        [pscustomobject]@{
            Username       = $u.SamAccountName
            FullName       = $u.Name
            Category       = $category
            LastLogon      = $u.LastLogonDate
            DaysSinceLogon = $days
            Created        = $u.WhenCreated
        }
    })

    if ($inactive.Count -gt 0) { $inactive | Format-Table -AutoSize } else { Write-Host "None found." -ForegroundColor Green }
    $f1 = Save-Report -Data $inactive -Name "InactiveUsers"
    Write-Log -Message "Report 1 (inactive users): $($inactive.Count) account(s) flagged" -Level "INFO" -LogFile $LogFile
    $reportsOk++
}
catch {
    Write-Log -Message "Report 1 (inactive users) FAILED: $(Get-FriendlyAdError -ErrorRecord $_)" -Level "ERROR" -LogFile $LogFile
}

# ======================================================================
# REPORT 2: Locked-out accounts
# ======================================================================
Show-Header "REPORT 2: Locked-out accounts (right now)"
try {
    $locked = @(Search-ADAccount -LockedOut -UsersOnly -ErrorAction Stop | ForEach-Object {
        $d = Get-ADUser -Identity $_.SamAccountName -Properties AccountLockoutTime, BadLogonCount -ErrorAction Stop
        [pscustomobject]@{
            Username      = $d.SamAccountName
            FullName      = $d.Name
            LockoutTime   = $d.AccountLockoutTime
            BadLogonCount = $d.BadLogonCount
            OU            = Get-ParentDn -Dn $d.DistinguishedName
        }
    })

    if ($locked.Count -gt 0) { $locked | Format-Table -AutoSize } else { Write-Host "No locked-out accounts." -ForegroundColor Green }
    $f2 = Save-Report -Data $locked -Name "LockedAccounts"
    Write-Log -Message "Report 2 (locked accounts): $($locked.Count) account(s) locked" -Level "INFO" -LogFile $LogFile
    $reportsOk++
}
catch {
    Write-Log -Message "Report 2 (locked accounts) FAILED: $(Get-FriendlyAdError -ErrorRecord $_)" -Level "ERROR" -LogFile $LogFile
}

# ======================================================================
# REPORT 3: Password expiry
# ======================================================================
Show-Header "REPORT 3: Password expiry (enabled accounts, soonest first)"
try {
    $pwUsers = Get-ADUser -Filter 'Enabled -eq $true' -Properties PasswordLastSet, PasswordNeverExpires, 'msDS-UserPasswordExpiryTimeComputed' -ErrorAction Stop

    $pwReport = @(foreach ($u in $pwUsers) {
        $expiry   = $null
        $daysLeft = $null

        if ($u.PasswordNeverExpires) {
            $status = "Never expires"
        }
        elseif (-not $u.PasswordLastSet) {
            $status = "Must change at next logon"
        }
        else {
            try {
                $expiry   = [datetime]::FromFileTime($u.'msDS-UserPasswordExpiryTimeComputed')
                $daysLeft = [int][math]::Floor(($expiry - $now).TotalDays)
                if     ($daysLeft -lt 0)          { $status = "EXPIRED" }
                elseif ($daysLeft -le $WarnDays)  { $status = "Expiring soon" }
                else                              { $status = "OK" }
            }
            catch {
                $expiry = $null
                $status = "No expiry (policy)"
            }
        }

        [pscustomobject]@{
            Username        = $u.SamAccountName
            FullName        = $u.Name
            PasswordLastSet = $u.PasswordLastSet
            ExpiresOn       = $expiry
            DaysLeft        = $daysLeft
            Status          = $status
        }
    }) | Sort-Object { if ($null -eq $_.DaysLeft) { 99999 } else { $_.DaysLeft } }

    $pwReport | Format-Table -AutoSize
    $f3 = Save-Report -Data $pwReport -Name "PasswordExpiry"
    $pwProblems = @($pwReport | Where-Object { $_.Status -in @("EXPIRED", "Expiring soon") }).Count
    Write-Log -Message "Report 3 (password expiry): $(@($pwReport).Count) account(s) checked, $pwProblems expired or expiring soon" -Level "INFO" -LogFile $LogFile
    $reportsOk++
}
catch {
    Write-Log -Message "Report 3 (password expiry) FAILED: $(Get-FriendlyAdError -ErrorRecord $_)" -Level "ERROR" -LogFile $LogFile
}

# ======================================================================
# REPORT 4: Group membership audit
#   - Is the account disabled?                  -> should not still be in a group
#   - Is the user outside that department's OU? -> possible privilege creep
# ======================================================================
Show-Header "REPORT 4: Group membership audit"
try {
    $groupAudit = @(foreach ($dept in $Global:DepartmentMap.Keys) {
        $map = $Global:DepartmentMap[$dept]
        foreach ($g in $map.SecurityGroups) {
            $members = @(Get-ADGroupMember -Identity $g -ErrorAction Stop | Where-Object { $_.objectClass -eq "user" })
            foreach ($mem in $members) {
                $u  = Get-ADUser -Identity $mem.SamAccountName -Properties Enabled -ErrorAction Stop
                $ou = Get-ParentDn -Dn $u.DistinguishedName

                if     (-not $u.Enabled) { $finding = "Disabled account still in group" }
                elseif ($ou -ne $map.OU) { $finding = "User is outside the $dept OU" }
                else                     { $finding = "OK" }

                [pscustomobject]@{
                    Group     = $g
                    Username  = $u.SamAccountName
                    FullName  = $u.Name
                    Enabled   = $u.Enabled
                    CurrentOU = $ou
                    Finding   = $finding
                }
            }
        }
    })

    $findings = @($groupAudit | Where-Object { $_.Finding -ne "OK" })
    Write-Host "$($groupAudit.Count) group membership(s) checked, $($findings.Count) finding(s)." -ForegroundColor Cyan
    if ($findings.Count -gt 0) { $findings | Format-Table -AutoSize } else { Write-Host "No findings. All memberships match their department." -ForegroundColor Green }
    $f4 = Save-Report -Data $groupAudit -Name "GroupMembership"
    Write-Log -Message "Report 4 (group audit): $($groupAudit.Count) membership(s) checked, $($findings.Count) finding(s)" -Level "INFO" -LogFile $LogFile
    $reportsOk++
}
catch {
    Write-Log -Message "Report 4 (group audit) FAILED: $(Get-FriendlyAdError -ErrorRecord $_)" -Level "ERROR" -LogFile $LogFile
}

# ======================================================================
# Wrap up
# ======================================================================
$level = if ($reportsOk -eq 4) { "SUCCESS" } else { "WARNING" }
Write-Log -Message "===== Audit reports finished: $reportsOk of 4 reports completed =====" -Level $level -LogFile $LogFile
Write-Host "`nSaved CSV reports:" -ForegroundColor Magenta
foreach ($f in @($f1, $f2, $f3, $f4)) { if ($f) { Write-Host "  $f" } }
Write-Host "Log saved to: $LogFile" -ForegroundColor Magenta
