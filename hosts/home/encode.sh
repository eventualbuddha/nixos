# encode -- turn a rip into the copy Infuse plays, an iPad copy, or file it as-is.
#
#   encode tv   <rip.mkv> "Title (Year)"  HEVC 10-bit at source resolution, all
#                                         audio passed through, subs kept
#                                         (English only; see ENCODE_LANGS)
#                                         -> Movies/Title (Year).mkv
#   encode ipad <rip.mkv> "Title (Year)"  1080p MP4, AAC stereo + AC-3 5.1,
#                                         forced subs burned in
#                                         -> Mobile/Title (Year).mp4
#   encode file <rip.mkv> "Title (Year)"  no encode: move the rip itself
#                                         -> Movies/Title (Year).mkv
#   encode episode <rip.mkv> "Show" S01E02 "Episode Title" [chapters]
#                                         as tv, for a TV episode; chapters
#                                         (e.g. 5-8) picks one episode out of
#                                         a title that holds several
#                                         -> TV/Show/Season 1/
#                                            Show - S01E02 - Episode Title.mkv
#   encode status                        running encodes and progress; recent results
#   encode log                            HandBrake's log (journal)
#   encode stop                           stop every running encode
#   encode mobile-sync                    hardlink every Movies/ film of 4 GB or less
#                                         with no Mobile/ copy into Mobile/
#
#   ENCODE_SAMPLE=60 encode tv ...       just 60 s from 20 min in, left in
#                                         Videos/.encoding/ to judge quality/size
#
# Infuse sources: the Apple TV gets Movies/ (one copy of each film, the best
# one); the iPad gets Mobile/ (one copy of each film, small enough to
# download). Rips/ and .encoding/ are in no source.
#
# Mobile/ is mostly hardlinks into Movies/: a film that is already small takes
# no extra space there. Only films too big for the iPad get a separate file
# (`encode ipad`). `tv` and `file` link their result in when it is small enough,
# and `mobile-sync` catches up on anything added by hand. Links only get added:
# renaming or deleting a Movies/ copy leaves its Mobile/ link as it was.
#
# TV/ is its own Infuse source on both devices; episodes are not linked into
# Mobile/, which is films only. An SD (DVD) source is deinterlaced/detelecined
# in every mode: HandBrake leaves combing in otherwise.
#
# tv, ipad and episode run as transient systemd user units (encode-<mode>-<name>), so
# they survive logging out; linger keeps the user manager up. They write to
# Videos/.encoding/ and are renamed into place only when finished, so Infuse
# never sees a half-written file. Same share, so the rename is instant.
# Nothing is ever overwritten, and the rip is never deleted: once the result
# checks out, `rm -r` the Rips/<disc>/ folder yourself.
#
# Packaged by configuration.nix (writeShellApplication adds `set -euo pipefail`
# and puts HandBrakeCLI/ffprobe/systemd on PATH).

VIDEOS="${VIDEOS:-$VIDEOS_DEFAULT}"
STAGE="$VIDEOS/.encoding"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/encode"
# Audio and subtitle languages to keep (ISO 639-2), e.g. ENCODE_LANGS=eng,jpn
# for an anime with its original track. HandBrake falls back to the first
# track when none match.
LANGS="${ENCODE_LANGS:-eng}"
SAMPLE="${ENCODE_SAMPLE:-}"
# Largest Movies/ file mobile-sync links into Mobile/ as is.
MOBILE_MAX=$((${ENCODE_MOBILE_MAX_GB:-4} * 1024 * 1024 * 1024))
# The NAS, for mobile-sync (see below): ssh target, key, and where Videos/ is there.
NAS_SSH="${ENCODE_NAS_SSH:-$NAS_SSH_DEFAULT}"
NAS_KEY="${ENCODE_NAS_KEY:-$HOME/.ssh/readynas_sshfs}"
NAS_VIDEOS="${ENCODE_NAS_VIDEOS:-/data/Videos}"

die() {
  echo "encode: $*" >&2
  exit 1
}

