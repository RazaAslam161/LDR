# Does this project actually have a working TURN relay?
#
# Two phones on one wifi connect directly and never need a relay, so calling can
# look perfect while being broken for every real pair of users. Two people
# behind different carrier NATs almost always need one. This answers the
# question without a second phone, a second network, or a debugger.
#
# Run it from PowerShell in E:\LDR :
#
#   .\scripts\check-turn.ps1 -Url "https://<ref>.supabase.co" -Key "<publishable or anon key>"
#
# Both values are in Supabase Dashboard -> Project Settings -> API.
# Use the PUBLISHABLE key (sb_publishable_...) or the legacy anon key. Never the
# secret key — it is not needed here and must not leave the server.

param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Key
)

$endpoint = "$($Url.TrimEnd('/'))/functions/v1/turn-credentials"
Write-Host "Asking $endpoint ..." -ForegroundColor Cyan
Write-Host ""

# curl.exe rather than Invoke-WebRequest on purpose. Windows PowerShell 5.1 has
# no -SkipHttpErrorCheck and throws on any non-2xx, and the shape of the
# exception differs between 5.1 and 7 — which is exactly the case this script
# needs to read. curl ships with Windows 10 1803+ and behaves the same on both.
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
if ($body) { Write-Host ($body.Substring(0, [Math]::Min(1500, $body.Length))) }
Write-Host ""

switch ($status) {
    200 {
        if ($body -match "turns?:") {
            Write-Host "HEALTHY - the response contains a turn:/turns: relay." -ForegroundColor Green
            Write-Host "Calls between users on different networks can connect."
        }
        else {
            Write-Host "BROKEN - HTTP 200 but NO turn:/turns: entry in the response." -ForegroundColor Red
            Write-Host "Only STUN came back. Two users on different networks will fail to"
            Write-Host "connect, while two phones on your wifi will work fine."
        }
    }
    401 { Write-Host "BROKEN - auth rejected. Check the key is the publishable/anon one." -ForegroundColor Red }
    403 { Write-Host "BROKEN - forbidden. The function may require a signed-in user." -ForegroundColor Red }
    404 {
        Write-Host "BROKEN - the function is not deployed." -ForegroundColor Red
        Write-Host "Deploy it with:  supabase functions deploy turn-credentials"
    }
    500 {
        Write-Host "BROKEN - the function ran and failed. The body above says which:" -ForegroundColor Red
        Write-Host "  turn_not_configured -> the app_secrets rows are missing. In the SQL editor:"
        Write-Host "     insert into app_secrets(key,value) values"
        Write-Host "       ('CF_TURN_KEY_ID','<cloudflare turn key id>'),"
        Write-Host "       ('CF_TURN_API_TOKEN','<cloudflare turn api token>');"
        Write-Host "  secret_read_failed  -> the function cannot read app_secrets."
    }
    502 {
        Write-Host "BROKEN - Cloudflare rejected the request." -ForegroundColor Red
        Write-Host "Usually the API token is wrong, expired, or lacks Realtime TURN permission."
    }
    default { Write-Host "BROKEN - unexpected status. The body above is the detail." -ForegroundColor Red }
}
