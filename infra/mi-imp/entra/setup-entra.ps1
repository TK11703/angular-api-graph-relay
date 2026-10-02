<#
.SYNOPSIS
    Creates the Entra ID app registrations for the managed-identity implementation, and grants the
    API's managed identity its Microsoft Graph application permissions.

.DESCRIPTION
    App 1 - "PoC API (MI)" (resource only)
        * exposes the delegated scope  access_as_user
        * defines the app role         ApplicationAdmin
        * holds no credential and no Graph permissions: it only validates inbound tokens

    App 2 - "PoC SPA (MI)" (public client)
        * SPA redirect URI for the Angular dev server
        * permission to call the API's access_as_user scope (pre-authorized, so no second consent prompt)

    Managed identity (with -ManagedIdentityResourceId / -ManagedIdentityPrincipalId)
        * Microsoft Graph application permissions (app-only, tenant-wide)
        * optionally the User Administrator directory role

    The identity only exists after infra/mi-imp/azure/deploy.ps1 has run, so run this script once
    before deploying and again afterwards with the identity. The script is idempotent.

.NOTES
    Requires the Application Administrator role (to create apps) and
    Privileged Role Administrator / Global Administrator (to grant Graph application permissions).

.EXAMPLE
    ./setup-entra.ps1 -AssignAdminRoleToCurrentUser -ApplyLocalConfig

.EXAMPLE
    ./setup-entra.ps1 -ManagedIdentityResourceId /subscriptions/.../userAssignedIdentities/aagrmi-api-id
#>
[CmdletBinding()]
param(
    [string] $ApiAppName = 'PoC API (MI)',
    [string] $SpaAppName = 'PoC SPA (MI)',
    [string] $SpaRedirectUri = 'http://localhost:4200',
    # Deployed SPA origins. Existing redirect URIs are kept.
    [string[]] $AdditionalSpaRedirectUris = @(),
    [string] $ApiBaseUrl = 'https://localhost:7182/api',

    # Sovereign-cloud endpoints. Left empty, both are read from the CLI's active cloud
    # (`az cloud show`), so `az cloud set --name AzureUSGovernment` is normally enough.
    [string] $GraphResourceUrl,
    [string] $AuthorityHost,
    [string] $GraphApiVersion = 'v1.0',

    # Grants the current signed-in user the ApplicationAdmin app role.
    [switch] $AssignAdminRoleToCurrentUser,

    # The API's managed identity. Supply the user-assigned identity's resource id, or the principal
    # id directly (required for a system-assigned identity). Omit to skip the Graph grants.
    [string] $ManagedIdentityResourceId,
    [string] $ManagedIdentityPrincipalId,
    [string[]] $ManagedIdentityGraphAppRoles = @('User.Read.All', 'GroupMember.Read.All', 'User.ReadWrite.All'),
    # Graph only lets app-only callers edit some properties (e.g. mobilePhone) with a directory role.
    [switch] $AssignUserAdministratorRoleToManagedIdentity,

    # Writes the resulting ids into src/mi-imp/poc-web/.../environment.ts and the API user-secrets.
    [switch] $ApplyLocalConfig
)

$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# First-party app ids and built-in role template ids are identical in every cloud.
$GraphAppId = '00000003-0000-0000-c000-000000000000'
$UserAdministratorRoleId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$ApiDir = Join-Path $RepoRoot 'src/mi-imp/Poc.Api'
$WebDir = Join-Path $RepoRoot 'src/mi-imp/poc-web'

#region helpers ---------------------------------------------------------------

# az writes warnings to stderr, so stdout and stderr are separated before parsing JSON.
function Invoke-Az {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AsJson
    )

    $all = & az @Arguments 2>&1
    $stdout = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"

    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$stderr"
    }

    if (-not $AsJson) { return $stdout }
    if ([string]::IsNullOrWhiteSpace($stdout)) { return $null }
    return $stdout | ConvertFrom-Json
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)
    return Invoke-Az -Arguments ($Arguments + @('--output', 'json')) -AsJson
}