usage() {
  awk '/^# encode --/ { on = 1 } on { sub(/^# ?/, ""); print } /to judge quality/ { exit }' "$(readlink -f "$0")"
  exit "${1:-0}"
}

check_name() {
  [[ -n $1 && $1 != */* && $1 != .* ]] || die "name must be like \"Title (Year)\", no slashes: '$1'"
}

dest_for() { # <mode> <name> [show] [season]
  case $1 in
    tv | file) echo "$VIDEOS/Movies/$2.mkv" ;;
    ipad) echo "$VIDEOS/Mobile/$2.mp4" ;;
    episode) echo "$VIDEOS/TV/$3/Season $4/$2.mkv" ;;
  esac
}

# The linking runs ON THE NAS, over ssh: through the CIFS mount, `ln` fails for
# any name with a character SMB maps (`:` `?` ...), which is a lot of titles.
# On the NAS's own filesystem the names are just names, and the whole pass
# takes a second instead of minutes.
#
# Hardlink every Movies/ film (and its .srt sidecars) that is small enough and
# has no Mobile/ copy yet. Args: <Videos dir on the NAS> <max bytes>.
# shellcheck disable=SC2016 # expanded by the NAS's shell, not this one
MOBILE_SYNC_REMOTE='
set -u
V=$1 max=$2 n=0 big=0 have=0 failed=0
# On disk a ":" is either itself or U+F022 (how macOS writes it over SMB);
# Samba shows both as the same name, so compare names with U+F022 folded to ":".
norm() { sed "s/$(printf "\357\200\242")/:/g"; }
mkdir -p "$V/Mobile"
have_list=$(mktemp)
trap "rm -f $have_list" EXIT
ls "$V/Mobile" | sed -n "s/\.\(mkv\|mp4\|m4v\|avi\|mov\|MKV\|MP4\|M4V\|AVI\|MOV\)$//p" | norm >"$have_list"
has_mobile() { printf "%s\n" "$1" | norm | grep -qxF -f - "$have_list"; }
for f in "$V/Movies"/*; do
  [ -f "$f" ] || continue
  base=${f##*/} stem=${f##*/}
  stem=${stem%.*}
  case $(printf %s "${base##*.}" | tr A-Z a-z) in mkv | mp4 | m4v | avi | mov) ;; *) continue ;; esac
  if [ "$(stat -c %s "$f")" -gt "$max" ]; then
    if has_mobile "$stem"; then have=$((have + 1)); else big=$((big + 1)); fi
    continue
  fi
  has_mobile "$stem" && continue
  if ln "$f" "$V/Mobile/$base"; then
    for s in "$V/Movies/$stem".srt "$V/Movies/$stem".*.srt; do
      [ -e "$s" ] && [ ! -e "$V/Mobile/${s##*/}" ] && ln "$s" "$V/Mobile/${s##*/}"
    done
    printf "%s\n" "$stem" | norm >>"$have_list"
    echo "linked  $base"
    n=$((n + 1))
  else
    failed=$((failed + 1))
  fi
done
echo "mobile-sync: $n newly linked, $failed failed; $big too big with no Mobile/ copy (encode ipad), $have big with one"
[ "$failed" -eq 0 ]
'

mobile_sync() {
  ssh -i "$NAS_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR "$NAS_SSH" \
    sh -s -- "'$NAS_VIDEOS'" "$MOBILE_MAX" <<<"$MOBILE_SYNC_REMOTE"
}

unit_for() { # <mode> <name> -> encode-tv-Project-Hail-Mary-2026
  local slug
  slug=$(printf '%s' "$2" | tr -cs 'A-Za-z0-9' '-')
  slug=${slug%-}
  echo "encode-$1-$slug"
}

height() {
  ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$1" | head -1
}

# HandBrake's number (1-based) of the first audio track in LANGS, else 1.
first_audio() {
  ffprobe -v error -select_streams a -show_entries stream_tags=language -of csv=p=0 "$1" |
    awk -v langs=",$LANGS," 'index(langs, "," $1 ",") { print NR; found = 1; exit } END { if (!found) print 1 }'
}

note() { # one line into the history `encode status` shows
  mkdir -p "$STATE"
  printf '%s  %s\n' "$(date '+%F %R')" "$*" >>"$STATE/history"
}

# --- inside the unit ---------------------------------------------------------

run() { # _run <mode> <src> <name> <dest> [chapters]
  local mode=$1 src=$2 name=$3 dest=$4 chapters=${5:-} tmp progress h
  tmp="$STAGE/$name.$mode.${dest##*.}"
  if [[ -n $SAMPLE ]]; then
    tmp="$STAGE/$name.$mode.sample.${dest##*.}"
  fi
  progress="$STATE/$(unit_for "$mode" "$name").progress"
  mkdir -p "$STAGE" "$STATE"

  h=$(height "$src")
  local -a args
  case $mode in
    tv | episode)
      # RF 20 is near-transparent for 1080p; 4K holds up at 22.
      args=(--format av_mkv --markers
        -e x265_10bit --encoder-preset medium -q "$([[ $h -gt 1100 ]] && echo 22 || echo 20)"
        --crop-mode conservative
        --audio-lang-list "$LANGS" --all-audio -E copy --audio-copy-mask "aac,ac3,eac3,truehd,dts,dtshd,flac,mp3"
        --audio-fallback ac3
        --subtitle-lang-list "$LANGS" --all-subtitles --subtitle-burned=none)
      ;;
    ipad)
      # What HandBrake's "Apple 1080p30 Surround" preset does (H.264 High@4.1,
      # 1080p max, AAC stereo + AC-3 5.1), spelled out: the preset also turns on
      # its foreign-audio subtitle scan, which hung here. Instead, burn in only
      # the forced-flagged captions of the first matching subtitle track -- what
      # Blu-rays use for alien dialogue and signs. A 4K (HDR) source is encoded as
      # HEVC 10-bit, so its HDR survives the downscale.
      args=(--format av_mp4 --markers --optimize
        --maxWidth 1920 --maxHeight 1080 --crop-mode conservative
        -r 30 --pfr
        -a "$(first_audio "$src"),$(first_audio "$src")"
        -E "av_aac,copy:ac3" -B "160,640" -6 "stereo,none" --audio-fallback ac3
        --subtitle-lang-list "$LANGS" --first-subtitle
        --subtitle-forced --subtitle-burned)
      if [[ $h -gt 1100 ]]; then
        args+=(-e x265_10bit --encoder-preset medium -q 22)
      else
        args+=(-e x264 --encoder-preset medium --encoder-profile high
          --encoder-level 4.1 -q 22)
      fi
      ;;
  esac

  # DVDs (480i/576i) are interlaced or telecined; film-sourced HD is not.
  # detelecine restores 24p from 3:2 pulldown, and decomb deinterlaces only
  # the frames that comb-detect flags, leaving progressive ones alone.
  if [[ $h -le 576 ]]; then
    args+=(--detelecine --comb-detect --decomb)
  fi

  if [[ -n $chapters ]]; then
    args+=(--chapters "$chapters")
  fi

  # Clean up a partial file however this ends (`encode stop` sends TERM).
  trap 'rm -f "$tmp"' EXIT
  trap 'note "stopped  $mode  $name"; exit 143' TERM INT

  if [[ -n $SAMPLE ]]; then
    args+=(--start-at seconds:1200 --stop-at "seconds:$SAMPLE")
  fi

  echo "encode: $mode '$src' -> '$dest' (source ${h}p)"
  if ! HandBrakeCLI -i "$src" -o "$tmp" "${args[@]}" >"$progress"; then
    note "FAILED   $mode  $name  (encode log)"
    exit 1
  fi
  if [[ -n $SAMPLE ]]; then
    trap - EXIT
    rm -f "$progress"
    note "sample   $mode  $name  ($(du -h "$tmp" | cut -f1) for ${SAMPLE}s: $tmp)"
    return
  fi
  [[ -e $dest ]] && {
    note "FAILED   $mode  $name  ($dest appeared meanwhile)"
    exit 1
  }
  mkdir -p "$(dirname "$dest")"
  mv -n "$tmp" "$dest"
  trap - EXIT
  rm -f "$progress"
  note "done     $mode  $name  ($(du -h "$dest" | cut -f1))"
  echo "encode: done: $dest"
  if [[ $mode == tv ]]; then
    link_new
  fi
}

