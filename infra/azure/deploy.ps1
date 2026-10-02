<#
.SYNOPSIS
    Provisions the Azure resources with Bicep, builds both apps and deploys them.

.DESCRIPTION
    1. Deploys main.bicep without images (registry, identities, Container Apps environment).
    2. Builds the API image in ACR (no local Docker needed).
    3. Builds the SPA against the deployed URLs and ships it as an nginx image.
    4. Deploys main.bicep again with both images, which creates/updates the container apps.

    Run infra/entra/setup-entra.ps1 in the same cloud and tenant first; this script reads
    infra/entra/entra-output.json. The cloud is whatever `az cloud set` points at.

.EXAMPLE
    ./deploy.ps1

.EXAMPLE
    az cloud set --name AzureUSGovernment; az login
    ./deploy.ps1 -Location usgovvirginia -ResourceGroup rg-aagr-gov
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-aagr',
    [string] $Location = 'eastus2',
    [string] $NamePrefix = 'aagr',
    [string] $ContainerCpu = '0.25',
    [string] $ContainerMemory = '0.5Gi',
    [int] $MaxReplicas = 1,
    [ValidateSet('Basic', 'Standard', 'Premium')]
    [string] $AcrSku = 'Basic',
    [string] $EntraOutputFile = (Join-Path $PSScriptRoot '../entra/entra-output.json')
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ApiDir = Join-Path $RepoRoot 'src/Poc.Api'
$WebDir = Join-Path $RepoRoot 'src/poc-web'
$Template = Join-Path $PSScriptRoot 'main.bicep'

