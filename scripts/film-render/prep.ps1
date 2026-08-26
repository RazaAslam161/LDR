# One-time prep: 2x lanczos plate resamples + lottie player + the three emoji
# JSONs the film uses, all into composition/ (generated files, gitignored).
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$plates = "composition\assets\plates"
New-Item -ItemType Directory -Force $plates | Out-Null

# ffmpeg on PATH after winget install; fall back to the winget links dir
$ffmpeg = "ffmpeg"
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  $cand = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe" -ErrorAction SilentlyContinue
  if ($cand) { $ffmpeg = $cand.FullName } else { throw "ffmpeg not found - install Gyan.FFmpeg and open a new shell" }
}

& $ffmpeg -y -i "..\..\web\assets\img\hero-plate.webp" -vf "scale=iw*2:ih*2:flags=lanczos" "$plates\hero-plate@2x.png"
& $ffmpeg -y -i "..\..\web\assets\img\distance.webp"   -vf "scale=iw*2:ih*2:flags=lanczos" "$plates\distance@2x.png"
& $ffmpeg -y -i "..\..\web\assets\img\keepsakes.webp"  -vf "scale=iw*2:ih*2:flags=lanczos" "$plates\keepsakes@2x.png"

Copy-Item "node_modules\lottie-web\build\player\lottie.min.js" "composition\lottie.min.js" -Force
New-Item -ItemType Directory -Force "composition\emoji" | Out-Null
foreach ($e in @("loving", "calm", "missing_you")) {
  Copy-Item "..\..\mobile\assets\emoji\$e.json" "composition\emoji\$e.json" -Force
}

Get-ChildItem $plates, "composition\emoji", "composition\lottie.min.js" |
  ForEach-Object { "{0,10:N0}  {1}" -f $_.Length, $_.Name }
Write-Output "prep complete"
