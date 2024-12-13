<#
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║                                 Hilla.it                                  ║
║                                                                           ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
#>

# Connect and validate Microsoft Graph Connection
Write-Host "`n🔄 Connecting to Microsoft Graph..."
try {
    Connect-MgGraph -Scopes @(
        "User.ReadWrite.All",
        "Directory.ReadWrite.All",
        "RoleManagement.ReadWrite.Directory",
        "UserAuthenticationMethod.ReadWrite.All",
        "Policy.ReadWrite.ConditionalAccess"
    )
    
    $context = Get-MgContext -ErrorAction Stop
    Write-Host "`n✓ Connected as: $($context.Account)"
} catch {
    Write-Host "`n❌ Connection Error: $_"
    Write-Host "Make sure Microsoft.Graph module is installed:"
    Write-Host "Install-Module Microsoft.Graph -Scope CurrentUser"
    exit 1
}

# Connect to Exchange Online if not already connected
$exchangeSession = Get-PSSession | Where-Object {$_.ConfigurationName -eq "Microsoft.Exchange" -and $_.State -eq "Opened"}
if (-not $exchangeSession) {
    try {
        Write-Host "`n🔄 Connecting to Exchange Online..."
        Connect-ExchangeOnline -ErrorAction Stop
        Write-Host "✓ Connected to Exchange Online"
    } catch {
        Write-Host "`n❌ Exchange Online Connection Error: $_"
        Write-Host "Make sure ExchangeOnlineManagement module is installed:"
        Write-Host "Install-Module ExchangeOnlineManagement -Scope CurrentUser"
        exit 1
    }
}

# Helper Functions
function Set-UserAsGlobalAdmin {
    param(
        [string]$UserId,
        [string]$UserUpn
    )
    try {
        # Find Global Administrator role
        $globalAdminRole = Get-MgDirectoryRole | Where-Object { $_.DisplayName -eq "Global Administrator" }
        
        # Check if user is already Global Admin
        $existingMembers = Get-MgDirectoryRoleMember -DirectoryRoleId $globalAdminRole.Id
        if ($existingMembers.Id -contains $UserId) {
            Write-Host "ℹ️ User is already a Global Administrator"
            return $true
        }

        # Assign Global Admin role
        New-MgDirectoryRoleMember -DirectoryRoleId $globalAdminRole.Id -DirectoryObjectId $UserId
        Write-Host "✅ Global Administrator role assigned successfully"
        return $true
    }
    catch {
        Write-Host "❌ Failed to assign Global Administrator role: $_"
        return $false
    }
}

function New-GlobalAdmin {
    param(
        [string]$UserPrincipalName,
        [string]$DisplayName
    )
    try {
        # Generate a secure random password
        $PasswordLength = 16
        $RandomPassword = -join ((33..126) | Get-Random -Count $PasswordLength | ForEach-Object { [char]$_ })
        $SecurePassword = ConvertTo-SecureString -String $RandomPassword -AsPlainText -Force
        
        # Create new user
        $params = @{
            DisplayName = $DisplayName
            UserPrincipalName = $UserPrincipalName
            PasswordProfile = @{
                Password = $RandomPassword
                ForceChangePasswordNextSignIn = $true
            }
            AccountEnabled = $true
        }
        
        $newUser = New-MgUser -BodyParameter $params
        Write-Host "✅ Created new account"
        Write-Host "   Initial password: $RandomPassword"
        Write-Host "   User must change password at first login"
        return $newUser
    }
    catch {
        throw "Failed to create account: $_"
    }
}

function New-EmailForwardingPolicy {
    param(
        [string]$UserUpn
    )
    try {
        # Create new transport rule
        $ruleName = "Allow External Forwarding - $UserUpn"
        
        # Check if rule already exists
        $existingRule = Get-TransportRule | Where-Object {$_.Name -eq $ruleName}
        if ($existingRule) {
            Write-Host "ℹ️ Mail flow policy already exists for this user"
            return $true
        }
        
        $ruleParams = @{
            Name = $ruleName
            FromScope = "InOrganization"
            SentToScope = "External"
            RedirectMessageTo = "tuki@hilla.it"
            ExceptIfFrom = @($UserUpn)
            Enabled = $true
            Priority = 0
        }
        
        New-TransportRule @ruleParams
        Write-Host "✅ Created mail flow policy to allow external forwarding"
        return $true
    }
    catch {
        Write-Host "❌ Failed to create mail flow policy: $_"
        return $false
    }
}