# $Path is relative to $GraphApiUrl so no cloud-specific host is hard-coded at the call sites.
function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PATCH', 'POST')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [hashtable] $Body
    )

    $arguments = @('rest', '--method', $Method, '--url', "$GraphApiUrl/$($Path.TrimStart('/'))")
    if (-not $Body) {
        return Invoke-AzJson -Arguments $arguments
    }

    $file = New-TemporaryFile
    try {
        ($Body | ConvertTo-Json -Depth 20) | Set-Content -Path $file.FullName -Encoding utf8
        Invoke-Az -Arguments ($arguments + @(
                '--headers', 'Content-Type=application/json',
                '--body', "@$($file.FullName)"
            )) | Out-Null
    }
    finally {
        Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-AppByDisplayName {
    param([Parameter(Mandatory)][string] $DisplayName)

    $found = @(Invoke-AzJson -Arguments @('ad', 'app', 'list', '--display-name', $DisplayName))
    if ($found.Count -gt 0) { return $found[0] }
    return $null
}

function Confirm-ServicePrincipal {
    param([Parameter(Mandatory)][string] $AppId)

    $existing = @(Invoke-AzJson -Arguments @('ad', 'sp', 'list', '--filter', "appId eq '$AppId'"))
    if ($existing.Count -gt 0) { return $existing[0] }

    Write-Host "  creating service principal for $AppId"
    return Invoke-AzJson -Arguments @('ad', 'sp', 'create', '--id', $AppId)
}

function Get-PropertyOrDefault {
    param($InputObject, [string] $Name)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject.PSObject.Properties.Name -contains $Name) { return $InputObject.$Name }
    return $null
}

#endregion --------------------------------------------------------------------

Write-Host '==> Checking Azure CLI sign-in' -ForegroundColor Cyan
$account = Invoke-AzJson -Arguments @('account', 'show')
$tenantId = $account.tenantId
Write-Host "  tenant : $tenantId"
Write-Host "  user   : $($account.user.name)"

Write-Host '==> Resolving cloud endpoints' -ForegroundColor Cyan
$cloud = Invoke-AzJson -Arguments @('cloud', 'show')
if (-not $GraphResourceUrl) { $GraphResourceUrl = Get-PropertyOrDefault $cloud.endpoints 'microsoftGraphResourceId' }
if (-not $AuthorityHost) { $AuthorityHost = Get-PropertyOrDefault $cloud.endpoints 'activeDirectory' }
if (-not $GraphResourceUrl) { throw "Cloud '$($cloud.name)' does not publish a Microsoft Graph endpoint. Pass -GraphResourceUrl explicitly." }
if (-not $AuthorityHost) { throw "Cloud '$($cloud.name)' does not publish an Entra ID authority. Pass -AuthorityHost explicitly." }

$GraphResourceUrl = $GraphResourceUrl.TrimEnd('/')
$AuthorityHost = $AuthorityHost.TrimEnd('/') + '/'
$GraphApiUrl = "$GraphResourceUrl/$GraphApiVersion"
Write-Host "  cloud     : $($cloud.name)"
Write-Host "  graph     : $GraphApiUrl"
Write-Host "  authority : $AuthorityHost"

# ---------------------------------------------------------------- API app ----
Write-Host "==> API app registration: $ApiAppName" -ForegroundColor Cyan
$apiApp = Get-AppByDisplayName -DisplayName $ApiAppName
if ($apiApp) {
    Write-Host "  reusing existing app $($apiApp.appId)"
}
else {
    $apiApp = Invoke-AzJson -Arguments @('ad', 'app', 'create', '--display-name', $ApiAppName, '--sign-in-audience', 'AzureADMyOrg')
    Write-Host "  created app $($apiApp.appId)"
    Start-Sleep -Seconds 10   # directory replication
}

