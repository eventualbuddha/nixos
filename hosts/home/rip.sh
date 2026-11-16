# rip -- list a disc's titles, then rip the one(s) you pick onto the NAS.
#
#   rip              show the disc name and its titles (longest marked *)
#   rip 3            rip title 3
#   rip 3 7          rip titles 3 and 7
#   rip main         rip the longest title
#   rip all          rip every title over makemkvcon's minimum length
#   rip eject        eject the disc
#   rip backup       copy the whole disc, decrypted, to $RIP_DIR/<name>/backup/
#                    in one pass; after that, `rip` and `rip <#...>` with the
#                    same RIP_NAME read the backup instead of the drive
#
# Backups are for slow or flaky discs: every `rip` invocation rescans the
# disc (twice, with the info step), which on some box-set sides takes ~7 min
# a scan; a backup scans once, and the titles then come out of it in seconds.
# A backup is ~the whole disc (4-8 GB DVD, 25-50 GB Blu-ray); `rm -r` it with
# the rest of the disc's folder.
#
# makemkvcon reports "Operation successfully completed" even when titles
# failed, so both rips and backups also check its output for read errors and
# fail loudly. A failed backup is left as backup.partial/ (with its log), and
# is never read from.
#
# Output goes to $RIP_DIR/<disc name>/ (default: the NAS's Videos/Rips), named
# by makemkvcon (title_t03.mkv ...). Box sets often give every disc the same
# label: RIP_NAME="Show S1D1A" rip ... picks the folder name instead.
# Renaming into Movies/ or TV/ is left to you, on purpose: telling the feature
# from the decoy playlists some discs carry, and which film it actually is, is
# the part automation gets wrong.
#
# Packaged by configuration.nix (writeShellApplication adds `set -euo pipefail`
# and puts makemkvcon/awk/eject on PATH).

RIP_DIR="${RIP_DIR:-$RIP_DIR_DEFAULT}"
DEVICE="${RIP_DEVICE:-/dev/sr0}"
SOURCE="dev:$DEVICE"

die() {
  echo "rip: $*" >&2
  exit 1
}

# Robot-mode disc scan. Lines we use (attribute ids from makemkvcon's apdefs):
#   CINFO:2,0,"Disc name"     CINFO:32,0,"VOLUME_LABEL"
#   TINFO:<t>,8,0,"chapters"  TINFO:<t>,9,0,"h:mm:ss"  TINFO:<t>,10,0,"size"
scan() {
  makemkvcon -r --cache=1 info "$SOURCE" 2>/dev/null || true
}

field() { # field <id> -- a CINFO value
  awk -F'"' -v id="$1" 'index($0, "CINFO:" id ",") == 1 { print $2; exit }'
}

titles() { # -> "t<TAB>duration<TAB>seconds<TAB>chapters<TAB>size"
  awk -F'"' '
    /^TINFO:/ {
      split(substr($1, 7), k, ",")
      t = k[1]; a = k[2]; seen[t] = 1
      if (a == 8)  ch[t] = $2
      if (a == 9)  { dur[t] = $2; n = split($2, p, ":"); s = 0
                     for (i = 1; i <= n; i++) s = s * 60 + p[i]; secs[t] = s }
      if (a == 10) size[t] = $2
    }
    END { for (t in seen) printf "%s\t%s\t%d\t%s\t%s\n", t, dur[t], secs[t], ch[t], size[t] }
  ' | sort -n
}

disc_name() { # a filesystem-safe directory name for this disc
  local info="$1" name
  name="$(field 2 <<<"$info")"
  [[ -n "$name" ]] || name="$(field 32 <<<"$info")"
  [[ -n "$name" ]] || name="disc-$(date +%Y%m%d-%H%M%S)"
  tr '/:' '__' <<<"$name"
}

longest() { sort -t$'\t' -k3,3n | tail -n1 | cut -f1; }

no_titles() { # <info> -- explain an empty scan and exit
  # MSG lines carry makemkvcon's own explanation (no disc, expired key, ...).
  grep '^MSG:' <<<"$1" | awk -F'"' '{ print $2 }' >&2 || true
  die "no titles found on $SOURCE"
}

