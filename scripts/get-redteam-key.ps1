<#
.SYNOPSIS
  Entregable de la Fase I para la Fase II: imprime los datos para crear el target
  de AI Red Teaming (URL, header, API key, campos adicionales) y valida la key.
.EXAMPLE
  .\scripts\get-redteam-key.ps1
  .\scripts\get-redteam-key.ps1 -CopyKey      # además copia la key al portapapeles
#>
param(
    [string]$ResourceGroup = "rg-amanda-lab",
    [switch]$CopyKey
)
chcp 65001 > $null
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.Console]::OutputEncoding = $utf8

$sub = az account show --query id -o tsv
$o = az deployment group show -g $ResourceGroup -n main --query properties.outputs -o json | ConvertFrom-Json
if (-not $o) { throw "No encontré el deployment 'main' en $ResourceGroup" }
$apim = $o.apimName.value
$url  = $o.chatCompletionsUrl.value
$ui   = $o.chatUrl.value

$key = az rest --method post `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$apim/subscriptions/amanda-redteam/listSecrets?api-version=2024-05-01" `
  --query primaryKey -o tsv
if (-not $key) { throw "No encontré la subscription 'amanda-redteam'. Redespliega la Fase I." }

Write-Host "`n=== Amanda · datos de la Fase I ===`n" -ForegroundColor Magenta
Write-Host "Chat (UI)              : $ui"
Write-Host "`n=== Target de AI Red Teaming (Fase II) ===`n" -ForegroundColor Magenta
Write-Host "Target type            : Agent"
Write-Host "Endpoint URL           : $url"
Write-Host "Conversation mode      : Stateless (se envía el historial completo)"
Write-Host "Authentication         : API Key"
Write-Host "Header name            : Ocp-Apim-Subscription-Key"
Write-Host "API key                : $key" -ForegroundColor Yellow
Write-Host "Additional fields      : {""stream"": false}"
Write-Host "Rate limit (esta key)  : 600 req/min"
Write-Host "Max concurrent (suger.): 3-5 (cuota del modelo: 50K TPM)"

Write-Host "`nValidando la key..." -ForegroundColor Cyan
$body = @{ messages = @(@{ role = "user"; content = "Hola, ¿quién eres?" }); stream = $false } | ConvertTo-Json -Depth 5
try {
    $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $url `
        -Headers @{ "Ocp-Apim-Subscription-Key" = $key } `
        -ContentType "application/json; charset=utf-8" -Body $utf8.GetBytes($body)
    $r = $utf8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    Write-Host "✔ HTTP $($resp.StatusCode) · Amanda: $($r.choices[0].message.content)" -ForegroundColor Green
} catch {
    Write-Host "✖ Error: $($_.Exception.Message)" -ForegroundColor Red
}

if ($CopyKey) { Set-Clipboard -Value $key; Write-Host "`nKey copiada al portapapeles." -ForegroundColor Green }
Write-Host "`n⚠️  La key es un secreto: no la subas al repo ni la compartas por chat." -ForegroundColor Yellow
