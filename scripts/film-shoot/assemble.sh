#!/usr/bin/env bash
# Assemble the Miles intro film: mezzanines -> xfade timeline -> VO/bed mix.
# Usage: bash assemble.sh mezz | preview | master | web | poster <t>
set -e
cd /d/Miles/scripts/film-shoot
export PATH="$LOCALAPPDATA/Microsoft/WinGet/Links:$PATH"
BT709="-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv"
MZ=work/mz; mkdir -p "$MZ"

# Timeline order; g3 last. Names map to mezzanine files $MZ/<name>.mp4
ORDER=(s01 s02 g1 s03 s04 s05 s06 s07 g2 s08 s09 g3)
FADE=0.5

mezz() {
  for s in s01 s02 s03 s05 s06 s07; do
    ffmpeg -y -v error -i shots/$s.mp4 -vf "scale=1920:1080:flags=lanczos,setsar=1,format=yuv420p" -r 24 \
      -c:v libx264 -preset slow -crf 12 $BT709 -an "$MZ/$s.mp4"
  done
  ffmpeg -y -v error -i shots/s08_probe.mp4 -vf "scale=1920:1080:flags=lanczos,setsar=1,format=yuv420p" -r 24 \
    -c:v libx264 -preset slow -crf 12 $BT709 -an "$MZ/s08.mp4"
  # s04 is 720p Veo -> lanczos upscale; s09 is the 1080p high take
  ffmpeg -y -v error -i shots/s04.mp4 -vf "scale=1920:1080:flags=lanczos,setsar=1,format=yuv420p" -r 24 \
    -c:v libx264 -preset slow -crf 12 $BT709 -an "$MZ/s04.mp4"
  ffmpeg -y -v error -i shots/s09_high.mp4 -vf "scale=1920:1080:flags=lanczos,setsar=1,format=yuv420p" -r 24 \
    -c:v libx264 -preset slow -crf 12 $BT709 -an "$MZ/s09.mp4"
  # graphics: PNG full-range -> tv-range bt709 (PNG input ONLY)
  for pair in "g1:g1_mark" "g2:g2_icons" "g3:g3_endcard"; do
    short="${pair%%:*}"; seg="${pair##*:}"
    ffmpeg -y -v error -framerate 24 -start_number 0 -i graphics/frames/$seg/f%04d.png \
      -vf "scale=in_range=full:out_range=tv:out_color_matrix=bt709,format=yuv420p" \
      -c:v libx264 -preset slow -crf 12 $BT709 -an "$MZ/$short.mp4"
  done
  # ambience beds from Veo native audio
  ffmpeg -y -v error -i shots/s04.mp4 -vn -c:a pcm_s16le -ar 48000 -ac 2 "$MZ/bed_s04.wav"
  ffmpeg -y -v error -i shots/s09_high.mp4 -vn -c:a pcm_s16le -ar 48000 -ac 2 "$MZ/bed_s09.wav"
  for f in "$MZ"/*.mp4; do
    printf "%s " "$f"; ffprobe -v error -show_entries format=duration -of csv=p=0 "$f"
  done
}

# Compute xfade offsets from actual mezzanine durations; emit shot start times too.
compute() {
  local -n _offs=$1; local -n _starts=$2
  local t=0 prev_end=0
  _offs=(); _starts=()
  for i in "${!ORDER[@]}"; do
    local d
    d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MZ/${ORDER[$i]}.mp4")
    if [ "$i" -eq 0 ]; then _starts+=(0); prev_end=$d
    else
      local off; off=$(awk -v e="$prev_end" -v f="$FADE" 'BEGIN{printf "%.6f", e-f}')
      _offs+=("$off"); _starts+=("$off")
      prev_end=$(awk -v o="$off" -v d="$d" 'BEGIN{printf "%.6f", o+d}')
    fi
  done
  TOTAL="$prev_end"
}

build_graph() {
  declare -a OFFS STARTS; compute OFFS STARTS
  echo "shot starts: ${STARTS[*]}  total: $TOTAL" >&2
  # video inputs 0..11, then VO inputs, then beds
  local g="" prev="[0:v]"
  for i in $(seq 1 11); do
    local out="[v$i]"; [ "$i" -eq 11 ] && out="[vout]"
    g+="${prev}[${i}:v]xfade=transition=fade:duration=${FADE}:offset=${OFFS[$((i-1))]}${out};"
    prev="[v$i]"
  done
  # VO cues: input-index:delay-ms — trailer flow, max gap ~3s (two deliberate breaths)
  # STARTS slots: S1=0 S2=1 G1=2 S3=3 S4=4 S5=5 S6=6 S7=7 G2=8 S8=9 S9=10 G3=11
  local cues=(
    "12:$(ms "${STARTS[0]}" 1.00)"  "13:$(ms "${STARTS[2]}" -0.48)"
    "14:$(ms "${STARTS[3]}" 2.60)"  "15:$(ms "${STARTS[4]}" -0.70)"
    "16:$(ms "${STARTS[5]}" -1.20)" "17:$(ms "${STARTS[6]}" 1.15)"
    "18:$(ms "${STARTS[7]}" 3.10)"  "19:$(ms "${STARTS[9]}" 2.55)"
    "20:$(ms "${STARTS[10]}" 1.50)" "21:$(ms "${STARTS[11]}" 2.20)"
  )
  local mix="" n=0
  for c in "${cues[@]}"; do
    local idx="${c%%:*}" d="${c##*:}"
    g+="[${idx}:a]adelay=${d}|${d}[vo$n];"
    mix+="[vo$n]"; n=$((n+1))
  done
  # beds: s04 under S4, s09 under S9->end, faded, low
  local b4 b9
  b4=$(ms "${STARTS[4]}" 0); b9=$(ms "${STARTS[10]}" 0)
  g+="[22:a]volume=0.45,afade=t=in:d=1.2,afade=t=out:st=6.8:d=1.2,adelay=${b4}|${b4}[bed4];"
  g+="[23:a]volume=0.40,afade=t=in:d=1.5,adelay=${b9}|${b9}[bed9];"
  g+="[24:a]volume=0.45[mus];"
  g+="${mix}[bed4][bed9][mus]amix=inputs=$((n+3)):normalize=0,loudnorm=I=-14:TP=-1.5:LRA=11,afade=t=out:st=$(awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t-0.45}'):d=0.45[aout]"
  GRAPH="$g"
}

ms() { awk -v s="$1" -v o="$2" 'BEGIN{printf "%d", (s+o)*1000}'; }

inputs() {
  INP=()
  for s in "${ORDER[@]}"; do INP+=(-i "$MZ/$s.mp4"); done
  for l in v2_line01 v2_line02 v2_line03 v2_line04 v2_line05 v2_line06 v2_line07 line_discretion v2_line10 v2_line11; do
    INP+=(-i "audio/vo/$l.wav")
  done
  INP+=(-i "$MZ/bed_s04.wav" -i "$MZ/bed_s09.wav" -i "audio/music/bed.wav")
}

preview() {
  build_graph; inputs
  GRAPH="$GRAPH;[vout]scale=960:540[vsmall]"
  ffmpeg -y -v error "${INP[@]}" -filter_complex "$GRAPH" -map "[vsmall]" -map "[aout]" \
    -c:v libx264 -preset ultrafast -crf 28 -c:a aac -b:a 128k -r 24 out/preview.mp4
  echo "preview: $(ffprobe -v error -show_entries format=duration -of csv=p=0 out/preview.mp4)s"
}

master() {
  build_graph; inputs
  ffmpeg -y -v error "${INP[@]}" -filter_complex "$GRAPH" -map "[vout]" -map "[aout]" \
    -c:v libx264 -preset slower -crf 18 -pix_fmt yuv420p \
    -x264-params "aq-mode=3:aq-strength=1.0:deblock=-1,-1" \
    $BT709 -c:a aac -b:a 192k -movflags +faststart -r 24 out/miles-intro-master.mp4
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height,avg_frame_rate,color_space,color_transfer -show_entries format=duration -of default=nw=1 out/miles-intro-master.mp4
}

web() {
  local D BITR MAXR
  D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 out/miles-intro-master.mp4)
  # 10MiB budget: (83886080 bits * 0.97 container margin - 64k audio) / duration
  BITR=$(awk -v d="$D" 'BEGIN{printf "%dk", (83886.08*0.97/d - 64)}')
  MAXR=$(awk -v d="$D" 'BEGIN{printf "%dk", (83886.08*0.97/d - 64)*1.45}')
  echo "duration=$D video bitrate=$BITR max=$MAXR"
  ffmpeg -y -v error -i out/miles-intro-master.mp4 -c:v libvpx-vp9 -pix_fmt yuv420p \
    -b:v "$BITR" -maxrate "$MAXR" -deadline good -cpu-used 4 -row-mt 1 -tile-columns 2 -g 240 -aq-mode 2 \
    $BT709 -passlogfile work/vp9 -pass 1 -an -f null /dev/null
  ffmpeg -y -v error -i out/miles-intro-master.mp4 -c:v libvpx-vp9 -pix_fmt yuv420p \
    -b:v "$BITR" -maxrate "$MAXR" -deadline good -cpu-used 2 -row-mt 1 -tile-columns 2 -g 240 -aq-mode 2 \
    $BT709 -passlogfile work/vp9 -pass 2 -c:a libopus -b:a 64k /d/Miles/web/miles-intro.webm
  ls -la /d/Miles/web/miles-intro.webm
}

poster() {
  local T="${2:-50.5}"
  ffmpeg -y -v error -ss "$T" -i out/miles-intro-master.mp4 -frames:v 1 work/poster-src.png
  ffmpeg -y -v error -i work/poster-src.png -vf "scale=1600:900" -q:v 4 /d/Miles/web/assets/img/film-poster.jpg
  ls -la /d/Miles/web/assets/img/film-poster.jpg
}

"$@"
