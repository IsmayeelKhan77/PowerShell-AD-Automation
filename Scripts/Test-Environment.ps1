<#
.SYNOPSIS
    Checkpoint 1 verification script.
    Run this FIRST on your Domain Controller (or a machine with RSAT-AD
    tools installed) to confirm everything is wired up correctly before
    building onboarding/offboarding automation on top of it.

.DESCRIPTION
    1. Confirms the ActiveDirectory module loads.
    2. Confirms the Logging module loads and writes a test log entry.
    3. Lists your real OUs and Security Groups so you can update
       Config.ps1 to match your actual lab exactly.

.NOTES
    Run as: .\Test-Environment.ps1
    Must be run with an account that has read access to AD (any domain
    user can read AD by default).
#>

$ScriptRoot = $PSScriptRoot
Import-Module "$ScriptRoot\Logging-Module.psm1" -Force
. "$ScriptRoot\Config.ps1"

$LogFile = New-LogFile -ScriptName "Test-Environment" -LogFolder $Global:LogFolder

Write-Log -Message "===== Checkpoint 1: Environment Verification Started =====" -Level "INFO" -LogFile $LogFile

# --- Step 1: Confirm AD module ---------------------------------------------
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Log -Message "ActiveDirectory module loaded successfully." -Level "SUCCESS" -LogFile $LogFile
}
catch {
    Write-Log -Message "FAILED to load ActiveDirectory module: $($_.Exception.Message)" -Level "ERROR" -LogFile $LogFile
    Write-Log -Message "Install RSAT-AD-PowerShell via: Install-WindowsFeature RSAT-AD-PowerShell (on a server) or via Windows Optional Features (on a client OS)." -Level "WARNING" -LogFile $LogFile
    exit 1
}

# --- Step 2: Confirm domain connectivity -----------------------------------
try {
    $domain = Get-ADDomain -ErrorAction Stop
    Write-Log -Message "Connected to domain: $($domain.DNSRoot)" -Level "SUCCESS" -LogFile $LogFile
}
catch {
    Write-Log -Message "FAILED to reach domain: $($_.Exception.Message)" -Level "ERROR" -LogFile $LogFile
    exit 1
}

# --- Step 3: List real OUs so Config.ps1 can be matched to them -------------
Write-Log -Message "Listing Organizational Units in the domain:" -Level "INFO" -LogFile $LogFile
$ous = Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName
foreach ($ou in $ous) {
    Write-Log -Message "OU Found -> $($ou.Name) | $($ou.DistinguishedName)" -Level "INFO" -LogFile $LogFile
}

# --- Step 4: List real Security Groups --------------------------------------
Write-Log -Message "Listing Security Groups in the domain:" -Level "INFO" -LogFile $LogFile
$groups = Get-ADGroup -Filter * | Select-Object Name, GroupCategory, DistinguishedName
foreach ($g in $groups) {
    Write-Log -Message "Group Found -> $($g.Name) | Category: $($g.GroupCategory)" -Level "INFO" -LogFile $LogFile
}

# --- Step 5: Sanity-check Config.ps1 against real AD ------------------------
Write-Log -Message "Validating Config.ps1 department mappings against live AD..." -Level "INFO" -LogFile $LogFile
foreach ($dept in $Global:DepartmentMap.Keys) {
    $mapping = $Global:DepartmentMap[$dept]

    $ouExists = [adsi]::Exists("LDAP://$($mapping.OU)")
    if ($ouExists) {
        Write-Log -Message "[$dept] OU path OK -> $($mapping.OU)" -Level "SUCCESS" -LogFile $LogFile
    } else {
        Write-Log -Message "[$dept] OU path NOT FOUND -> $($mapping.OU). Update Config.ps1 to match a real OU listed above." -Level "WARNING" -LogFile $LogFile
    }

    foreach ($groupName in $mapping.SecurityGroups) {
        $groupObj = Get-ADGroup -Filter { Name -eq $groupName } -ErrorAction SilentlyContinue
        if ($groupObj) {
            Write-Log -Message "[$dept] Group OK -> $groupName" -Level "SUCCESS" -LogFile $LogFile
        } else {
            Write-Log -Message "[$dept] Group NOT FOUND -> $groupName. Either create it or update Config.ps1." -Level "WARNING" -LogFile $LogFile
        }
    }
}

# --- Step 6: Check the Disabled Users OU used by offboarding ----------------
if ([adsi]::Exists("LDAP://$($Global:DisabledOU)")) {
    Write-Log -Message "Disabled Users OU OK -> $($Global:DisabledOU)" -Level "SUCCESS" -LogFile $LogFile
} else {
    Write-Log -Message "Disabled Users OU NOT FOUND -> $($Global:DisabledOU). Offboarding needs it. Update Config.ps1 or create the OU." -Level "WARNING" -LogFile $LogFile
}

Write-Log -Message "===== Checkpoint 1: Environment Verification Complete =====" -Level "INFO" -LogFile $LogFile
Write-Host "`nDone. Full log saved to: $LogFile" -ForegroundColor Magenta