# makemkvcon <args...>, failing if it failed OR reported read errors (it exits
# 0 and says "successfully completed" for a title it couldn't read). The log
# keeps its full output.
makemkv_checked() { # <log> <args...>
  local log=$1
  shift
  makemkvcon --progress=-same "$@" 2>&1 | tee "$log"
  if grep -qE "errors of type|Failed to save title|titles saved, [1-9][0-9]* failed|Failed to open disc" "$log"; then
    die "makemkvcon reported errors (log: $log)"
  fi
}

backup() {
  local name info dest
  if [[ -n ${RIP_NAME:-} ]]; then
    name=$RIP_NAME
  else
    info="$(scan)"
    [[ -n "$(titles <<<"$info")" ]] || no_titles "$info"
    name="$(disc_name "$info")"
  fi
  [[ $name != */* ]] || die "RIP_NAME can't contain slashes: '$name'"
  dest="$RIP_DIR/$name/backup"
  [[ -e $dest ]] && die "already backed up: $dest"
  mkdir -p "$RIP_DIR/$name"
  rm -rf "$dest.partial"
  echo "rip: backing up $DEVICE -> $dest/"
  makemkv_checked "$RIP_DIR/$name/backup.log" backup --decrypt "$SOURCE" "$dest.partial"
  mv "$dest.partial" "$dest"
  echo "rip: backed up: $dest"
  echo "  RIP_NAME=\"$name\" rip      # list its titles (from the backup, not the drive)"
}

case "${1:-}" in
  eject)
    eject "$DEVICE"
    exit 0
    ;;
  backup)
    backup
    exit 0
    ;;
esac

# A backup made by `rip backup` stands in for the drive.
if [[ -n ${RIP_NAME:-} && -d "$RIP_DIR/$RIP_NAME/backup" ]]; then
  SOURCE="file:$RIP_DIR/$RIP_NAME/backup"
  echo "rip: reading the backup, not the drive: $RIP_DIR/$RIP_NAME/backup/" >&2
fi

info="$(scan)"
table="$(titles <<<"$info")"
[[ -n "$table" ]] || no_titles "$info"

name="${RIP_NAME:-$(disc_name "$info")}"
[[ $name != */* ]] || die "RIP_NAME can't contain slashes: '$name'"
main="$(longest <<<"$table")"

if [[ $# -eq 0 ]]; then
  echo "Disc: $name   (volume label: $(field 32 <<<"$info"))"
  echo
  printf '  %-4s %-9s %-9s %s\n' "#" "length" "chapters" "size"
  while IFS=$'\t' read -r t dur _ ch size; do
    mark=" "
    [[ "$t" == "$main" ]] && mark="*"
    printf '%s %-4s %-9s %-9s %s\n' "$mark" "$t" "$dur" "$ch" "$size"
  done <<<"$table"
  echo
  echo "rip <#...> | rip main | rip all    -> $RIP_DIR/$name/"
  echo "Several near-identical long titles usually means decoy playlists: check"
  echo "chapter counts, or open the disc in the GUI (waypipe ssh home makemkv)."
  exit 0
fi

out="$RIP_DIR/$name"
case "$1" in
  main) set -- "$main" ;;
  all) set -- all ;;
esac

# makemkvcon names files <title name>_tNN.mkv by title number, so a second
# disc with the same label would overwrite the first one's _t00. Refuse only
# that collision: ripping a disc's titles one at a time into its folder is
# fine.
for t in "$@"; do
  if [[ $t == all ]]; then
    pat="$out/*.mkv"
  else
    pat="$out/*_t$(printf %02d "$t").mkv"
  fi
  if compgen -G "$pat" >/dev/null; then
    die "$out/ already has a rip of title $t (another disc with this label?); set RIP_NAME"
  fi
done
mkdir -p "$out"

for t in "$@"; do
  if [[ "$t" != all ]] && ! cut -f1 <<<"$table" | grep -qx "$t"; then
    die "no title $t on this disc (run \`rip\` to list them)"
  fi
  echo "rip: title $t -> $out/"
  makemkv_checked "$out/rip-title-$t.log" mkv "$SOURCE" "$t" "$out"
done

echo "rip: done: $out"