$apiObjectId = $apiApp.id
$apiAppId = $apiApp.appId

# Reuse existing identifiers when re-running, otherwise mint new ones.
$existingScope = (Get-PropertyOrDefault (Get-PropertyOrDefault $apiApp 'api') 'oauth2PermissionScopes') |
    Where-Object { $_.value -eq 'access_as_user' } | Select-Object -First 1
$apiScopeId = if ($existingScope) { $existingScope.id } else { [guid]::NewGuid().ToString() }

$existingRole = (Get-PropertyOrDefault $apiApp 'appRoles') |
    Where-Object { $_.value -eq 'ApplicationAdmin' } | Select-Object -First 1
$adminRoleId = if ($existingRole) { $existingRole.id } else { [guid]::NewGuid().ToString() }

$apiScope = @{
    id                      = $apiScopeId
    value                   = 'access_as_user'
    type                    = 'User'
    isEnabled               = $true
    adminConsentDisplayName = 'Access the PoC API as the signed-in user'
    adminConsentDescription = 'Allows the app to call the PoC API on behalf of the signed-in user.'
    userConsentDisplayName  = 'Access the PoC API on your behalf'
    userConsentDescription  = 'Allows the app to call the PoC API as you.'
}

# requiredResourceAccess is emptied: Graph is reached through the managed identity, not this app.
Invoke-GraphRequest -Method PATCH -Path "applications/$apiObjectId" -Body @{
    identifierUris         = @("api://$apiAppId")
    api                    = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @($apiScope)
    }
    appRoles               = @(
        @{
            id                 = $adminRoleId
            value              = 'ApplicationAdmin'
            displayName        = 'Application Administrator'
            description        = 'Can edit Entra ID profile information for other users in the tenant.'
            allowedMemberTypes = @('User')
            isEnabled          = $true
        }
    )
    requiredResourceAccess = @()
}
Write-Host '  identifier uri, access_as_user scope and ApplicationAdmin role configured'

$apiSp = Confirm-ServicePrincipal -AppId $apiAppId

# ---------------------------------------------------------------- SPA app ----
Write-Host "==> SPA app registration: $SpaAppName" -ForegroundColor Cyan
$spaApp = Get-AppByDisplayName -DisplayName $SpaAppName
if ($spaApp) {
    Write-Host "  reusing existing app $($spaApp.appId)"
}
else {
    $spaApp = Invoke-AzJson -Arguments @('ad', 'app', 'create', '--display-name', $SpaAppName, '--sign-in-audience', 'AzureADMyOrg')
    Write-Host "  created app $($spaApp.appId)"
    Start-Sleep -Seconds 10
}

$spaObjectId = $spaApp.id
$spaAppId = $spaApp.appId

Confirm-ServicePrincipal -AppId $spaAppId | Out-Null

# Pre-authorizing the SPA avoids a consent prompt for the API scope. Graph validates
# delegatedPermissionIds against the stored scopes, so this has to follow the PATCH above.
# Patching `api` replaces the whole complex property, so the scope is re-sent with it.
Invoke-GraphRequest -Method PATCH -Path "applications/$apiObjectId" -Body @{
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @($apiScope)
        preAuthorizedApplications   = @(
            @{ appId = $spaAppId; delegatedPermissionIds = @($apiScopeId) }
        )
    }
}
Write-Host '  SPA pre-authorized for access_as_user'

