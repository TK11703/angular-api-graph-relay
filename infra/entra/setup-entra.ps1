<#
.SYNOPSIS
    Creates the two Entra ID app registrations this PoC needs.

.DESCRIPTION
    App 1 - "PoC API" (confidential client)
        * exposes the delegated scope  access_as_user
        * defines the app role         ApplicationAdmin
        * holds delegated Microsoft Graph permissions used by the on-behalf-of flow
        * gets a client secret so it can redeem the OBO token locally, and optionally a
          federated identity credential so a managed identity replaces that secret when hosted

    App 2 - "PoC SPA" (public client)
        * SPA redirect URI for the Angular dev server
        * permission to call the API's access_as_user scope (pre-authorized, so no second consent prompt)

    The script is idempotent: re-running it reuses existing registrations and their
    scope / app-role identifiers.

.NOTES
    Requires the Application Administrator role (to create apps) and
    Privileged Role Administrator / Global Administrator (to grant admin consent).

.EXAMPLE
    ./setup-entra.ps1 -AssignAdminRoleToCurrentUser -ApplyLocalConfig

.EXAMPLE
    ./setup-entra.ps1 -ConfigureFederatedCredential -ManagedIdentityResourceId /subscriptions/.../userAssignedIdentities/poc-api
#>
[CmdletBinding()]
param(
    [string] $ApiAppName = 'PoC API',
    [string] $SpaAppName = 'PoC SPA',
    [string] $SpaRedirectUri = 'http://localhost:4200',
    [string] $ApiBaseUrl = 'https://localhost:7182/api',

    # Sovereign-cloud endpoints. Left empty, both are read from the CLI's active cloud
    # (`az cloud show`), so `az cloud set --name AzureUSGovernment` is normally enough.
    [string] $GraphResourceUrl,
    [string] $AuthorityHost,
    [string] $GraphApiVersion = 'v1.0',

    # Grants the current signed-in user the ApplicationAdmin app role.
    [switch] $AssignAdminRoleToCurrentUser,

    # Registers a managed identity as a federated credential on the API app, so the deployed
    # API can drop the client secret. Supply the user-assigned identity's resource id, or the
    # principal id directly (required for a system-assigned identity).
    [switch] $ConfigureFederatedCredential,
    [string] $ManagedIdentityResourceId,
    [string] $ManagedIdentityPrincipalId,
    [string] $ManagedIdentityClientId,
    [string] $FederatedCredentialName = 'poc-api-managed-identity',
    [string] $FederatedAudience,

    # Writes the resulting ids into src/poc-web/.../environment.ts and the API user-secrets.
    [switch] $ApplyLocalConfig
)

$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# The Graph first-party app id is identical in every cloud; only the endpoints differ.
$GraphAppId = '00000003-0000-0000-c000-000000000000'
$GraphDelegatedPermissions = @('openid', 'profile', 'offline_access', 'User.Read', 'User.Read.All', 'GroupMember.Read.All')

# Workload identity federation uses a different token-exchange audience per cloud.
$TokenExchangeAudiences = @{
    'AzureCloud'        = 'api://AzureADTokenExchange'
    'AzureUSGovernment' = 'api://AzureADTokenExchangeUSGov'
    'AzureChinaCloud'   = 'api://AzureADTokenExchangeChina'
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

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

Write-Host '==> Resolving Microsoft Graph delegated permission ids' -ForegroundColor Cyan
$graphSp = Invoke-AzJson -Arguments @('ad', 'sp', 'show', '--id', $GraphAppId)
$graphScopeIds = @{}
foreach ($scope in $graphSp.oauth2PermissionScopes) { $graphScopeIds[$scope.value] = $scope.id }

$graphResourceAccess = foreach ($permission in $GraphDelegatedPermissions) {
    if (-not $graphScopeIds.ContainsKey($permission)) { throw "Microsoft Graph does not expose delegated permission '$permission'." }
    @{ id = $graphScopeIds[$permission]; type = 'Scope' }
}

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
            description        = 'Can query Entra ID information for other users in the tenant.'
            allowedMemberTypes = @('User')
            isEnabled          = $true
        }
    )
    requiredResourceAccess = @(
        @{ resourceAppId = $GraphAppId; resourceAccess = @($graphResourceAccess) }
    )
}
Write-Host '  identifier uri, access_as_user scope, ApplicationAdmin role and Graph permissions configured'

