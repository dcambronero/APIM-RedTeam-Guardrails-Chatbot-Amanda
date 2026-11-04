<#
.SYNOPSIS
  Muestra las acciones de alto impacto que ejecutó Amanda (transferencias y correos).
  Útil como evidencia en la Fase II (Red Team) y Fase III (guardrails).
#>
param([string]$ResourceGroup = "rg-amanda-lab")
$sub  = az account show --query id -o tsv
$apim = az deployment group show -g $ResourceGroup -n main --query properties.outputs.apimName.value -o tsv
$gw   = az apim show -g $ResourceGroup -n $apim --query gatewayUrl -o tsv
$key  = az rest --method post --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$apim/subscriptions/amanda-agent/listSecrets?api-version=2024-05-01" --query primaryKey -o tsv
$r = Invoke-RestMethod -Uri "$gw/tools/audit" -Headers @{ "Ocp-Apim-Subscription-Key" = $key }
if (-not $r.events) { Write-Host "Sin acciones registradas todavía." -ForegroundColor Green; return }
$r.events | Format-Table type, time, from, to_account, amount, to, subject -AutoSize
