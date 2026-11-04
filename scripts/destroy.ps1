<#
.SYNOPSIS
  Elimina el lab y PURGA los recursos con soft-delete (APIM y Azure OpenAI),
  para que puedas volver a desplegar con los mismos nombres.
.EXAMPLE
  .\scripts\destroy.ps1 -ResourceGroup rg-amanda-lab
  .\scripts\destroy.ps1 -ResourceGroup rg-amanda-lab -DeleteDeployerIdentity
#>
param(
    [string]$ResourceGroup = "rg-amanda-lab",
    [switch]$DeleteDeployerIdentity,
    [string]$AppName = "gh-amanda-lab-deployer"
)
$loc  = az group show -n $ResourceGroup --query location -o tsv
if (-not $loc) { throw "No existe el resource group $ResourceGroup" }
$apim = az apim list -g $ResourceGroup --query "[0].name" -o tsv
$aoai = az cognitiveservices account list -g $ResourceGroup --query "[0].name" -o tsv

Write-Host "Eliminando $ResourceGroup (puede tardar 10-20 min)..." -ForegroundColor Yellow
az group delete -n $ResourceGroup --yes

if ($apim) { Write-Host "Purgando APIM $apim"; az apim deletedservice purge --service-name $apim --location $loc }
if ($aoai) { Write-Host "Purgando Azure OpenAI $aoai"; az cognitiveservices account purge -l $loc -g $ResourceGroup -n $aoai }

if ($DeleteDeployerIdentity) {
    $appId = az ad app list --display-name $AppName --query "[0].appId" -o tsv
    if ($appId) { az ad app delete --id $appId; Write-Host "App registration eliminada" }
}
Write-Host "✔ Lab eliminado" -ForegroundColor Green
