<#
.SYNOPSIS
  Prepara Azure + GitHub para desplegar Amanda con GitHub Actions (OIDC). Se corre UNA vez.
  Es idempotente: puedes volver a correrlo sin romper nada.

  Crea:
    - Resource group del lab
    - App registration + service principal "gh-amanda-lab-deployer"
    - Rol Contributor del deployer SOLO sobre el resource group
    - Federated credentials para la rama main (formato clásico + inmutable de GitHub)
    - Secrets y variables del repo (si tienes GitHub CLI autenticado)

.EXAMPLE
  .\scripts\bootstrap.ps1 -PublisherEmail diego@ejemplo.com
#>
param(
    [Parameter(Mandatory = $true)][string]$PublisherEmail,
    [string]$Repo = "dcambronero/APIM-RedTeam-Guardrails-Chatbot-Amanda",
    [string]$ResourceGroup = "rg-amanda-lab",
    [string]$Location = "eastus2",
    [string]$AppName = "gh-amanda-lab-deployer",
    [string]$Branch = "main"
)
$ErrorActionPreference = "Continue"  # en PS 5.1 "Stop" rompe con stderr de az
function Step($t) { Write-Host "`n▶ $t" -ForegroundColor Magenta }
function Az-Json { $out = az @args -o json; if ($LASTEXITCODE -ne 0) { throw "az $args falló" }; if ($out) { $out | ConvertFrom-Json } }

$acct = Az-Json account show
$sub = $acct.id; $tenant = $acct.tenantId
Write-Host "Suscripción: $($acct.name) ($sub)"

Step "1/6 Registrando resource providers"
$providers = "Microsoft.ApiManagement","Microsoft.App","Microsoft.CognitiveServices","Microsoft.Search",
             "Microsoft.ContainerRegistry","Microsoft.OperationalInsights","Microsoft.Insights"
foreach ($p in $providers) { az provider register -n $p -o none }
foreach ($p in $providers) {
    for ($i = 0; $i -lt 60; $i++) {
        if ((az provider show -n $p --query registrationState -o tsv) -eq "Registered") { break }
        Start-Sleep 10
    }
    Write-Host "  ✔ $p"
}

Step "2/6 Resource group $ResourceGroup ($Location)"
$rg = Az-Json group create -n $ResourceGroup -l $Location --tags project=amanda-lab
$rgId = $rg.id

Step "3/6 App registration + service principal ($AppName)"
$appId = az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) { $appId = az ad app create --display-name $AppName --query appId -o tsv }
if (-not $appId) { throw "No se pudo crear la app registration (revisa permisos en Entra ID)" }
$appObjectId = az ad app show --id $appId --query id -o tsv
$spId = az ad sp show --id $appId --query id -o tsv 2>$null
if (-not $spId) { $spId = az ad sp create --id $appId --query id -o tsv }
if (-not $spId) { throw "No se pudo crear el service principal" }
Write-Host "  appId: $appId"

Step "4/6 Rol Contributor sobre el resource group"
$exists = az role assignment list --assignee $spId --scope $rgId --role Contributor --query "[0].id" -o tsv
if (-not $exists) {
    for ($i = 1; $i -le 10; $i++) {  # reintenta: el SP tarda en replicar en Entra ID
        az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
            --role Contributor --scope $rgId -o none 2>$null
        if ($LASTEXITCODE -eq 0) { break }
        Write-Host "  esperando replicación del service principal ($i/10)..."; Start-Sleep 15
    }
    if ($LASTEXITCODE -ne 0) { throw "No se pudo asignar Contributor. ¿Tienes Owner/User Access Administrator?" }
}
Write-Host "  ✔ Contributor en $ResourceGroup"

Step "5/6 Federated credentials (GitHub OIDC)"
$owner, $repoName = $Repo.Split("/")
$subjects = @{ "github-$Branch" = "repo:${Repo}:ref:refs/heads/$Branch" }
# Repos creados después del 15-jul-2026 usan el subject inmutable: repo:owner@ownerId/repo@repoId:...
$ids = $null
if (Get-Command gh -ErrorAction SilentlyContinue) {
    try { $ids = gh api "repos/$Repo" | ConvertFrom-Json } catch {}
}
if (-not $ids) { try { $ids = Invoke-RestMethod "https://api.github.com/repos/$Repo" } catch {} }
if ($ids) {
    $subjects["github-$Branch-immutable"] = "repo:$owner@$($ids.owner.id)/$repoName@$($ids.id):ref:refs/heads/$Branch"
} else {
    Write-Warning "No pude leer los IDs del repo (¿privado y sin 'gh auth login'?). Solo se crea el subject clásico."
}
$existing = @(az ad app federated-credential list --id $appObjectId --query "[].name" -o tsv)
foreach ($name in $subjects.Keys) {
    if ($existing -contains $name) { Write-Host "  = $name ya existe"; continue }
    $file = Join-Path $env:TEMP "$name.json"
    $json = @{ name = $name; issuer = "https://token.actions.githubusercontent.com"; subject = $subjects[$name];
               audiences = @("api://AzureADTokenExchange") } | ConvertTo-Json
    [IO.File]::WriteAllText($file, $json)   # UTF-8 sin BOM
    az ad app federated-credential create --id $appObjectId --parameters "@$file" -o none
    Write-Host "  ✔ $name → $($subjects[$name])"
}

Step "6/6 Secrets y variables del repo en GitHub"
$secrets = [ordered]@{ AZURE_CLIENT_ID = $appId; AZURE_TENANT_ID = $tenant; AZURE_SUBSCRIPTION_ID = $sub }
$vars = [ordered]@{ AZURE_RESOURCE_GROUP = $ResourceGroup; AZURE_LOCATION = $Location; APIM_PUBLISHER_EMAIL = $PublisherEmail }
$ghOk = $false
if (Get-Command gh -ErrorAction SilentlyContinue) { gh auth status 2>$null | Out-Null; $ghOk = ($LASTEXITCODE -eq 0) }
if ($ghOk) {
    foreach ($k in $secrets.Keys) { gh secret set $k -R $Repo -b $secrets[$k]; Write-Host "  ✔ secret $k" }
    foreach ($k in $vars.Keys) { gh variable set $k -R $Repo -b $vars[$k]; Write-Host "  ✔ variable $k" }
} else {
    Write-Host "GitHub CLI no disponible. Crea esto en GitHub > Settings > Secrets and variables > Actions:" -ForegroundColor Yellow
    Write-Host "  Secrets:";   $secrets.GetEnumerator() | ForEach-Object { Write-Host "    $($_.Key) = $($_.Value)" }
    Write-Host "  Variables:"; $vars.GetEnumerator()    | ForEach-Object { Write-Host "    $($_.Key) = $($_.Value)" }
}

Write-Host "`n✅ Bootstrap completo. Ahora: GitHub > Actions > 'Fase I · Desplegar Amanda' > Run workflow`n" -ForegroundColor Green