# After tv/file: link the new Movies/ file into Mobile/ if it qualifies. A
# failure here (NAS unreachable) only means running `encode mobile-sync` later.
link_new() {
  local out
  if out=$(mobile_sync 2>&1); then
    grep '^linked' <<<"$out" || echo "not linked into Mobile/: over $((MOBILE_MAX >> 30)) GB (encode ipad), or Mobile/ has a copy"
  else
    echo "mobile-sync failed; run it again later:"
    echo "$out" | tail -3
  fi
}

# --- commands ----------------------------------------------------------------

start() { # <mode> <src> <name>  |  episode <src> <show> <SxxEyy> <title> [chapters]
  local mode=$1 src name=$3 dest unit chapters=""
  [[ -f $2 ]] || die "no such file: $2"
  src=$(readlink -f "$2")
  if [[ $mode == episode ]]; then
    local show=$3 se=${4^^} title=$5 season
    chapters=${6:-}
    check_name "$show"
    check_name "$title"
    [[ $se =~ ^S([0-9]+)E[0-9]+(-?E[0-9]+)?$ ]] || die "episode must be like S01E02 (or S01E02-E03): '$4'"
    season=$((10#${BASH_REMATCH[1]}))
    [[ -z $chapters || $chapters =~ ^[0-9]+(-[0-9]+)?$ ]] || die "chapters must be like 5 or 5-8: '$chapters'"
    name="$show - $se - $title"
    dest=$(dest_for episode "$name" "$show" "$season")
  else
    check_name "$name"
    dest=$(dest_for "$mode" "$name")
  fi
  [[ -e $dest ]] && die "already exists: $dest"

  if [[ $mode == file ]]; then
    mkdir -p "$(dirname "$dest")"
    mv -n "$src" "$dest"
    note "filed    $name"
    echo "$dest"
    link_new
    return
  fi

  unit=$(unit_for "$mode" "$name")
  systemctl --user is-active --quiet "$unit" && die "$unit is already running"
  # Background priority: summer and Forgejo stay responsive while x265 has
  # every core.
  systemd-run --user --quiet --collect --unit "$unit" \
    -p Nice=15 -p CPUSchedulingPolicy=batch -p IOSchedulingClass=idle \
    -E VIDEOS="$VIDEOS" -E ENCODE_LANGS="$LANGS" -E ENCODE_SAMPLE="$SAMPLE" \
    -- "$(readlink -f "$0")" _run "$mode" "$src" "$name" "$dest" "$chapters"
  if [[ -n $SAMPLE ]]; then
    echo "started $unit: ${SAMPLE}s sample -> $STAGE/"
  else
    echo "started $unit -> $dest"
  fi
  echo "  encode status   # progress"
}

status() {
  local units u p
  units=$(systemctl --user list-units --plain --no-legend 'encode-*' | awk '{print $1}')
  if [[ -z $units ]]; then
    echo "no encodes running"
  fi
  for u in $units; do
    u=${u%.service}
    p="$STATE/$u.progress"
    printf '%s\n  %s\n' "$u" "$([[ -f $p ]] && tr '\r' '\n' <"$p" | grep -a 'Encoding' | tail -1 || echo starting)"
  done
  if [[ -f $STATE/history ]]; then
    echo
    echo "recent:"
    tail -5 "$STATE/history" | sed 's/^/  /'
  fi
}

case "${1:-}" in
  tv | ipad | file)
    [[ $# -eq 3 ]] || usage 1
    start "$@"
    ;;
  episode)
    [[ $# -eq 5 || $# -eq 6 ]] || usage 1
    start "$@"
    ;;
  _run)
    shift
    run "$@"
    ;;
  status | "") status ;;
  log) journalctl --user -u 'encode-*' -n 60 --no-pager ;;
  stop) systemctl --user stop 'encode-*' ;;
  mobile-sync) mobile_sync ;;
  -h | --help | help) usage ;;
  *) usage 1 ;;
esac
