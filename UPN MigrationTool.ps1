<#
╔═══════════════════════════════════════════════════════════════════════════╗
║                           Hilla.it                                        ║
║                   Admin UPN Migration Tool                                ║
║                                                                           ║
║  Purpose: Migrate admin accounts from custom domains to .onmicrosoft.com  ║
╚═══════════════════════════════════════════════════════════════════════════╝
#>

# Validate Microsoft Graph Connection with Error Handling
try {
    $context = Get-MgContext -ErrorAction Stop
    Write-Host "`n✓ Connected as: $($context.Account)"
} catch {
    Write-Host "`n❌ Connection Error: Please connect using:"
    Write-Host "Connect-MgGraph -Scopes 'User.ReadWrite.All','Directory.ReadWrite.All'"
    exit 1
}

# Configuration
$config = @{
    CurrentDomain = "tester.uppista.fi"
    TargetDomain = "uppistafi.onmicrosoft.com"
    Username     = "adminhilla"
}

# Process Migration
Write-Host "`n🔍 Locating admin account..."
$currentUpn = "$($config.Username)@$($config.CurrentDomain)"
$adminUser = Get-MgUser -Filter "userPrincipalName eq '$currentUpn'"

if (-not $adminUser) {
    Write-Host "`n❌ Error: Admin account not found: $currentUpn"
    exit 1
}

$newUpn = "$($config.Username)@$($config.TargetDomain)"

# Display Migration Details
Write-Host "`n📋 Migration Details:"
Write-Host "  Current UPN: $currentUpn"
Write-Host "  New UPN:     $newUpn"

$confirmation = Read-Host "`n⚠️ Proceed with migration? (Y/N)"

if ($confirmation -ne "Y") {
    Write-Host "`n✖ Operation cancelled by user."
    exit 0
}

# Execute Migration
try {
    Update-MgUser -UserId $adminUser.Id -UserPrincipalName $newUpn
    Write-Host "`n✅ Migration Successful!"
    Write-Host "   New UPN: $newUpn"
} catch {
    Write-Host "`n❌ Migration Failed:"
    Write-Host "   Error: $_"
    Write-Host "`n📝 Verified domains in your tenant:"
    Get-MgDomain | Select-Object -ExpandProperty Id
    exit 1
}

Write-Host "`n═══════════════════════════════════════════════════════════════════════════"
Write-Host "                      Migration Complete                                    "
Write-Host "═══════════════════════════════════════════════════════════════════════════`n"