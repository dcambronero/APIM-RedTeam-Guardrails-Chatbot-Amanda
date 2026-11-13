<#
.SYNOPSIS
  Elimina el lab y PURGA los recursos con soft-delete (APIM y Azure OpenAI),
  para poder volver a desplegar con los mismos nombres.
  Espera, reintenta y verifica que la purga se completó.
  Después de esto, para volver a levantar: bootstrap.ps1 + workflow.
.EXAMPLE
  .\scripts\destroy.ps1
  .\scripts\destroy.ps1 -DeleteDeployerIdentity
#>
param(
    [string]$ResourceGroup = "rg-amanda-lab",
    [switch]$DeleteDeployerIdentity,
    [string]$AppName = "gh-amanda-lab-deployer"
)
$ErrorActionPreference = "Continue"

function Purge-Apim($name, $loc) {
    for ($i = 1; $i -le 20; $i++) {
        $deleted = az apim deletedservice list --query "[?name=='$name'].name" -o tsv 2>$null
        if ($deleted) {
            Write-Host "  Purgando APIM $name (intento $i)..."
            az apim deletedservice purge --service-name $name --location $loc 2>$null
        }
        Start-Sleep 15
        $still = az apim deletedservice list --query "[?name=='$name'].name" -o tsv 2>$null
        $alive = az apim list --query "[?name=='$name'].name" -o tsv 2>$null
        if (-not $still -and -not $alive) { Write-Host "  ✔ APIM purgado" -ForegroundColor Green; return $true }
        Write-Host "  esperando a que APIM termine de eliminarse ($i/20)..."
        Start-Sleep 15
    }
    return $false
}

function Purge-Aoai($name, $loc, $rg) {
    for ($i = 1; $i -le 20; $i++) {
        $deleted = az cognitiveservices account list-deleted --query "[?name=='$name'].name" -o tsv 2>$null
        if ($deleted) {
            Write-Host "  Purgando Azure OpenAI $name (intento $i)..."
            az cognitiveservices account purge -l $loc -g $rg -n $name 2>$null
        }
        Start-Sleep 10
        $still = az cognitiveservices account list-deleted --query "[?name=='$name'].name" -o tsv 2>$null
        if (-not $still) { Write-Host "  ✔ Azure OpenAI purgado" -ForegroundColor Green; return $true }
        Write-Host "  esperando a que Azure OpenAI aparezca como eliminado ($i/20)..."
        Start-Sleep 10
    }
    return $false
}

$loc = az group show -n $ResourceGroup --query location -o tsv 2>$null
if (-not $loc) { throw "No existe el resource group $ResourceGroup" }
$apim = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
$aoai = az cognitiveservices account list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
Write-Host "APIM: $apim · Azure OpenAI: $aoai · Región: $loc" -ForegroundColor Magenta

Write-Host "`n▶ Eliminando $ResourceGroup (10-20 min)..." -ForegroundColor Yellow
az group delete -n $ResourceGroup --yes
for ($i = 0; $i -lt 60; $i++) {
    if ((az group exists -n $ResourceGroup) -eq "false") { break }
    Start-Sleep 20
}
Write-Host "  ✔ Resource group eliminado" -ForegroundColor Green

$ok = $true
if ($apim) { Write-Host "`n▶ Purga de APIM" -ForegroundColor Yellow; if (-not (Purge-Apim $apim $loc)) { $ok = $false } }
if ($aoai) { Write-Host "`n▶ Purga de Azure OpenAI" -ForegroundColor Yellow; if (-not (Purge-Aoai $aoai $loc $ResourceGroup)) { $ok = $false } }

if ($DeleteDeployerIdentity) {
    $appId = az ad app list --display-name $AppName --query "[0].appId" -o tsv
    if ($appId) { az ad app delete --id $appId; Write-Host "  ✔ App registration eliminada" -ForegroundColor Green }
}

Write-Host "`n=== Verificación ===" -ForegroundColor Magenta
Write-Host "Resource group existe : $(az group exists -n $ResourceGroup)"
Write-Host "APIM en soft-delete   : $(az apim deletedservice list --query "[?name=='$apim'].name" -o tsv)"
Write-Host "OpenAI en soft-delete : $(az cognitiveservices account list-deleted --query "[?name=='$aoai'].name" -o tsv)"
if ($ok) { Write-Host "`n✔ Lab eliminado y purgado. No quedan recursos cobrando." -ForegroundColor Green }
else {
    Write-Host "`n⚠ Alguna purga no se completó. Repite manualmente:" -ForegroundColor Red
    if ($apim) { Write-Host "  az apim deletedservice purge --service-name $apim --location $loc" }
    if ($aoai) { Write-Host "  az cognitiveservices account purge -l $loc -g $ResourceGroup -n $aoai" }
}