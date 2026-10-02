targetScope = 'resourceGroup'

@description('Prefix for resource names. Lowercase letters, digits and hyphens.')
@minLength(2)
@maxLength(12)
param namePrefix string = 'aagrmi'

param location string = resourceGroup().location

@description('Tenant that holds the PoC API app registration.')
param entraTenantId string = tenant().tenantId

@description('Client id of the PoC API (MI) app registration. Used only to validate inbound tokens.')
param apiClientId string

param authorityHost string = environment().authentication.loginEndpoint

param graphBaseUrl string = environment().name == 'AzureUSGovernment'
  ? 'https://graph.microsoft.us/v1.0'
  : 'https://graph.microsoft.com/v1.0'

@description('Full API image reference. Empty deploys only the shared infrastructure (first pass, before images exist).')
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

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param acrSku string = 'Basic'

@minValue(30)
param logRetentionDays int = 30

param tags object = {}

var apiAppName = '${namePrefix}-api'
var spaAppName = '${namePrefix}-spa'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource logs 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${namePrefix}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: logRetentionDays
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: '${replace(namePrefix, '-', '')}${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: acrSku }
  properties: {
    adminUserEnabled: false
  }
}

resource apiIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-api-id'
  location: location
  tags: tags
}

resource spaIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-spa-id'
  location: location
  tags: tags
}

resource apiAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, apiIdentity.id, acrPullRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: apiIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource spaAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, spaIdentity.id, acrPullRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: spaIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${namePrefix}-env'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
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
    identityId: apiIdentity.id
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
  dependsOn: [
    apiAcrPull
  ]
}

module spaApp 'modules/container-app.bicep' = if (!empty(spaImage)) {
  name: 'container-app-spa'
  params: {
    name: spaAppName
    location: location
    tags: tags
    environmentId: containerEnv.id
    identityId: spaIdentity.id
    registryServer: registry.properties.loginServer
    image: spaImage
    cpu: containerCpu
    memory: containerMemory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
  }
  dependsOn: [
    spaAcrPull
  ]
}

output acrName string = registry.name
output acrLoginServer string = registry.properties.loginServer
output apiUrl string = apiUrl
output spaUrl string = spaUrl
output apiIdentityResourceId string = apiIdentity.id
output apiIdentityClientId string = apiIdentity.properties.clientId
output apiIdentityPrincipalId string = apiIdentity.properties.principalId
