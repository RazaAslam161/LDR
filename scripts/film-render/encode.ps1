# Encode the rendered frames. Usage: .\encode.ps1 master | web | poster
# All commands force bt709 matrix + tv range and TAG the stream - ffmpeg's
# RGB->YUV default can silently pick bt601 and shift the ember colors.
param([Parameter(Mandatory)][ValidateSet("master", "web", "poster")] [string]$What)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$ffmpeg = "ffmpeg"
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  $cand = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe" -ErrorAction SilentlyContinue
  if ($cand) { $ffmpeg = $cand.FullName } else { throw "ffmpeg not found" }
}

$vf = "scale=in_range=full:out_range=tv:out_color_matrix=bt709"
$color = @("-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv")

switch ($What) {
  "master" {
    & $ffmpeg -y -framerate 30 -i out/frames/f%04d.png -vf $vf `
      -c:v libx264 -preset slower -crf 18 -pix_fmt yuv420p `
      -x264-params "aq-mode=3:aq-strength=1.0:deblock=-1,-1" `
      @color -movflags +faststart -an out/miles-intro-master.mp4
    & $ffmpeg -hide_banner -i out/miles-intro-master.mp4 2>&1 | Select-String "Duration|Stream"
  }
  "web" {
    # 60s inside 10 MiB: 1398 kbps ceiling minus container overhead -> 1250k target
    & $ffmpeg -y -framerate 30 -i out/frames/f%04d.png -vf $vf `
      -c:v libvpx-vp9 -pix_fmt yuv420p -b:v 1250k -minrate 625k -maxrate 1812k `
      -deadline good -cpu-used 4 -row-mt 1 -tile-columns 2 -g 240 -aq-mode 2 `
      @color -passlogfile out/vp9 -pass 1 -an -f null NUL
    & $ffmpeg -y -framerate 30 -i out/frames/f%04d.png -vf $vf `
      -c:v libvpx-vp9 -pix_fmt yuv420p -b:v 1250k -minrate 625k -maxrate 1812k `
      -deadline good -cpu-used 1 -row-mt 1 -tile-columns 2 -g 240 -aq-mode 2 `
      @color -passlogfile out/vp9 -pass 2 -an "..\..\web\miles-intro.webm"
    "{0:N0} bytes" -f (Get-Item "..\..\web\miles-intro.webm").Length
  }
  "poster" {
    # hero frame at t = 9.0s (wordmark + H1 + mark all settled)
    & $ffmpeg -y -i out/frames/f0270.png -vf "scale=1600:900" -q:v 4 `
      "..\..\web\assets\img\film-poster.jpg"
    "{0:N0} bytes" -f (Get-Item "..\..\web\assets\img\film-poster.jpg").Length
  }
}