function New-HillaNamedLocation {
    param(
        [string]$IpAddresses
    )
    try {
        $locationName = "Hilla Office Location"
        
        # Check if named location already exists
        $existingLocation = Get-MgIdentityConditionalAccessNamedLocation | Where-Object { $_.DisplayName -eq $locationName }
        if ($existingLocation) {
            Write-Host "ℹ️ Named location already exists for Hilla"
            return $existingLocation
        }
        
        # Split IP addresses if multiple
        $ipRanges = $IpAddresses.Split(',') | ForEach-Object {
            @{
                "@odata.type" = "#microsoft.graph.iPv4CidrRange"
                cidrAddress = $_.Trim()
            }
        }
        
        $params = @{
            "@odata.type" = "#microsoft.graph.ipNamedLocation"
            DisplayName = $locationName
            IsTrusted = $true
            IpRanges = $ipRanges
        }
        
        $namedLocation = New-MgIdentityConditionalAccessNamedLocation -BodyParameter $params
        Write-Host "✅ Created named location for Hilla IP addresses"
        return $namedLocation
    }
    catch {
        Write-Host "❌ Failed to create named location: $_"
        return $null
    }
}

function New-HillaConditionalAccessPolicy {
    param(
        [string]$UserId,
        [string]$UserUpn,
        [string]$LocationId
    )
    try {
        $policyName = "Hilla IP Restriction - $UserUpn"
        
        # Check if policy already exists
        $existingPolicy = Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.DisplayName -eq $policyName }
        if ($existingPolicy) {
            Write-Host "ℹ️ Conditional Access Policy already exists for this user"
            return $true
        }
        
        $policyParams = @{
            DisplayName = $policyName
            State = "enabledForReportingButNotEnforced"  # Report-only mode
            Conditions = @{
                Users = @{
                    IncludeUsers = @($UserId)
                    ExcludeUsers = @()
                }
                Locations = @{
                    IncludeLocations = @("All")
                    ExcludeLocations = @($LocationId)
                }
                Applications = @{
                    IncludeApplications = @("All")
                }
            }
            GrantControls = @{
                Operator = "OR"
                BuiltInControls = @("Block")
            }
        }
        
        New-MgIdentityConditionalAccessPolicy -BodyParameter $policyParams
        Write-Host "✅ Created Conditional Access Policy in report-only mode"
        return $true
    }
    catch {
        Write-Host "❌ Failed to create Conditional Access Policy: $_"
        return $false
    }
}

# Configuration
$config = @{
    CurrentDomain = "tester.uppista.fi"
    TargetDomain = "uppistafi.onmicrosoft.com"
    Username     = "adminhilla"
    ForwardTo    = "tuki@hilla.it"
}

# Available Licenses
$licenses = @{
    "Microsoft 365 Business Premium" = "cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46"
    "Exchange Online Kiosk" = "80b2d799-d2ba-4d2a-8842-fb0d0f3a4b82"
    "Microsoft Entra ID P1" = "078d2b04-f1bd-4111-bbd4-b4b1b354cef4"
}

# Process Migration
Write-Host "`n🔍 Locating admin account..."
$currentUpn = "$($config.Username)@$($config.CurrentDomain)"
$adminUser = Get-MgUser -Filter "userPrincipalName eq '$currentUpn'"

# Check if account exists, create if needed
if (-not $adminUser) {
    $createPrompt = Read-Host "`n❓ Admin account not found. Create new account? (Y/N)"
    if ($createPrompt -eq "Y") {
        try {
            $displayName = "$($config.Username) Admin"
            $adminUser = New-GlobalAdmin -UserPrincipalName $currentUpn -DisplayName $displayName
        }
        catch {
            Write-Host "`n❌ Error creating account: $_"
            exit 1
        }
    }
    else {
        Write-Host "`n✖ Operation cancelled by user."
        exit 1
    }
}

# Prompt for Global Admin assignment first
$globalAdminPrompt = Read-Host "`n➤ Do you want to make this account a Global Administrator? (Y/N)"
if ($globalAdminPrompt -eq "Y") {
    if (-not (Set-UserAsGlobalAdmin -UserId $adminUser.Id -UserUpn $currentUpn)) {
        $continuePrompt = Read-Host "`n❓ Failed to assign Global Admin role. Continue with other tasks? (Y/N)"
        if ($continuePrompt -ne "Y") {
            Write-Host "`n✖ Operation cancelled by user."
            exit 1
        }
    }
}

$newUpn = "$($config.Username)@$($config.TargetDomain)"

# Display Migration Details
Write-Host "`n📋 Migration Details:"
Write-Host "  Current UPN: $currentUpn"
Write-Host "  New UPN:     $newUpn"

