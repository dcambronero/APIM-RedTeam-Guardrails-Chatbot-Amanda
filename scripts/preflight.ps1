<#
.SYNOPSIS
  Valida, ANTES de desplegar, que tu usuario y tu suscripción pueden levantar el lab Amanda.
  No crea recursos de Azure (solo crea y borra una app registration de prueba).

.EXAMPLE
  .\scripts\preflight.ps1 -Location eastus2
#>
param(
    [string]$Location = "eastus2",
    [string]$ChatModel = "gpt-5.4-mini",
    [string]$ChatVersion = "2026-03-17",
    [string]$ChatSku = "GlobalStandard",
    [int]$ChatCapacity = 50,
    [string]$EmbedModel = "text-embedding-3-small",
    [string]$EmbedSku = "Standard",
    [int]$EmbedCapacity = 50
)
$ErrorActionPreference = "Continue"
$Location = $Location.Trim().TrimEnd('.').ToLower()
$results = New-Object System.Collections.Generic.List[object]
function Add-Result($check, $status, $detail) {
    $results.Add([pscustomobject]@{ Check = $check; Status = $status; Detail = $detail })
    $color = @{ PASS = "Green"; WARN = "Yellow"; FAIL = "Red" }[$status]
    Write-Host ("[{0}] {1} - {2}" -f $status, $check, $detail) -ForegroundColor $color
}

Write-Host "`n=== Amanda Lab · Preflight ($Location) ===`n" -ForegroundColor Magenta

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

# 3. Rol en la suscripción
$oid = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $oid) {
    Add-Result "Rol RBAC" "WARN" "No pude leer tu usuario en Entra ID (¿cuenta invitada?). Valida el rol en el portal."
} else {
    $roles = az role assignment list --assignee $oid --scope "/subscriptions/$sub" --include-inherited --include-groups --query "[].roleDefinitionName" -o tsv 2>$null
    $roles = @($roles | Sort-Object -Unique)
    $canAssign = ($roles -contains "Owner") -or ($roles -contains "User Access Administrator") -or ($roles -contains "Role Based Access Control Administrator")
    $canCreate = ($roles -contains "Owner") -or ($roles -contains "Contributor")
    if ($canAssign -and $canCreate) { Add-Result "Rol RBAC" "PASS" ($roles -join ", ") }
    elseif ($roles.Count -eq 0) { Add-Result "Rol RBAC" "WARN" "Sin roles activos visibles. Si usas PIM, ACTIVA tu rol (Owner)." }
    else { Add-Result "Rol RBAC" "FAIL" "Tienes: $($roles -join ', '). Necesitas Owner (o Contributor + User Access Administrator)." }
}

# 4. App registrations (OIDC con GitHub)
$testName = "amanda-preflight-" + (Get-Random -Maximum 99999)
$testApp = az ad app create --display-name $testName --query appId -o tsv 2>$null
if ($testApp) {
    az ad app delete --id $testApp 2>$null | Out-Null
    Add-Result "App registration" "PASS" "Puedes crear apps en Entra ID (se creó y borró '$testName')"
} else {
    Add-Result "App registration" "FAIL" "No puedes crear app registrations. Pide el rol 'Application Developer'."
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

# 6. Modelos (nombre + versión + SKU) y cuota de Azure OpenAI
#    Filtrado con JMESPath dentro de az: robusto en PowerShell 5.1 y 7
$checks = @(
    @{ n = $ChatModel;  v = $ChatVersion; s = $ChatSku;  c = $ChatCapacity },
    @{ n = $EmbedModel; v = "1";          s = $EmbedSku; c = $EmbedCapacity }
)
foreach ($m in $checks) {
    $q = "[?model.name=='$($m.n)' && model.version=='$($m.v)'] | [?contains(model.skus[].name, '$($m.s)')] | length(@)"
    $found = 0
    $raw = az cognitiveservices model list -l $Location --query $q -o tsv 2>$null
    if ($raw) { $found = [int](@($raw)[0]) }
    if ($found -lt 1) {
        $skus = az cognitiveservices model list -l $Location --query "[?model.name=='$($m.n)'].model.skus[].name" -o tsv 2>$null
        Add-Result "Modelo $($m.n)" "FAIL" "Versión $($m.v) con SKU $($m.s) no disponible en $Location. SKUs: $((@($skus) | Sort-Object -Unique) -join ', ')"
        continue
    }
    $u = az cognitiveservices usage list -l $Location --query "[?name.value=='OpenAI.$($m.s).$($m.n)'] | [0].[limit, currentValue]" -o tsv 2>$null
    $vals = @(@($u) -join " " -split "\s+" | Where-Object { $_ -ne "" })
    if ($vals.Count -ge 2) {
        $free = [int][double]$vals[0] - [int][double]$vals[1]
        if ($free -ge $m.c) { Add-Result "Cuota $($m.n)" "PASS" "$free K TPM libres ($($m.s), se usan $($m.c))" }
        else { Add-Result "Cuota $($m.n)" "FAIL" "Solo $free K TPM libres ($($m.s)); baja la capacidad o cambia de región" }
    } else {
        Add-Result "Modelo $($m.n)" "PASS" "Disponible ($($m.v), $($m.s)); no pude leer la cuota"
    }
}

# 7. Azure Policy que pueda bloquear el lab
$policies = az policy assignment list --scope "/subscriptions/$sub" --query "[].displayName" -o tsv 2>$null
$risky = @($policies | Where-Object { $_ -match "local auth|key access|allowed locations|public network|allowed resource|deny" })
if ($risky.Count -gt 0) { Add-Result "Azure Policy" "WARN" "Revisa: $($risky -join ' | ') (el lab usa keys locales y endpoints públicos)" }
else { Add-Result "Azure Policy" "PASS" "Sin políticas evidentes que bloqueen el lab" }

# 8. Recursos en soft-delete que bloquearían el redespliegue
$apimDeleted = az apim deletedservice list --query "[?starts_with(name,'apim-amanda-')].name" -o tsv 2>$null
$aoaiDeleted = az cognitiveservices account list-deleted --query "[?starts_with(name,'aoai-amanda-')].name" -o tsv 2>$null
if ($apimDeleted -or $aoaiDeleted) {
    Add-Result "Soft-delete" "FAIL" "Purga antes de desplegar: $((@($apimDeleted) + @($aoaiDeleted) | Where-Object { $_ }) -join ', ') (ver destroy.ps1 o la guía)"
} else { Add-Result "Soft-delete" "PASS" "Sin APIM ni Azure OpenAI de Amanda pendientes de purga" }

# 9. GitHub CLI
if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Add-Result "GitHub CLI" "PASS" "Autenticado: el bootstrap configurará secrets y variables" }
    else { Add-Result "GitHub CLI" "WARN" "Instalado pero sin login: ejecuta 'gh auth login'" }
} else { Add-Result "GitHub CLI" "WARN" "No instalado: winget install GitHub.cli" }

Write-Host "`n=== Resumen ===" -ForegroundColor Magenta
$results | Format-Table -AutoSize
if ($results.Status -contains "FAIL") { Write-Host "Hay checks en FAIL: resuélvelos antes del bootstrap." -ForegroundColor Red; exit 1 }
Write-Host "Listo para continuar con .\scripts\bootstrap.ps1" -ForegroundColor Green