function Invoke-Native {
    param([Parameter(Mandatory)][string] $FilePath, [string[]] $Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

# ARM lookups of a newly created registry intermittently return ResourceNotFound, so builds are retried.
function Invoke-AcrBuild {
    param([Parameter(Mandatory)][string] $Registry, [Parameter(Mandatory)][string] $Image, [Parameter(Mandatory)][string] $Context)
    $maxAttempts = 3
    for ($attempt = 1; ; $attempt++) {
        & az acr build --registry $Registry --image $Image $Context
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -ge $maxAttempts) { throw "az acr build for $Image failed after $maxAttempts attempts." }
        Write-Warning "az acr build failed (attempt $attempt of $maxAttempts), retrying in 20 seconds."
        Start-Sleep -Seconds 20
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $json = & az @Arguments --output json
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed" }
    return $json | ConvertFrom-Json
}

function Get-OperationError {
    param($Operation)
    $err = $Operation.properties.statusMessage.error
    if (-not $err) { return $Operation.properties.statusMessage | ConvertTo-Json -Depth 10 -Compress }
    $inner = @($err.details) | Where-Object { $_.message } | Select-Object -First 1
    if ($inner) { return "$($inner.code): $($inner.message)" }
    return "$($err.code): $($err.message)"
}

# ARM can keep an operation "Running" for hours while the resource itself already reports an error
# (e.g. Container Apps environment capacity errors), so in-flight resources are checked directly.
function Get-InFlightResourceError {
    param([Parameter(Mandatory)][string] $ResourceId)
    $json = & az resource show --ids $ResourceId --query '{state: properties.provisioningState, errors: properties.deploymentErrors}' --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $resource = $json | ConvertFrom-Json
    if ($resource.errors) { return [string]$resource.errors }
    if ($resource.state -eq 'Failed') { return 'Resource provisioning state is Failed.' }
    return $null
}

function Watch-Deployment {
    param([Parameter(Mandatory)][string] $Name)

    $stateColors = @{ Succeeded = 'Green'; Failed = 'Red'; Canceled = 'Yellow' }
    $lastState = @{}
    $started = Get-Date

    while ($true) {
        Start-Sleep -Seconds 5
        $elapsed = '{0:mm\:ss}' -f ((Get-Date) - $started)

        $opsJson = & az deployment operation group list --resource-group $ResourceGroup --name $Name --output json 2>$null
        $operations = if ($LASTEXITCODE -eq 0 -and $opsJson) { @($opsJson | ConvertFrom-Json) } else { @() }

        foreach ($op in $operations | Where-Object { $_.properties.targetResource }) {
            $target = $op.properties.targetResource
            $key = "$($target.resourceType)/$($target.resourceName)"
            $state = $op.properties.provisioningState
            if ($lastState[$key] -eq $state) { continue }
            $lastState[$key] = $state

            $color = if ($stateColors.ContainsKey($state)) { $stateColors[$state] } else { 'Gray' }
            Write-Host ('  [{0}] {1,-10} {2,-55} {3}' -f $elapsed, $state, $target.resourceType, $target.resourceName) -ForegroundColor $color
            if ($state -eq 'Failed') { Write-Host "             $(Get-OperationError $op)" -ForegroundColor Red }
        }

        $running = $operations | Where-Object { $_.properties.targetResource -and $_.properties.provisioningState -eq 'Running' }
        foreach ($op in $running) {
            $target = $op.properties.targetResource
            if ($target.resourceType -eq 'Microsoft.Resources/deployments') { continue }
            $resourceError = Get-InFlightResourceError -ResourceId $target.id
            if (-not $resourceError) { continue }

            Write-Host ('  [{0}] {1,-10} {2,-55} {3}' -f $elapsed, 'Error', $target.resourceType, $target.resourceName) -ForegroundColor Red
            Write-Host "             $resourceError" -ForegroundColor Red
            Write-Host '  cancelling deployment' -ForegroundColor Yellow
            & az deployment group cancel --resource-group $ResourceGroup --name $Name 2>$null
            throw "Deployment '$Name' stopped: $($target.resourceName) reported an error while provisioning."
        }

        $overall = & az deployment group show --resource-group $ResourceGroup --name $Name --query 'properties.provisioningState' --output tsv 2>$null
        if ($overall -in 'Succeeded', 'Failed', 'Canceled') {
            Write-Host "  [$elapsed] deployment $overall" -ForegroundColor $stateColors[$overall]
            if ($overall -ne 'Succeeded') { throw "Deployment '$Name' $($overall.ToLower()). See the failed resources above." }
            return
        }
    }
}

function Deploy-Infrastructure {
    param([string] $ApiImage = '', [string] $SpaImage = '')

    $parameters = @(
        "namePrefix=$NamePrefix"
        "location=$Location"
        "entraTenantId=$($entra.tenantId)"
        "apiClientId=$($entra.apiClientId)"
        "authorityHost=$($entra.authorityHost)"
        "graphBaseUrl=$($entra.graphBaseUrl)"
        "containerCpu=$ContainerCpu"
        "containerMemory=$ContainerMemory"
        "maxReplicas=$MaxReplicas"
        "acrSku=$AcrSku"
        "apiImage=$ApiImage"
        "spaImage=$SpaImage"
    )
    $deploymentName = "$NamePrefix-infra"

    # --no-wait returns once ARM accepts the deployment, so per-resource progress can be polled.
    Invoke-Native az (@(
            'deployment', 'group', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $deploymentName,
            '--template-file', $Template,
            '--no-wait',
            '--parameters') + $parameters)

    Watch-Deployment -Name $deploymentName

    $result = Invoke-AzJson -Arguments @(
        'deployment', 'group', 'show',
        '--resource-group', $ResourceGroup,
        '--name', $deploymentName,
        '--query', 'properties.outputs')

    $outputs = @{}
    foreach ($p in $result.PSObject.Properties) { $outputs[$p.Name] = $p.Value.value }
    return $outputs
}

Write-Host '==> Checking Azure CLI sign-in' -ForegroundColor Cyan
$account = Invoke-AzJson -Arguments @('account', 'show')
$cloud = Invoke-AzJson -Arguments @('cloud', 'show')
Write-Host "  cloud        : $($cloud.name)"
Write-Host "  subscription : $($account.name) ($($account.id))"

if (-not (Test-Path $EntraOutputFile)) { throw "Missing $EntraOutputFile. Run infra/entra/setup-entra.ps1 first." }
$entra = Get-Content $EntraOutputFile -Raw | ConvertFrom-Json
if ($entra.cloud -and $entra.cloud -ne $cloud.name) {
    throw "entra-output.json was produced for cloud '$($entra.cloud)' but the CLI is on '$($cloud.name)'. Re-run setup-entra.ps1 in this cloud."
}
if ($entra.tenantId -ne $account.tenantId) {
    Write-Warning "Subscription tenant $($account.tenantId) differs from the app registration tenant $($entra.tenantId)."
}

Write-Host "==> Resource group $ResourceGroup ($Location)" -ForegroundColor Cyan
Invoke-Native az @('group', 'create', '--name', $ResourceGroup, '--location', $Location, '--output', 'none')

Write-Host '==> Deploying shared infrastructure' -ForegroundColor Cyan
$infra = Deploy-Infrastructure
Write-Host "  registry : $($infra.acrLoginServer)"
Write-Host "  api url  : $($infra.apiUrl)"
Write-Host "  spa url  : $($infra.spaUrl)"

$tag = Get-Date -Format 'yyyyMMddHHmmss'
$apiImage = "$($infra.acrLoginServer)/poc-api:$tag"

Write-Host "==> Building API image $apiImage" -ForegroundColor Cyan
Invoke-AcrBuild -Registry $infra.acrName -Image "poc-api:$tag" -Context $ApiDir

Write-Host '==> Building SPA' -ForegroundColor Cyan
$environmentDir = Join-Path $WebDir 'src/environments'
$localEnvironment = Join-Path $environmentDir 'environment.ts'
if (-not (Test-Path $localEnvironment)) {
    # The azure configuration replaces environment.ts, so the file only has to exist.
    Copy-Item (Join-Path $environmentDir 'environment.sample.ts') $localEnvironment
}

@"
/**
 * Generated by infra/azure/deploy.ps1 for the deployed environment.
 * Nothing here is a secret - the SPA is a public client.
 */
export const environment = {
  tenantId: '$($entra.tenantId)',
  spaClientId: '$($entra.spaClientId)',
  authorityHost: '$($entra.authorityHost)',
  redirectUri: '$($infra.spaUrl)',
  postLogoutRedirectUri: '$($infra.spaUrl)',
  apiScopes: ['$($entra.apiScope)'],
  apiBaseUrl: '$($infra.apiUrl)/api',
};
"@ | Set-Content -Path (Join-Path $environmentDir 'environment.azure.ts') -Encoding utf8

Push-Location $WebDir
try {
    if (-not (Test-Path 'node_modules')) { Invoke-Native npm @('ci') }
    Invoke-Native npx @('ng', 'build', '--configuration', 'production,azure')
}
finally {
    Pop-Location
}

$spaImage = "$($infra.acrLoginServer)/poc-web:$tag"
Write-Host "==> Building SPA image $spaImage" -ForegroundColor Cyan
Invoke-AcrBuild -Registry $infra.acrName -Image "poc-web:$tag" -Context $WebDir

Write-Host '==> Deploying container apps' -ForegroundColor Cyan
$infra = Deploy-Infrastructure -ApiImage $apiImage -SpaImage $spaImage

Write-Host ''
Write-Host '==> Done' -ForegroundColor Green
Write-Host "  SPA : $($infra.spaUrl)"
Write-Host "  API : $($infra.apiUrl)/api"
Write-Host ''
Write-Host 'If not done yet for this deployment, trust the managed identity and register the SPA URL (needs Entra admin rights):' -ForegroundColor Yellow
Write-Host "  cd infra/entra"
Write-Host "  ./setup-entra.ps1 -ApplyLocalConfig -ConfigureFederatedCredential ``"
Write-Host "      -ManagedIdentityResourceId $($infra.apiIdentityResourceId) ``"
Write-Host "      -AdditionalSpaRedirectUris $($infra.spaUrl)"
