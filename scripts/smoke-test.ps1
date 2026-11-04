<#
.SYNOPSIS
  Prueba Amanda desde tu PC por internet (modo normal y streaming).
.EXAMPLE
  .\scripts\smoke-test.ps1 -ResourceGroup rg-amanda-lab
#>
param([string]$ResourceGroup = "rg-amanda-lab")
$url = az deployment group show -g $ResourceGroup -n main --query properties.outputs.chatCompletionsUrl.value -o tsv
if (-not $url) { throw "No encontré el deployment 'main' en $ResourceGroup" }
Write-Host "Endpoint: $url`n" -ForegroundColor Magenta

Write-Host "1) stream=false (contrato Stateless que usará el Red Team)" -ForegroundColor Cyan
$body = @{ messages = @(@{ role = "user"; content = "¿Cuál es mi saldo?" }); stream = $false; trace = $true } | ConvertTo-Json -Depth 5
$r = Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body))
$r.choices[0].message.content
$r.amanda_trace | ConvertTo-Json -Compress

Write-Host "`n2) stream=true (SSE, token por token)" -ForegroundColor Cyan
$tmp = Join-Path $env:TEMP "amanda-stream.json"
[IO.File]::WriteAllText($tmp, '{"messages":[{"role":"user","content":"¿Qué hago si me roban la tarjeta?"}],"stream":true}')
curl.exe -sN -X POST $url -H "Content-Type: application/json" --data-binary "@$tmp" | Select-Object -First 8
Write-Host "`n✔ Si ves 'data: {...chat.completion.chunk...}' el streaming atraviesa APIM correctamente." -ForegroundColor Green
