// Etapa 1: Azure Container Registry.
// Se despliega primero para poder construir las imágenes antes del resto de la infraestructura.
targetScope = 'resourceGroup'

param location string = resourceGroup().location

var suffix = uniqueString(subscription().id, resourceGroup().id)

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acramanda${suffix}'
  location: location
  tags: { project: 'amanda-lab' }
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: true // Simplifica el lab: no requiere role assignments (solo Contributor)
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
