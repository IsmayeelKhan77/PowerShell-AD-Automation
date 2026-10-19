<#
.SYNOPSIS
    Central configuration for the AD Automation project.
    Every onboarding/offboarding/mover script dot-sources this file,
    so there is ONE place to update OU paths and groups.

.NOTES
    Matches the real lab from Project 1 (domain: Project.local).
    OUs and groups below were taken from the live AD environment.
#>

# --- Domain root ---------------------------------------------------------
$Global:DomainDN = "DC=Project,DC=local"

# --- Where disabled (offboarded) users get moved --------------------------
$Global:DisabledOU = "OU=Disabled Users,$Global:DomainDN"

# --- Department -> OU / Group mapping -------------------------------------
# Keys are matched against the "Department" column in the onboarding CSV.
$Global:DepartmentMap = @{
    "IT" = @{
        OU             = "OU=IT,$Global:DomainDN"
        SecurityGroups = @("IT-Team")
        PasswordLength = 14
    }
    "Finance" = @{
        OU             = "OU=Finance,$Global:DomainDN"
        SecurityGroups = @("Finance-Team")
        PasswordLength = 14
    }
    "HR" = @{
        OU             = "OU=HR,$Global:DomainDN"
        SecurityGroups = @("HR-Team")
        PasswordLength = 14
    }
    "Management" = @{
        OU             = "OU=Management,$Global:DomainDN"
        SecurityGroups = @("Management-Team")
        PasswordLength = 14
    }
}

# --- Global script settings ----------------------------------------------
$Global:LogFolder           = Join-Path (Split-Path $PSScriptRoot -Parent) "Logs"
$Global:CsvFolder           = Join-Path (Split-Path $PSScriptRoot -Parent) "CSV"
$Global:DefaultDomainSuffix = "@project.local"   # used to build UPNs