$existingRedirectUris = @(Get-PropertyOrDefault (Get-PropertyOrDefault $spaApp 'spa') 'redirectUris')
$spaRedirectUris = @(@($SpaRedirectUri) + $AdditionalSpaRedirectUris + $existingRedirectUris |
    Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/') } | Select-Object -Unique)

Invoke-GraphRequest -Method PATCH -Path "applications/$spaObjectId" -Body @{
    spa                    = @{ redirectUris = $spaRedirectUris }
    requiredResourceAccess = @(
        @{ resourceAppId = $apiAppId; resourceAccess = @(@{ id = $apiScopeId; type = 'Scope' }) }
    )
}
Write-Host "  redirect uris $($spaRedirectUris -join ', ') and API permission configured"

Write-Host '==> Granting admin consent (SPA -> API)' -ForegroundColor Cyan
try {
    Invoke-Az -Arguments @('ad', 'app', 'permission', 'admin-consent', '--id', $spaAppId) | Out-Null
    Write-Host '  consented'
}
catch {
    Write-Warning "Could not grant admin consent for SPA -> API. Grant it in the portal (Entra ID > App registrations > API permissions). Details: $_"
}

# -------------------------------------------------------------- app role -----
if ($AssignAdminRoleToCurrentUser) {
    Write-Host '==> Assigning ApplicationAdmin to the current user' -ForegroundColor Cyan
    $me = Invoke-AzJson -Arguments @('ad', 'signed-in-user', 'show')
    $assignments = Invoke-GraphRequest -Method GET -Path "users/$($me.id)/appRoleAssignments"
    $already = (Get-PropertyOrDefault $assignments 'value') |
        Where-Object { $_.appRoleId -eq $adminRoleId -and $_.resourceId -eq $apiSp.id }

    if ($already) {
        Write-Host '  already assigned'
    }
    else {
        Invoke-GraphRequest -Method POST -Path "users/$($me.id)/appRoleAssignments" -Body @{
            principalId = $me.id
            resourceId  = $apiSp.id
            appRoleId   = $adminRoleId
        }
        Write-Host "  assigned to $($me.userPrincipalName)"
    }
}

# ------------------------------------------------- managed identity access ---
if ($ManagedIdentityResourceId) {
    $identity = Invoke-AzJson -Arguments @('identity', 'show', '--ids', $ManagedIdentityResourceId)
    $ManagedIdentityPrincipalId = $identity.principalId
    Write-Host "==> Managed identity $($identity.name)" -ForegroundColor Cyan
}

if ($AssignUserAdministratorRoleToManagedIdentity -and -not $ManagedIdentityPrincipalId) {
    throw 'Pass -ManagedIdentityResourceId, or -ManagedIdentityPrincipalId for a system-assigned identity.'
}

if ($ManagedIdentityPrincipalId) {
    Write-Host '==> Granting Microsoft Graph application permissions to the managed identity' -ForegroundColor Cyan

    $graphSp = Invoke-AzJson -Arguments @('ad', 'sp', 'show', '--id', $GraphAppId)
    $graphAppRoleIds = @{}
    foreach ($role in $graphSp.appRoles) { $graphAppRoleIds[$role.value] = $role.id }

    $existingGrants = (Get-PropertyOrDefault (Invoke-GraphRequest -Method GET -Path "servicePrincipals/$ManagedIdentityPrincipalId/appRoleAssignments") 'value')

    foreach ($permission in $ManagedIdentityGraphAppRoles) {
        if (-not $graphAppRoleIds.ContainsKey($permission)) { throw "Microsoft Graph does not expose application permission '$permission'." }
        $appRoleId = $graphAppRoleIds[$permission]

        if ($existingGrants | Where-Object { $_.appRoleId -eq $appRoleId -and $_.resourceId -eq $graphSp.id }) {
            Write-Host "  $permission already granted"
            continue
        }

        Invoke-GraphRequest -Method POST -Path "servicePrincipals/$ManagedIdentityPrincipalId/appRoleAssignments" -Body @{
            principalId = $ManagedIdentityPrincipalId
            resourceId  = $graphSp.id
            appRoleId   = $appRoleId
        }
        Write-Host "  granted $permission"
    }
    Write-Host '  managed identity tokens are cached for up to 24h; restart the API revision to pick up new grants sooner'
}

if ($AssignUserAdministratorRoleToManagedIdentity) {
    Write-Host '==> Assigning the User Administrator directory role to the managed identity' -ForegroundColor Cyan

    $filter = [uri]::EscapeDataString("principalId eq '$ManagedIdentityPrincipalId' and roleDefinitionId eq '$UserAdministratorRoleId'")
    $existingRole = Invoke-GraphRequest -Method GET -Path "roleManagement/directory/roleAssignments?`$filter=$filter"

    if (@(Get-PropertyOrDefault $existingRole 'value').Count -gt 0) {
        Write-Host '  already assigned'
    }
    else {
        Invoke-GraphRequest -Method POST -Path 'roleManagement/directory/roleAssignments' -Body @{
            principalId      = $ManagedIdentityPrincipalId
            roleDefinitionId = $UserAdministratorRoleId
            directoryScopeId = '/'
        }
        Write-Host '  assigned tenant-wide'
    }
}

# ---------------------------------------------------------------- output -----
$result = [ordered]@{
    tenantId       = $tenantId
    cloud          = $cloud.name
    authorityHost  = $AuthorityHost
    graphBaseUrl   = $GraphApiUrl
    apiClientId    = $apiAppId
    apiObjectId    = $apiObjectId
    apiIdentifier  = "api://$apiAppId"
    apiScope       = "api://$apiAppId/access_as_user"
    apiScopeId     = $apiScopeId
    adminRoleId    = $adminRoleId
    spaClientId    = $spaAppId
    spaObjectId    = $spaObjectId
    spaRedirectUri = $SpaRedirectUri
    apiBaseUrl     = $ApiBaseUrl
}

if ($ManagedIdentityPrincipalId) {
    $result.managedIdentityPrincipalId = $ManagedIdentityPrincipalId
    $result.managedIdentityGraphAppRoles = $ManagedIdentityGraphAppRoles -join ' '
}

$outputFile = Join-Path $PSScriptRoot 'entra-output.json'
$result | ConvertTo-Json -Depth 5 | Set-Content -Path $outputFile -Encoding utf8

Write-Host ''
Write-Host '==> Done' -ForegroundColor Green
$result.GetEnumerator() | ForEach-Object { '{0,-28} {1}' -f $_.Key, $_.Value }
Write-Host ""
Write-Host "Values written to $outputFile (git-ignored)."

if ($ApplyLocalConfig) {
    Write-Host ''
    Write-Host '==> Applying local configuration' -ForegroundColor Cyan

    $environmentFile = Join-Path $WebDir 'src/environments/environment.ts'
    @"
/**
 * Generated by infra/mi-imp/entra/setup-entra.ps1.
 * Nothing here is a secret - the SPA is a public client.
 */
export const environment = {
  tenantId: '$tenantId',
  spaClientId: '$spaAppId',

  /** Entra ID authority host for this cloud, e.g. https://login.microsoftonline.us/ in Azure Government. */
  authorityHost: '$AuthorityHost',

  redirectUri: '$SpaRedirectUri',
  postLogoutRedirectUri: '$SpaRedirectUri',

  /** Scope exposed by the .NET API. */
  apiScopes: ['api://$apiAppId/access_as_user'],

  apiBaseUrl: '$ApiBaseUrl',
};
"@ | Set-Content -Path $environmentFile -Encoding utf8
    Write-Host "  wrote $environmentFile"

    # No secret: locally the API reaches Graph through the `az login` user (see GraphClientRegistration.cs).
    Push-Location $ApiDir
    try {
        & dotnet user-secrets init | Out-Null
        & dotnet user-secrets set 'AzureAd:Instance' $AuthorityHost | Out-Null
        & dotnet user-secrets set 'AzureAd:TenantId' $tenantId | Out-Null
        & dotnet user-secrets set 'AzureAd:ClientId' $apiAppId | Out-Null
        & dotnet user-secrets set 'MicrosoftGraph:BaseUrl' $GraphApiUrl | Out-Null
        Write-Host '  API endpoints, client id and tenant id stored in dotnet user-secrets'
    }
    finally {
        Pop-Location
    }
}
