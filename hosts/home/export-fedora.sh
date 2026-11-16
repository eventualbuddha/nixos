#!/usr/bin/env bash
# Run ON THE FEDORA BOX, as brian, immediately before wiping it. Captures
# everything hosts/home carries over into one directory on the NAS (via the
# existing sshfs mount). Step 1 of ./MIGRATION.md.
#
#   bash export-fedora.sh [dest]      # default: ~/mnt/readynas/Backups/home-fedora-<date>
#
# It STOPS the services to export their volumes consistently and leaves them
# stopped, so nothing written after the export is lost by the wipe. To back
# out:  systemctl --user start gitea summer-app tailscale-gitea tailscale-summer
#
# Asks for your sudo password once (tailscaled state, sshd host keys).
set -euo pipefail

dest="${1:-$HOME/mnt/readynas/Backups/home-fedora-$(date +%F)}"
mountpoint -q "$HOME/mnt/readynas" || {
  echo "NAS not mounted at ~/mnt/readynas" >&2
  exit 1
}
mkdir -p "$dest"/{volumes,gitea,summer,files}
echo "exporting to $dest"

echo "== logical dumps (services still running)"
podman exec systemd-summer-surrealdb /surreal export --log none \
  --endpoint http://127.0.0.1:8000 --namespace summer --database summer - \
  >"$dest/summer/summer.surql"
podman exec -u git -w /tmp systemd-gitea \
  gitea dump -c /data/gitea/conf/app.ini --type tar.gz -f /tmp/gitea-dump.tar.gz
podman cp systemd-gitea:/tmp/gitea-dump.tar.gz "$dest/gitea/"
podman exec systemd-gitea rm -f /tmp/gitea-dump.tar.gz
# What Forgejo needs re-created by hand: the accounts and their ssh keys.
podman exec systemd-gitea sqlite3 -header -csv /data/gitea/gitea.db \
  "select u.name, u.email, u.is_admin, k.name as key_name, k.content as key
     from user u left join public_key k on k.owner_id = u.id
    where u.type = 0 order by u.name" \
  >"$dest/gitea/users-and-keys.csv"
# Built-in ssh server host key, so gitea.<tailnet>:2222 keeps its fingerprint.
podman cp systemd-gitea:/data/gitea/ssh "$dest/gitea/ssh-host-key"

echo "== stopping services"
systemctl --user stop tailscale-summer summer-app summer-surrealdb tailscale-gitea gitea

echo "== volumes"
for v in systemd-summer systemd-tailscale-summer systemd-tailscale-gitea systemd-gitea \
  summer summer-surrealdb-data; do
  podman volume export "$v" -o "$dest/volumes/$v.tar"
done
# The built image, so summer can start before a rebuild if npm misbehaves.
podman image save localhost/summer-app:latest -o "$dest/summer/summer-app-image.tar"

echo "== home files"
cd "$HOME"
want=(notes code .ssh .config/tailscale-sidecar .MakeMKV .local/share/fish
  .bash_history .claude .claude.json .gitconfig)
have=()
for p in "${want[@]}"; do
  if [[ -e "$p" ]]; then have+=("$p"); fi
done
tar -cf "$dest/files/home.tar" --exclude='code/*/node_modules' "${have[@]}"

echo "== system state (sudo)"
# sudo's output is redirected by THIS shell (brian), which can write to the
# FUSE mount; root itself can't.
# ROOT_STAGE: a dir where root already wrote these two tarballs (for running
# this non-interactively, with root reached some other way than sudo).
if [[ -n "${ROOT_STAGE:-}" ]]; then
  cp "$ROOT_STAGE"/var-lib-tailscale.tar "$ROOT_STAGE"/etc-ssh-host-keys.tar "$dest/files/"
else
  # shellcheck disable=SC2024 # redirect as brian is the point (see above)
  sudo tar -C /var/lib -cf - tailscale >"$dest/files/var-lib-tailscale.tar"
  # shellcheck disable=SC2024
  sudo sh -c 'cd /etc/ssh && tar -cf - ssh_host_*' >"$dest/files/etc-ssh-host-keys.tar"
fi

(cd "$dest" && find . -type f ! -name SHA256SUMS -exec sha256sum {} + >SHA256SUMS)
du -sh "$dest"
echo "done. Services are left STOPPED."
