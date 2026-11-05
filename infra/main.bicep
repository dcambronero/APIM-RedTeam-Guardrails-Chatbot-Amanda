// =====================================================================
//  Amanda Lab · Fase I
//  APIM (AI Gateway) -> Agente (Container App) -> Azure OpenAI / AI Search / Tools
//  Diseñado para desplegarse SOLO con rol Contributor sobre el Resource Group
//  (no crea role assignments: usa keys guardadas como secretos).
// =====================================================================
targetScope = 'resourceGroup'

@description('Región de los recursos')
param location string = resourceGroup().location

@description('Email del publisher de APIM (obligatorio)')
param publisherEmail string

param publisherName string = 'Amanda Lab'

@description('Nombre del ACR creado por acr.bicep')
param acrName string

@description('Imagen completa del agente, ej. acrxxx.azurecr.io/amanda-agent:sha')
param agentImage string

@description('Imagen completa del servicio de tools')
param toolsImage string

// ---- Modelos -------------------------------------------------------
@description('Modelo de chat. gpt-4o-mini está en deprecación y no admite deployments nuevos')
param chatModelName string = 'gpt-5.4-mini'
param chatModelVersion string = '2026-03-17'
param chatDeploymentSku string = 'GlobalStandard'
@description('Capacidad en miles de tokens por minuto')
param chatCapacity int = 50

param embedModelName string = 'text-embedding-3-small'
param embedModelVersion string = '1'
param embedDeploymentSku string = 'Standard'
param embedCapacity int = 50

// ---- AI Search -----------------------------------------------------
@allowed([ 'free', 'basic' ])
param searchSku string = 'basic'
@description('Permite usar otra región si AI Search no tiene capacidad en la principal')
param searchLocation string = location

// ---- Secretos internos ---------------------------------------------
// El workflow los pasa SIEMPRE (reutiliza los existentes) para que no cambien en cada despliegue.
@secure()
@description('Header secreto que APIM inyecta hacia los backends')
param backendKey string = newGuid()

@secure()
@description('Subscription key de APIM que usa el agente para /openai, /rag y /tools')
param agentApimKey string = newGuid()

var suffix = uniqueString(subscription().id, resourceGroup().id)
var tags = { project: 'amanda-lab' }
var names = {
  law: 'law-amanda-${suffix}'
  appi: 'appi-amanda-${suffix}'
  aoai: 'aoai-amanda-${suffix}'
  search: 'srch-amanda-${suffix}'
  cae: 'cae-amanda-${suffix}'
  agent: 'ca-amanda-agent'
  tools: 'ca-amanda-tools'
  apim: 'apim-amanda-${suffix}'
}
var searchIndex = 'amanda-kb'
var aoaiApiVersion = '2025-04-01-preview' // requerido por la familia gpt-5

// Si cambian las keys, cambia este valor y Container Apps crea una revisión nueva
// (cambiar solo un secret NO reinicia la app y la key vieja queda en memoria).
var secretsVersion = uniqueString(backendKey, agentApimKey)

// =====================================================================
//  Observabilidad
// =====================================================================
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.law
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: names.appi
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// =====================================================================
//  Azure OpenAI
// =====================================================================
resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: names.aoai
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: names.aoai
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoai
  name: chatModelName
  sku: {
    name: chatDeploymentSku
    capacity: chatCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: chatModelName
      version: chatModelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

// Los deployments de un mismo account se crean en serie
resource embedDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoai
  name: embedModelName
  sku: {
    name: embedDeploymentSku
    capacity: embedCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embedModelName
      version: embedModelVersion
    }
  }
  dependsOn: [ chatDeployment ]
}

// =====================================================================
//  Azure AI Search (RAG)
// =====================================================================
resource search 'Microsoft.Search/searchServices@2023-11-01' = {
  name: names.search
  location: searchLocation
  tags: tags
  sku: { name: searchSku }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
  }
}

// =====================================================================
//  Container Apps (agente + tools) y APIM
// =====================================================================
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: names.cae
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: names.apim
  location: location
  tags: tags
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource toolsApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: names.tools
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      ingress: {
        external: true // APIM Basic v2 llega por internet; el backend exige x-backend-key
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        { name: 'acr-password', value: acr.listCredentials().passwords[0].value }
        { name: 'backend-key', value: backendKey }
      ]
    }
    template: {
      containers: [
        {
          name: 'tools'
          image: toolsImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'BACKEND_KEY', secretRef: 'backend-key' }
            { name: 'SECRETS_VERSION', value: secretsVersion }
          ]
        }
      ]
      // 1 réplica: el estado (saldos, auditoría) vive en memoria
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

resource agentApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: names.agent
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        { name: 'acr-password', value: acr.listCredentials().passwords[0].value }
        { name: 'backend-key', value: backendKey }
        { name: 'apim-key', value: agentApimKey }
      ]
    }
    template: {
      containers: [
        {
          name: 'agent'
          image: agentImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'APIM_GATEWAY_URL', value: apim.properties.gatewayUrl }
            { name: 'APIM_KEY', secretRef: 'apim-key' }
            { name: 'BACKEND_KEY', secretRef: 'backend-key' }
            { name: 'CHAT_DEPLOYMENT', value: chatModelName }
            { name: 'EMBED_DEPLOYMENT', value: embedModelName }
            { name: 'AOAI_API_VERSION', value: aoaiApiVersion }
            { name: 'SEARCH_INDEX', value: searchIndex }
            { name: 'SECRETS_VERSION', value: secretsVersion }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

// =====================================================================
//  APIM: named values, logging, APIs y políticas
// =====================================================================
resource nvAoaiKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'aoai-key'
  properties: {
    displayName: 'aoai-key'
    secret: true
    value: aoai.listKeys().key1
  }
}

resource nvSearchKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'search-query-key'
  properties: {
    displayName: 'search-query-key'
    secret: true
    value: search.listQueryKeys().value[0].key // key de solo lectura
  }
}

