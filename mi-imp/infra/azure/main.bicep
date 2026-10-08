// Deployed into the apps resource group (rg-apps). The Container Apps environment, its Log Analytics
// workspace, the registry and the ACR-pull identity are shared and only referenced here.
targetScope = 'resourceGroup'

@description('Prefix for resource names. Lowercase letters, digits and hyphens.')
@minLength(2)
@maxLength(12)
param namePrefix string = 'aagrmi'

@description('Must match the location of the shared Container Apps environment.')
param location string = 'northcentralus'

@description('Existing Container Apps environment in this resource group (already wired to its Log Analytics workspace).')
param containerAppsEnvironmentName string = 'cae-shared'

@description('Resource group holding the shared container registry and ACR-pull identity.')
param platformResourceGroupName string = 'rg-platform'

param containerRegistryName string = 'acccrshared'

@description('Existing user-assigned identity in the platform resource group that holds AcrPull on the registry.')
param acrPullIdentityName string = 'id-shared-acrpull'

@description('Tenant that holds the PoC API app registration.')
param entraTenantId string = tenant().tenantId

@description('Client id of the PoC API (MI) app registration. Used only to validate inbound tokens.')
param apiClientId string

param authorityHost string = environment().authentication.loginEndpoint

param graphBaseUrl string = environment().name == 'AzureUSGovernment'
  ? 'https://graph.microsoft.us/v1.0'
  : 'https://graph.microsoft.com/v1.0'

@description('Full API image reference. Empty deploys only the app identities (first pass, before images exist).')
param apiImage string = ''

@description('Full SPA (nginx) image reference. Empty skips the SPA container app.')
param spaImage string = ''

@description('vCPU per replica. Must pair with containerMemory: 0.25/0.5Gi, 0.5/1Gi, 1/2Gi, ...')
param containerCpu string = '0.25'
param containerMemory string = '0.5Gi'

@minValue(0)
param minReplicas int = 0

@minValue(1)
param maxReplicas int = 1

param tags object = {}

var apiAppName = 'ca-${namePrefix}-api'
var spaAppName = 'ca-${namePrefix}-spa'

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
  scope: resourceGroup(platformResourceGroupName)
}

resource acrPullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: acrPullIdentityName
  scope: resourceGroup(platformResourceGroupName)
}

// Per-app identities live in rg-apps so their ids and Graph/Entra grants survive Container App replacement.
resource apiIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}-api'
  location: location
  tags: tags
}

resource spaIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}-spa'
  location: location
  tags: tags
}

// Known before the apps exist, so the SPA can be built against them in the first pass.
var apiUrl = 'https://${apiAppName}.${containerEnv.properties.defaultDomain}'
var spaUrl = 'https://${spaAppName}.${containerEnv.properties.defaultDomain}'

module apiApp 'modules/container-app.bicep' = if (!empty(apiImage)) {
  name: 'container-app-api'
  params: {
    name: apiAppName
    location: location
    tags: tags
    environmentId: containerEnv.id
    identityIds: [apiIdentity.id, acrPullIdentity.id]
    registryIdentityId: acrPullIdentity.id
    registryServer: registry.properties.loginServer
    image: apiImage
    cpu: containerCpu
    memory: containerMemory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    env: [
      { name: 'AzureAd__Instance', value: authorityHost }
      { name: 'AzureAd__TenantId', value: entraTenantId }
      { name: 'AzureAd__ClientId', value: apiClientId }
      { name: 'ManagedIdentity__ClientId', value: apiIdentity.properties.clientId }
      { name: 'MicrosoftGraph__BaseUrl', value: graphBaseUrl }
      { name: 'Cors__AllowedOrigins__0', value: spaUrl }
    ]
  }
}

module spaApp 'modules/container-app.bicep' = if (!empty(spaImage)) {
  name: 'container-app-spa'
  params: {
    name: spaAppName
    location: location
    tags: tags
    environmentId: containerEnv.id
    identityIds: [spaIdentity.id, acrPullIdentity.id]
    registryIdentityId: acrPullIdentity.id
    registryServer: registry.properties.loginServer
    image: spaImage
    cpu: containerCpu
    memory: containerMemory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
  }
}

output acrName string = registry.name
output acrLoginServer string = registry.properties.loginServer
output apiUrl string = apiUrl
output spaUrl string = spaUrl
output apiIdentityResourceId string = apiIdentity.id
output apiIdentityClientId string = apiIdentity.properties.clientId
output apiIdentityPrincipalId string = apiIdentity.properties.principalId
