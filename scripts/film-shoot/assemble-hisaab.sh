#!/usr/bin/env bash
# Assemble HISAAB (~90.2s): trims -> hard-cut concat -> score/voice mix -> subs.
# Usage: bash assemble-hisaab.sh mezz | cut | preview | master | vertical
set -e
cd /d/Miles/scripts/film-shoot
export PATH="$LOCALAPPDATA/Microsoft/WinGet/Links:$PATH"
BT709="-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv"
MZ=work/hmz; mkdir -p "$MZ" out
NARR="${NARR:-work/narration.wav}"; SUBS="${SUBS:-subs.ass}"; SFX="${SFX:-}"

# name:kind:src/seg:start:dur  (hard cuts; order = the film; v2 — the sister-swipe cut)
# VID entries: start offset into the clip, then trim duration.
TL=(
  "t01:GRAPH:ui_swipe:0.55:2.0"
  "t02:GRAPH:title_card:0:2.5"
  "t03:VID:shots/h_k03.mp4:0:3.5"
  "t04:VID:shots/h_k04.mp4:0.3:4.0"
  "t05:VID:shots/h_k05.mp4:0.3:3.5"
  "t06:VID:shots/h_k06.mp4:0.5:3.5"
  "t07:VID:shots/h_k07.mp4:0.5:4.0"
  "t08:VID:shots/h_k12.mp4:0.5:3.0"
  "t09:GRAPH:ui_chat:0.5:4.0"
  "t10:VID:shots/h_k11.mp4:0:3.0"
  "t11:VID:shots/h_k14.mp4:0.3:4.0"
  "t13:VID:shots/h_k17n.mp4:0.5:3.0"
  "t14:VID:shots/h_k01.mp4:0.7:3.5"
  "t15:GRAPH:ui_picker:0:4.0"
  "t16:VID:shots/h_k13.mp4:0.5:3.5"
  "t17:VID:shots/new_zoya_burst.mp4:0:3.5"
  "t18:VID:shots/new_thumb_edge.mp4:0:1.8"
  "t19:GRAPH:ui_swipe:0:3.0"
  "t20:VID:shots/new_sisters.mp4:0:4.5"
  "t21:VID:shots/h_k19n.mp4:0.5:4.0"
  "t22:VID:shots/h_k20.mp4:0.3:4.0"
  "t23:GRAPH:g1_mark:0:5.0"
  "t24:GRAPH:g3_endcard:0:6.5"
)

mezz() {
  for e in "${TL[@]}"; do
    IFS=: read -r name kind src start dur <<< "$e"
    if [ "$kind" = "GRAPH" ]; then
      ffmpeg -y -v error -framerate 24 -start_number 0 -i "graphics/frames/$src/f%04d.png" \
        -ss "$start" -t "$dur" -vf "scale=in_range=full:out_range=tv:out_color_matrix=bt709,format=yuv420p" \
        -c:v libx264 -preset slow -crf 12 $BT709 -an "$MZ/$name.mp4"
    else
      if [ ! -f "$src" ]; then echo "SKIP $name ($src missing)"; continue; fi
      ffmpeg -y -v error -ss "$start" -i "$src" -t "$dur" \
        -vf "scale=1920:1080:flags=lanczos,setsar=1,format=yuv420p" -r 24 \
        -c:v libx264 -preset slow -crf 12 $BT709 -an "$MZ/$name.mp4"
    fi
    printf "%s " "$name"; ffprobe -v error -show_entries format=duration -of csv=p=0 "$MZ/$name.mp4"
  done
}

cut() {
  : > "$MZ/list.txt"
  for e in "${TL[@]}"; do IFS=: read -r name _ <<< "$e"; echo "file '$name.mp4'" >> "$MZ/list.txt"; done
  ffmpeg -y -v error -f concat -safe 0 -i "$MZ/list.txt" -c copy "$MZ/picture.mp4"
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$MZ/picture.mp4"
}

# audio: score + Ammi O.S. call @2.30 + narrator @78.90
mix_graph() {
  GRAPH="[1:a]volume=1.0[mus];\
[2:a]lowpass=f=3000,volume=1.25,adelay=34080|34080[call];\
[3:a]volume=1.1[story];[mus][call][story]amix=inputs=3:normalize=0,loudnorm=I=-14:TP=-1.5:LRA=11,afade=t=out:st=82.3:d=0.8[aout]"
}

preview() {
  mix_graph
  ffmpeg -y -v error -i "$MZ/picture.mp4" -i audio/music/hisaab-score.wav \
    -i audio/vo/ammi_call.wav -i "$NARR" \
    -filter_complex "$GRAPH;[0:v]subtitles=$SUBS,scale=960:540[vs]" \
    -map "[vs]" -map "[aout]" -c:v libx264 -preset ultrafast -crf 28 -c:a aac -b:a 128k -r 24 out/hisaab-preview$SFX.mp4
  ffprobe -v error -show_entries format=duration -of csv=p=0 out/hisaab-preview$SFX.mp4
}

master() {
  mix_graph
  ffmpeg -y -v error -i "$MZ/picture.mp4" -i audio/music/hisaab-score.wav \
    -i audio/vo/ammi_call.wav -i "$NARR" \
    -filter_complex "$GRAPH;[0:v]subtitles=$SUBS[vs]" \
    -map "[vs]" -map "[aout]" \
    -c:v libx264 -preset slower -crf 18 -pix_fmt yuv420p \
    -x264-params "aq-mode=3:aq-strength=1.0:deblock=-1,-1" \
    $BT709 -c:a aac -b:a 192k -movflags +faststart -r 24 out/hisaab-master$SFX.mp4
  ffmpeg -y -v error -i out/hisaab-master$SFX.mp4 -c copy \
    -bsf:v "h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0" \
    -movflags +faststart out/hm$SFX.mp4 && mv -f out/hm$SFX.mp4 out/hisaab-master$SFX.mp4
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height,avg_frame_rate,color_space,color_transfer,color_range -show_entries format=duration -of default=nw=1 out/hisaab-master$SFX.mp4
}

# 9:16 vertical: center-crop with per-shot x-offset would need a map; v1 = smart center crop.
vertical() {
  ffmpeg -y -v error -i out/hisaab-master$SFX.mp4 \
    -vf "crop=608:1080:(iw-608)/2:0,scale=1080:1920:flags=lanczos" \
    -c:v libx264 -preset slower -crf 19 -pix_fmt yuv420p $BT709 \
    -c:a copy -movflags +faststart out/hisaab-vertical$SFX.mp4
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 out/hisaab-vertical$SFX.mp4
}

"$@"