# Configuration Prompts
$configSettings = @{
    EnableForwarding = $false
    CreateMailFlowPolicy = $false
    HideFromAddressBook = $false
    SelectedLicenses = @()
    EnableMFA = $false
    MFAPhone = ""
    EnableTOTP = $false
    CreateNamedLocation = $false
    IpAddresses = ""
    CreateConditionalAccess = $false
}

# Email Forwarding Check and Prompt
Write-Host "`n📧 Checking current email forwarding settings..."
try {
    $currentMailbox = Get-Mailbox -Identity $currentUpn -ErrorAction Stop
    Write-Host "Current Email Forwarding Settings:"
    Write-Host "  • Forward To: $($currentMailbox.ForwardingSmtpAddress)"
    Write-Host "  • Keep Copy: $($currentMailbox.DeliverToMailboxAndForward)"
    Write-Host "  • Hidden from Address List: $($currentMailbox.HiddenFromAddressListsEnabled)"
} 
catch {
    Write-Host "  • No email forwarding currently configured or unable to fetch settings"
    Write-Host "  • Error: $_"
}

$forwardingPrompt = Read-Host "`n➤ Do you want to enable email forwarding to $($config.ForwardTo)? (Y/N)"
$configSettings.EnableForwarding = ($forwardingPrompt -eq 'Y')

# Mail Flow Policy Prompt (if email forwarding is enabled)
if ($configSettings.EnableForwarding) {
    $policyPrompt = Read-Host "`n➤ Do you want to create a mail flow policy to allow external forwarding? (Y/N)"
    $configSettings.CreateMailFlowPolicy = ($policyPrompt -eq 'Y')
}

# Hide from Address Book Prompt
$hidePrompt = Read-Host "`n➤ Do you want to hide this user from the address book? (Y/N)"
$configSettings.HideFromAddressBook = ($hidePrompt -eq 'Y')

# License Assignment Prompts
foreach ($license in $licenses.GetEnumerator()) {
    $response = Read-Host "`n➤ Assign $($license.Key) license? (Y/N)"
    if ($response -eq 'Y') {
        $configSettings.SelectedLicenses += $license.Value
    }
}

# MFA Configuration Prompts
$mfaPrompt = Read-Host "`n➤ Do you want to configure MFA? (Y/N)"
if ($mfaPrompt -eq 'Y') {
    $configSettings.EnableMFA = $true
    
    # TOTP Option
    $totpPrompt = Read-Host "➤ Enable TOTP (Authenticator App)? (Y/N)"
    $configSettings.EnableTOTP = ($totpPrompt -eq 'Y')
    
    # Phone MFA Option
    $phonePrompt = Read-Host "➤ Configure Phone Number MFA? (Y/N)"
    if ($phonePrompt -eq 'Y') {
        $configSettings.MFAPhone = Read-Host "Enter Hilla MFA phone number (format: +358XXXXXXXXX)"
    }
}

# Named Location and Conditional Access Prompts
$namedLocationPrompt = Read-Host "`n➤ Do you want to create a named location for Hilla IP addresses? (Y/N)"
if ($namedLocationPrompt -eq 'Y') {
    $configSettings.CreateNamedLocation = $true
    $configSettings.IpAddresses = Read-Host "Enter IP address(es) in CIDR format (e.g., 192.168.1.0/24, separate multiple with commas)"
    
    # Conditional Access Policy Prompt
    $caPrompt = Read-Host "`n➤ Do you want to create a Conditional Access Policy to restrict login to Hilla IP addresses? (Y/N)"
    $configSettings.CreateConditionalAccess = ($caPrompt -eq 'Y')
}

# Display Summary of Changes
Write-Host "`n📋 Summary of Changes to be Applied:"
Write-Host "  • UPN Migration: $currentUpn → $newUpn"
Write-Host "  • Email Forwarding: $(if ($configSettings.EnableForwarding) { "Enabled to $($config.ForwardTo)" } else { 'No change' })"
Write-Host "  • Mail Flow Policy: $(if ($configSettings.CreateMailFlowPolicy) { 'Will be created' } else { 'No change' })"
Write-Host "  • Address Book Visibility: $(if ($configSettings.HideFromAddressBook) { 'Hidden' } else { 'No change' })"
Write-Host "  • Licenses to Assign: $($configSettings.SelectedLicenses.Count) selected"
Write-Host "  • MFA - TOTP: $(if ($configSettings.EnableTOTP) { 'Enabled' } else { 'No change' })"
Write-Host "  • MFA - Phone: $(if ($configSettings.MFAPhone) { $configSettings.MFAPhone } else { 'No change' })"
Write-Host "  • Named Location: $(if ($configSettings.CreateNamedLocation) { "Will be created with IP(s): $($configSettings.IpAddresses)" } else { 'No change' })"
Write-Host "  • Conditional Access: $(if ($configSettings.CreateConditionalAccess) { 'Will be created in report-only mode' } else { 'No change' })"

