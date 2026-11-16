# rip -- list a disc's titles, then rip the one(s) you pick onto the NAS.
#
#   rip              show the disc name and its titles (longest marked *)
#   rip 3            rip title 3
#   rip 3 7          rip titles 3 and 7
#   rip main         rip the longest title
#   rip all          rip every title over makemkvcon's minimum length
#   rip eject        eject the disc
#
# Output goes to $RIP_DIR/<disc name>/ (default: the NAS's Videos/Rips), named
# by makemkvcon (title_t03.mkv ...). Renaming into Movies/ or TV/ is left to
# you, on purpose: telling the feature from the decoy playlists some discs
# carry, and which film it actually is, is the part automation gets wrong.
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

info="$(scan)"

if [[ "${1:-}" == "eject" ]]; then
  eject "$DEVICE"
  exit 0
fi

table="$(titles <<<"$info")"
if [[ -z "$table" ]]; then
  # MSG lines carry makemkvcon's own explanation (no disc, expired key, ...).
  grep '^MSG:' <<<"$info" | awk -F'"' '{ print $2 }' >&2 || true
  die "no titles found on $DEVICE"
fi

name="$(disc_name "$info")"
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
mkdir -p "$out"

case "$1" in
  main) set -- "$main" ;;
  all) set -- all ;;
esac

for t in "$@"; do
  if [[ "$t" != all ]] && ! cut -f1 <<<"$table" | grep -qx "$t"; then
    die "no title $t on this disc (run \`rip\` to list them)"
  fi
  echo "rip: title $t -> $out/"
  makemkvcon --progress=-same mkv "$SOURCE" "$t" "$out"
done

echo "rip: done: $out"
