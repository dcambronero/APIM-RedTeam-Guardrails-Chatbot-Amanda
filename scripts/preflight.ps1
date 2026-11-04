<#
.SYNOPSIS
  Valida, ANTES de desplegar, que tu usuario y tu suscripción pueden levantar el lab Amanda.
  No crea recursos de Azure (solo crea y borra una app registration de prueba).

.EXAMPLE
  .\scripts\preflight.ps1 -Location eastus2
#>
param(
    [string]$Location = "eastus2",
    [string]$ChatModel = "gpt-4o-mini",
    [string]$ChatSku = "GlobalStandard",
    [int]$ChatCapacity = 50,
    [string]$EmbedModel = "text-embedding-3-small",
    [string]$EmbedSku = "Standard",
    [int]$EmbedCapacity = 50
)
$ErrorActionPreference = "Continue"
$results = New-Object System.Collections.Generic.List[object]
function Add-Result($check, $status, $detail) {
    $results.Add([pscustomobject]@{ Check = $check; Status = $status; Detail = $detail })
    $color = @{ PASS = "Green"; WARN = "Yellow"; FAIL = "Red" }[$status]
    Write-Host ("[{0}] {1} - {2}" -f $status, $check, $detail) -ForegroundColor $color
}

Write-Host "`n=== Amanda Lab · Preflight ===`n" -ForegroundColor Magenta

# 1. Azure CLI
$azVersion = (az version -o json 2>$null | ConvertFrom-Json)."azure-cli"
if (-not $azVersion) { Add-Result "Azure CLI" "FAIL" "Instala Azure CLI: winget install Microsoft.AzureCLI"; return }
Add-Result "Azure CLI" "PASS" "v$azVersion"
az config set extension.use_dynamic_install=yes_without_prompt 2>$null | Out-Null

# 2. Sesión
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { Add-Result "Login" "FAIL" "Ejecuta: az login"; return }
$sub = $acct.id
Add-Result "Suscripción" "PASS" "$($acct.name) ($sub) · tenant $($acct.tenantId)"

# 3. Rol en la suscripción (necesario para el bootstrap: crear RG y asignar Contributor al deployer)
$oid = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $oid) {
    Add-Result "Rol RBAC" "WARN" "No pude leer tu usuario en Entra ID (¿cuenta invitada/guest?). Valida el rol en el portal."
} else {
    $roles = az role assignment list --assignee $oid --scope "/subscriptions/$sub" --include-inherited --include-groups --query "[].roleDefinitionName" -o tsv 2>$null
    $roles = @($roles | Sort-Object -Unique)
    $canAssign = ($roles -contains "Owner") -or ($roles -contains "User Access Administrator") -or ($roles -contains "Role Based Access Control Administrator")
    $canCreate = ($roles -contains "Owner") -or ($roles -contains "Contributor")
    if ($canAssign -and $canCreate) { Add-Result "Rol RBAC" "PASS" ($roles -join ", ") }
    elseif ($roles.Count -eq 0) { Add-Result "Rol RBAC" "WARN" "Sin roles activos visibles. Si usas PIM, ACTIVA tu rol (Owner) antes de continuar." }
    else { Add-Result "Rol RBAC" "FAIL" "Tienes: $($roles -join ', '). Necesitas Owner (o Contributor + User Access Administrator) en la suscripción." }
}

# 4. Crear app registrations (para OIDC con GitHub)
$testName = "amanda-preflight-" + (Get-Random -Maximum 99999)
$testApp = az ad app create --display-name $testName --query appId -o tsv 2>$null
if ($testApp) {
    az ad app delete --id $testApp 2>$null | Out-Null
    Add-Result "App registration" "PASS" "Puedes crear apps en Entra ID (se creó y borró '$testName')"
} else {
    Add-Result "App registration" "FAIL" "No puedes crear app registrations. Pide el rol 'Application Developer' o que un admin cree la app."
}

# 5. Resource providers
$providers = "Microsoft.ApiManagement","Microsoft.App","Microsoft.CognitiveServices","Microsoft.Search",
             "Microsoft.ContainerRegistry","Microsoft.OperationalInsights","Microsoft.Insights"
$notReg = @()
foreach ($p in $providers) {
    $state = az provider show -n $p --query registrationState -o tsv 2>$null
    if ($state -ne "Registered") { $notReg += $p }
}
if ($notReg.Count -eq 0) { Add-Result "Resource providers" "PASS" "Todos registrados" }
else { Add-Result "Resource providers" "WARN" "No registrados (el bootstrap los registra): $($notReg -join ', ')" }

# 6. Modelos y cuota de Azure OpenAI en la región
$models = az cognitiveservices model list -l $Location -o json 2>$null | ConvertFrom-Json
foreach ($m in @(@{n=$ChatModel; s=$ChatSku; c=$ChatCapacity}, @{n=$EmbedModel; s=$EmbedSku; c=$EmbedCapacity})) {
    $found = $models | Where-Object { $_.model.name -eq $m.n -and ($_.model.skus.name -contains $m.s) }
    if (-not $found) { Add-Result "Modelo $($m.n)" "FAIL" "No disponible con SKU $($m.s) en $Location. Prueba otra región (eastus2, swedencentral)."; continue }
    $usage = az cognitiveservices usage list -l $Location -o json 2>$null | ConvertFrom-Json |
             Where-Object { $_.name.value -eq "OpenAI.$($m.s).$($m.n)" }
    if ($usage) {
        $usage = @($usage)[0]; $free = [int]$usage.limit - [int]$usage.currentValue
        if ($free -ge $m.c) { Add-Result "Cuota $($m.n)" "PASS" "$free K TPM libres ($($m.s), se usan $($m.c))" }
        else { Add-Result "Cuota $($m.n)" "FAIL" "Solo $free K TPM libres; baja la capacidad o cambia de región" }
    } else { Add-Result "Cuota $($m.n)" "WARN" "No pude leer la cuota; el modelo sí está disponible" }
}

# 7. Azure Policy que pueda bloquear el lab
$policies = az policy assignment list --scope "/subscriptions/$sub" --query "[].displayName" -o tsv 2>$null
$risky = @($policies | Where-Object { $_ -match "local auth|key access|allowed locations|public network|allowed resource|deny" })
if ($risky.Count -gt 0) { Add-Result "Azure Policy" "WARN" "Revisa: $($risky -join ' | ') (el lab usa keys locales y endpoints públicos)" }
else { Add-Result "Azure Policy" "PASS" "Sin políticas evidentes que bloqueen el lab" }

# 8. GitHub CLI (opcional)
if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Add-Result "GitHub CLI" "PASS" "Autenticado: el bootstrap configurará secrets y variables" }
    else { Add-Result "GitHub CLI" "WARN" "Instalado pero sin login: ejecuta 'gh auth login'" }
} else { Add-Result "GitHub CLI" "WARN" "No instalado (opcional): winget install GitHub.cli" }

Write-Host "`n=== Resumen ===" -ForegroundColor Magenta
$results | Format-Table -AutoSize
if ($results.Status -contains "FAIL") { Write-Host "Hay checks en FAIL: resuélvelos antes del bootstrap." -ForegroundColor Red; exit 1 }
Write-Host "Listo para continuar con .\scripts\bootstrap.ps1" -ForegroundColor Green