$confirmation = Read-Host "`n⚠️ Proceed with these changes? (Y/N)"

if ($confirmation -ne "Y") {
    Write-Host "`n✖ Operation cancelled by user."
    exit 0
}

# Execute Migration and Changes
try {
    # Update UPN
    Update-MgUser -UserId $adminUser.Id -UserPrincipalName $newUpn
    Write-Host "`n✅ UPN Migration Successful!"
    Write-Host "   New UPN: $newUpn"

    # Assign selected licenses first (needed for email forwarding)
    if ($configSettings.SelectedLicenses.Count -gt 0) {
        $licenseParams = @{
            AddLicenses = @(
                foreach ($licenseId in $configSettings.SelectedLicenses) {
                    @{
                        SkuId = $licenseId
                    }
                }
            )
            RemoveLicenses = @()
        }
        Set-MgUserLicense -UserId $adminUser.Id -BodyParameter $licenseParams
        Write-Host "✅ Licenses assigned successfully"
        
        if ($configSettings.EnableForwarding) {
            Write-Host "`n⏳ Waiting for license to propagate (30 seconds)..."
            Start-Sleep -Seconds 30
        }
    }

    # Configure Email Forwarding if selected
    if ($configSettings.EnableForwarding) {
        try {
            Set-Mailbox -Identity $newUpn -ForwardingSmtpAddress "smtp:$($config.ForwardTo)" -DeliverToMailboxAndForward $true
            Write-Host "✅ Email forwarding configured to $($config.ForwardTo)"
            
            # Create mail flow policy if selected
            if ($configSettings.CreateMailFlowPolicy) {
                New-EmailForwardingPolicy -UserUpn $newUpn
            }
        }
        catch {
            Write-Host "❌ Failed to configure email forwarding: $_"
            Write-Host "Note: Exchange license may need more time to propagate"
        }
    }

    # Hide from address list if selected
    if ($configSettings.HideFromAddressBook) {
        Update-MgUser -UserId $adminUser.Id -HideFromAddressLists:$true
        Write-Host "✅ User hidden from address list"
    }

    # Configure MFA if selected
    if ($configSettings.EnableMFA) {
        Write-Host "`n⚙️ Configuring MFA..."
        
        # Enable TOTP if selected
        if ($configSettings.EnableTOTP) {
            $totpMethod = @{
                "@odata.type" = "#microsoft.graph.microsoftAuthenticatorAuthenticationMethod"
            }
            New-MgUserAuthenticationMethod -UserId $adminUser.Id -BodyParameter $totpMethod
            Write-Host "✅ TOTP authentication enabled"
        }
        
        # Configure Phone MFA if selected
        if ($configSettings.MFAPhone) {
            $phoneMethod = @{
                "@odata.type" = "#microsoft.graph.phoneAuthenticationMethod"
                phoneNumber = $configSettings.MFAPhone
                phoneType = "mobile"
            }
            New-MgUserAuthenticationMethod -UserId $adminUser.Id -BodyParameter $phoneMethod
            Write-Host "✅ Phone authentication enabled: $($configSettings.MFAPhone)"
        }
    }

    # Configure Named Location and Conditional Access if selected
    if ($configSettings.CreateNamedLocation) {
        $namedLocation = New-HillaNamedLocation -IpAddresses $configSettings.IpAddresses
        
        if ($configSettings.CreateConditionalAccess -and $namedLocation) {
            New-HillaConditionalAccessPolicy -UserId $adminUser.Id -UserUpn $newUpn -LocationId $namedLocation.Id
        }
    }

} catch {
    Write-Host "`n❌ Operation Failed:"
    Write-Host "   Error: $_"
    Write-Host "`n📝 Verified domains in your tenant:"
    Get-MgDomain | Select-Object -ExpandProperty Id
    exit 1
}

# Disconnect from services at the end
try {
    Disconnect-ExchangeOnline -Confirm:$false
    Disconnect-MgGraph
    Write-Host "`n✓ Disconnected from all services"
}
catch {
    Write-Host "⚠️ Warning: Failed to disconnect from some services: $_"
}

Write-Host "`n═══════════════════════════════════════════════════════════════════════════"
Write-Host "                      Migration Complete                                    "
Write-Host "═══════════════════════════════════════════════════════════════════════════`n"