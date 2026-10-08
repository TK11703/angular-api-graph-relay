param name string
param location string
param tags object = {}
param environmentId string
@description('User-assigned identities attached to the app.')
param identityIds array
@description('Identity used to pull from the registry; must also be in identityIds.')
param registryIdentityId string
param registryServer string
param image string
param targetPort int = 8080
param cpu string
param memory string
param minReplicas int
param maxReplicas int
param env array = []

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: toObject(identityIds, id => id, id => {})
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: registryServer
          identity: registryIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: name
          image: image
          env: env
          resources: {
            cpu: json(cpu)
            memory: memory
          }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