$apiSp = Confirm-ServicePrincipal -AppId $apiAppId

Write-Host '  resetting client secret'
$secret = Invoke-AzJson -Arguments @(
    'ad', 'app', 'credential', 'reset',
    '--id', $apiAppId,
    '--display-name', 'poc-api-obo',
    '--years', '1'
)

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

# Pre-authorizing the SPA avoids a second consent prompt for the API scope. Graph validates
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

Invoke-GraphRequest -Method PATCH -Path "applications/$spaObjectId" -Body @{
    spa                    = @{ redirectUris = @($SpaRedirectUri) }
    requiredResourceAccess = @(
        @{ resourceAppId = $apiAppId; resourceAccess = @(@{ id = $apiScopeId; type = 'Scope' }) }
    )
}
Write-Host "  redirect uri $SpaRedirectUri and API permission configured"

# ----------------------------------------------------------- admin consent ---
Write-Host '==> Granting admin consent' -ForegroundColor Cyan
foreach ($target in @(@{ Name = 'API -> Microsoft Graph'; Id = $apiAppId }, @{ Name = 'SPA -> API'; Id = $spaAppId })) {
    try {
        Invoke-Az -Arguments @('ad', 'app', 'permission', 'admin-consent', '--id', $target.Id) | Out-Null
        Write-Host "  consented: $($target.Name)"
    }
    catch {
        Write-Warning "Could not grant admin consent for $($target.Name). Grant it in the portal (Entra ID > App registrations > API permissions). Details: $_"
    }
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

# ------------------------------------------------------ federated credential --
if ($ConfigureFederatedCredential) {
    Write-Host '==> Configuring federated identity credential' -ForegroundColor Cyan

    if ($ManagedIdentityResourceId) {
        $identity = Invoke-AzJson -Arguments @('identity', 'show', '--ids', $ManagedIdentityResourceId)
        $ManagedIdentityPrincipalId = $identity.principalId
        $ManagedIdentityClientId = $identity.clientId
        Write-Host "  resolved $($identity.name)"
    }

    if (-not $ManagedIdentityPrincipalId) {
        throw 'Pass -ManagedIdentityResourceId, or -ManagedIdentityPrincipalId for a system-assigned identity.'
    }

    if (-not $FederatedAudience) {
        $FederatedAudience = $TokenExchangeAudiences[$cloud.name]
        if (-not $FederatedAudience) { throw "No token-exchange audience known for cloud '$($cloud.name)'. Pass -FederatedAudience." }
    }

    # The subject is the identity's principal (object) id, not its client id.
    $credential = @{
        name        = $FederatedCredentialName
        issuer      = "$AuthorityHost$tenantId/v2.0"
        subject     = $ManagedIdentityPrincipalId
        audiences   = @($FederatedAudience)
        description = 'Managed identity acting as this app, replacing the client secret.'
    }

    $existingCredentials = Invoke-GraphRequest -Method GET -Path "applications/$apiObjectId/federatedIdentityCredentials"
    $match = (Get-PropertyOrDefault $existingCredentials 'value') |
        Where-Object { $_.name -eq $FederatedCredentialName } | Select-Object -First 1

    if ($match) {
        # name is immutable, so it is omitted from the update.
        Invoke-GraphRequest -Method PATCH -Path "applications/$apiObjectId/federatedIdentityCredentials/$($match.id)" -Body @{
            issuer      = $credential.issuer
            subject     = $credential.subject
            audiences   = $credential.audiences
            description = $credential.description
        }
        Write-Host "  updated credential '$FederatedCredentialName'"
    }
    else {
        Invoke-GraphRequest -Method POST -Path "applications/$apiObjectId/federatedIdentityCredentials" -Body $credential
        Write-Host "  created credential '$FederatedCredentialName'"
    }

    Write-Host "  issuer   : $($credential.issuer)"
    Write-Host "  subject  : $ManagedIdentityPrincipalId"
    Write-Host "  audience : $FederatedAudience"
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

if ($ConfigureFederatedCredential) {
    $result.federatedCredential = $FederatedCredentialName
    $result.managedIdentityPrincipalId = $ManagedIdentityPrincipalId
    if ($ManagedIdentityClientId) { $result.managedIdentityClientId = $ManagedIdentityClientId }
}

$outputFile = Join-Path $PSScriptRoot 'entra-output.json'
$result | ConvertTo-Json -Depth 5 | Set-Content -Path $outputFile -Encoding utf8

Write-Host ''
Write-Host '==> Done' -ForegroundColor Green
$result.GetEnumerator() | ForEach-Object { '{0,-26} {1}' -f $_.Key, $_.Value }
Write-Host ""
Write-Host "Values written to $outputFile (git-ignored)."

if ($ConfigureFederatedCredential) {
    Write-Host ''
    Write-Host 'Set these on the deployed API (appsettings.Production.json is already wired for it):' -ForegroundColor Yellow
    Write-Host "  AzureAd__Instance = $AuthorityHost"
    Write-Host "  AzureAd__TenantId = $tenantId"
    Write-Host "  AzureAd__ClientId = $apiAppId"
    Write-Host "  MicrosoftGraph__BaseUrl = $GraphApiUrl"
    if ($ManagedIdentityClientId) {
        Write-Host "  AzureAd__ClientCredentials__0__ManagedIdentityClientId = $ManagedIdentityClientId"
    }
    else {
        Write-Host '  Remove ManagedIdentityClientId from appsettings.Production.json for a system-assigned identity.'
    }
}

if ($ApplyLocalConfig) {
    Write-Host ''
    Write-Host '==> Applying local configuration' -ForegroundColor Cyan

    $environmentFile = Join-Path $RepoRoot 'src/poc-web/src/environments/environment.ts'
    @"
/**
 * Generated by infra/entra/setup-entra.ps1.
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

    Push-Location (Join-Path $RepoRoot 'src/Poc.Api')
    try {
        & dotnet user-secrets init | Out-Null
        & dotnet user-secrets set 'AzureAd:Instance' $AuthorityHost | Out-Null
        & dotnet user-secrets set 'AzureAd:TenantId' $tenantId | Out-Null
        & dotnet user-secrets set 'AzureAd:ClientId' $apiAppId | Out-Null
        & dotnet user-secrets set 'AzureAd:ClientCredentials:0:SourceType' 'ClientSecret' | Out-Null
        & dotnet user-secrets set 'AzureAd:ClientCredentials:0:ClientSecret' $secret.password | Out-Null
        & dotnet user-secrets set 'MicrosoftGraph:BaseUrl' $GraphApiUrl | Out-Null
        Write-Host '  API endpoints, client id / tenant id / client secret stored in dotnet user-secrets'
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host ''
    Write-Host 'Store the API client secret (shown once) with:' -ForegroundColor Yellow
    Write-Host "  cd src/Poc.Api"
    Write-Host "  dotnet user-secrets init"
    Write-Host "  dotnet user-secrets set `"AzureAd:Instance`" `"$AuthorityHost`""
    Write-Host "  dotnet user-secrets set `"AzureAd:TenantId`" `"$tenantId`""
    Write-Host "  dotnet user-secrets set `"AzureAd:ClientId`" `"$apiAppId`""
    Write-Host "  dotnet user-secrets set `"AzureAd:ClientCredentials:0:SourceType`" `"ClientSecret`""
    Write-Host "  dotnet user-secrets set `"AzureAd:ClientCredentials:0:ClientSecret`" `"$($secret.password)`""
    Write-Host "  dotnet user-secrets set `"MicrosoftGraph:BaseUrl`" `"$GraphApiUrl`""
}