resource nvBackendKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'backend-key'
  properties: {
    displayName: 'backend-key'
    secret: true
    value: backendKey
  }
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appi.id
    credentials: {
      instrumentationKey: appi.properties.InstrumentationKey
    }
  }
}

// Sin logging de body: rompería el streaming (SSE)
resource apimDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    logClientIp: true
    verbosity: 'information'
    httpCorrelationProtocol: 'W3C'
    sampling: { samplingType: 'fixed', percentage: 100 }
  }
}

// ---------- API pública: /amanda (UI + chat OpenAI-compatible) -------
resource apiAmanda 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'amanda'
  properties: {
    displayName: 'Amanda Chat (público)'
    path: 'amanda'
    protocols: [ 'https' ]
    serviceUrl: 'https://${agentApp.properties.configuration.ingress.fqdn}'
    subscriptionRequired: false
  }
}

resource apiAmandaPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: apiAmanda
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policies/amanda-api.xml')
  }
  dependsOn: [ nvBackendKey ]
}

resource opAmandaRoot 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiAmanda
  name: 'get-root'
  properties: { displayName: 'UI', method: 'GET', urlTemplate: '/' }
}

resource opAmandaGet 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiAmanda
  name: 'get-any'
  properties: { displayName: 'GET *', method: 'GET', urlTemplate: '/*' }
}

resource opAmandaPost 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiAmanda
  name: 'chat-completions'
  properties: { displayName: 'Chat completions', method: 'POST', urlTemplate: '/v1/chat/completions' }
}

// ---------- API interna: /openai (modelo) ---------------------------
resource apiOpenAI 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'openai'
  properties: {
    displayName: 'Azure OpenAI (interno)'
    path: 'openai'
    protocols: [ 'https' ]
    serviceUrl: '${aoai.properties.endpoint}openai'
    subscriptionRequired: true
    subscriptionKeyParameterNames: { header: 'api-key', query: 'api-key' }
  }
}

resource apiOpenAIPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: apiOpenAI
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policies/openai-api.xml')
  }
  dependsOn: [ nvAoaiKey ]
}

resource opOpenAIChat 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiOpenAI
  name: 'chat-completions'
  properties: {
    displayName: 'Chat completions'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/chat/completions'
    templateParameters: [ { name: 'deployment-id', type: 'string', required: true } ]
  }
}

resource opOpenAIEmbed 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiOpenAI
  name: 'embeddings'
  properties: {
    displayName: 'Embeddings'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/embeddings'
    templateParameters: [ { name: 'deployment-id', type: 'string', required: true } ]
  }
}

// ---------- API interna: /rag (AI Search) ---------------------------
resource apiRag 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'rag'
  properties: {
    displayName: 'RAG - AI Search (interno)'
    path: 'rag'
    protocols: [ 'https' ]
    serviceUrl: 'https://${search.name}.search.windows.net'
    subscriptionRequired: true
  }
}

resource apiRagPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: apiRag
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policies/rag-api.xml')
  }
  dependsOn: [ nvSearchKey ]
}

resource opRagSearch 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiRag
  name: 'search'
  properties: {
    displayName: 'Search documents'
    method: 'POST'
    urlTemplate: '/indexes/{index}/docs/search'
    templateParameters: [ { name: 'index', type: 'string', required: true } ]
  }
}

// ---------- API interna: /tools --------------------------------------
resource apiTools 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'tools'
  properties: {
    displayName: 'Banco Aurora Tools (interno)'
    path: 'tools'
    protocols: [ 'https' ]
    serviceUrl: 'https://${toolsApp.properties.configuration.ingress.fqdn}'
    subscriptionRequired: true
  }
}

resource apiToolsPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: apiTools
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policies/tools-api.xml')
  }
  dependsOn: [ nvBackendKey ]
}

resource opToolsInvoke 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiTools
  name: 'invoke-tool'
  properties: {
    displayName: 'Invoke tool'
    method: 'POST'
    urlTemplate: '/{tool}'
    templateParameters: [ { name: 'tool', type: 'string', required: true } ]
  }
}

resource opToolsAudit 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiTools
  name: 'audit'
  properties: { displayName: 'Audit log', method: 'GET', urlTemplate: '/audit' }
}

// ---------- Subscription que usa el agente ---------------------------
resource agentSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'amanda-agent'
  properties: {
    displayName: 'Amanda agent (interno)'
    scope: '${apim.id}/apis'
    primaryKey: agentApimKey
    state: 'active'
  }
}

// =====================================================================
//  Outputs
// =====================================================================
output chatUrl string = '${apim.properties.gatewayUrl}/amanda/'
output chatCompletionsUrl string = '${apim.properties.gatewayUrl}/amanda/v1/chat/completions'
output apimName string = apim.name
output aoaiName string = aoai.name
output searchName string = search.name
output searchIndex string = searchIndex
output embedDeployment string = embedModelName
output aoaiApiVersion string = aoaiApiVersion
