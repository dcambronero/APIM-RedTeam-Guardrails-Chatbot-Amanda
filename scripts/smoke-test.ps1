<#
.SYNOPSIS
  Prueba Amanda desde tu PC por internet (modo normal y streaming).
  Compatible con Windows PowerShell 5.1 y PowerShell 7 (acentos y UTF-8 correctos).
.EXAMPLE
  .\scripts\smoke-test.ps1
  .\scripts\smoke-test.ps1 -ResourceGroup rg-amanda-lab
#>
param([string]$ResourceGroup = "rg-amanda-lab")

# --- Consola en UTF-8 (evita caracteres como Ã± o â¡ en PowerShell 5.1) ---
chcp 65001 > $null
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

# --- Endpoint ---
$url = az deployment group show -g $ResourceGroup -n main --query properties.outputs.chatCompletionsUrl.value -o tsv
if (-not $url) { throw "No encontré el deployment 'main' en $ResourceGroup" }
Write-Host "Endpoint: $url`n" -ForegroundColor Magenta

# --- 1) stream=false ---
Write-Host "1) stream=false (contrato Stateless que usará el Red Team)" -ForegroundColor Cyan
$body = @{
    messages = @(@{ role = "user"; content = "¿Cuál es mi saldo?" })
    stream   = $false
    trace    = $true
} | ConvertTo-Json -Depth 5
try {
    $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $url `
        -ContentType "application/json; charset=utf-8" -Body $utf8.GetBytes($body)
    $text = $utf8.GetString($resp.RawContentStream.ToArray())
    $r = $text | ConvertFrom-Json
    Write-Host ""
    $r.choices[0].message.content
    Write-Host ""
    $r.amanda_trace | ConvertTo-Json -Compress -Depth 5
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) { $_.ErrorDetails.Message }
}

# --- 2) stream=true ---
Write-Host "`n2) stream=true (SSE, token por token)" -ForegroundColor Cyan
$tmp = Join-Path $env:TEMP "amanda-stream.json"
$streamBody = '{"messages":[{"role":"user","content":"¿Qué hago si me roban la tarjeta?"}],"stream":true}'
[System.IO.File]::WriteAllText($tmp, $streamBody, $utf8)
curl.exe -sN -X POST $url -H "Content-Type: application/json" --data-binary "@$tmp" | Select-Object -First 8
Remove-Item $tmp -ErrorAction SilentlyContinue

Write-Host "`nSi ves 'data: {...chat.completion.chunk...}' el streaming atraviesa APIM correctamente." -ForegroundColor Green
