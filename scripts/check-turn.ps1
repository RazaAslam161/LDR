# Does this project actually hand the app a usable TURN relay?
#
# The previous version of this script reported HEALTHY for two months while
# calling was completely broken off-wifi. It grepped the response body for the
# string "turn:" — which is present INSIDE the object shape the client could
# not parse. It confirmed the credentials existed and never checked the one
# thing that mattered: whether `iceServers` is an ARRAY.
#
# Cloudflare returns it as an OBJECT. The Dart client requires a List, bailed,
# and cached nothing — so no relay candidate ever entered a peer connection.
# Two phones on one wifi pair on host candidates and never need a relay, which
# is why every test passed. This script now checks the shape.
#
#   .\scripts\check-turn.ps1 -Url "https://<ref>.supabase.co" -Key "<publishable or anon key>"
#
# Both values: Supabase Dashboard -> Project Settings -> API. Use the
# PUBLISHABLE key (sb_publishable_...) or the legacy anon key. Never the secret.

param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Key
)

$endpoint = "$($Url.TrimEnd('/'))/functions/v1/turn-credentials"
Write-Host "Asking $endpoint ..." -ForegroundColor Cyan
Write-Host ""

# curl.exe rather than Invoke-WebRequest: Windows PowerShell 5.1 has no
# -SkipHttpErrorCheck and throws on any non-2xx, and the exception shape
# differs between 5.1 and 7 — which is exactly the case this needs to read.
$raw = & curl.exe -s -S -w "`n%{http_code}" -X POST $endpoint `
    -H "Authorization: Bearer $Key" `
    -H "Content-Type: application/json" `
    -d "{}" --max-time 20 2>&1

$lines = @($raw -split "`n")
$status = 0
if ($lines.Count -gt 0) { [int]::TryParse($lines[-1].Trim(), [ref]$status) | Out-Null }
$body = ($lines[0..([Math]::Max(0, $lines.Count - 2))] -join "`n").Trim()

if ($status -eq 0) {
    Write-Host "BROKEN - could not reach the function at all." -ForegroundColor Red
    Write-Host $body
    exit 1
}

Write-Host "HTTP $status"
if ($body) { Write-Host ($body.Substring(0, [Math]::Min(1200, $body.Length))) }
Write-Host ""

if ($status -ne 200) {
    switch ($status) {
        401 { Write-Host "BROKEN - auth rejected. Use the publishable/anon key." -ForegroundColor Red }
        403 { Write-Host "BROKEN - forbidden. The function may require a signed-in user." -ForegroundColor Red }
        404 { Write-Host "BROKEN - not deployed. Run: npx supabase functions deploy turn-credentials" -ForegroundColor Red }
        500 {
            Write-Host "BROKEN - the function ran and failed. The body above says which:" -ForegroundColor Red
            Write-Host "  turn_not_configured -> the app_secrets rows are missing."
            Write-Host "  secret_read_failed  -> the function cannot read app_secrets."
        }
        502 {
            Write-Host "BROKEN - Cloudflare rejected the request, or returned a shape" -ForegroundColor Red
            Write-Host "         this function could not normalise. The body above says which."
        }
        default { Write-Host "BROKEN - unexpected status. The body above is the detail." -ForegroundColor Red }
    }
    exit 1
}

# ── The checks that actually matter ───────────────────────────────────────
try { $json = $body | ConvertFrom-Json }
catch {
    Write-Host "BROKEN - HTTP 200 but the body is not JSON." -ForegroundColor Red
    exit 1
}

$ice = $json.iceServers
if ($null -eq $ice) {
    Write-Host "BROKEN - HTTP 200 with no iceServers field at all." -ForegroundColor Red
    exit 1
}

# THE check the old script missed. PowerShell surfaces a JSON array as
# object[]; a single JSON object is a PSCustomObject.
$isArray = $ice -is [System.Array]
if (-not $isArray) {
    Write-Host "BROKEN - iceServers is an OBJECT, not an array." -ForegroundColor Red
    Write-Host "This is the two-month calling bug: the client requires a list and"
    Write-Host "discards anything else, so it caches no relay and every call between"
    Write-Host "two different networks fails while same-wifi calls work fine."
    Write-Host ""
    Write-Host "The deployed function is older than the code. Deploy it:" -ForegroundColor Yellow
    Write-Host "  npx -y supabase functions deploy turn-credentials --project-ref <ref>"
    exit 1
}

$relays = @($ice | Where-Object {
    ($_.urls -join ' ') -match '(^|\s)turns?:'
})

if ($relays.Count -eq 0) {
    Write-Host "BROKEN - iceServers is an array but contains NO turn:/turns: entry." -ForegroundColor Red
    Write-Host "Only STUN came back. Users on different networks cannot connect."
    exit 1
}

Write-Host "HEALTHY" -ForegroundColor Green
Write-Host "  iceServers is an ARRAY  ($($ice.Count) entries)"
Write-Host "  relay entries found:    $($relays.Count)"
Write-Host ""
Write-Host "The app can now cache a relay, so calls between two different"
Write-Host "networks can connect. The real proof is still one call with mobile"
Write-Host "data on one side and wifi on the other."
