# home: Fedora 44 → NixOS

Runbook for moving `home` (i5-10400T, 256 GB NVMe, BD-RE drive) from Fedora to
`nixosConfigurations.home`. Written and carried out 2026-11-15; steps 2-4 record what was actually run.

## What moves, what doesn't

| Fedora | NixOS | How it moves |
|---|---|---|
| summer-app + summer-surrealdb (quadlets) | same containers, home-manager `services.podman` | volume `systemd-summer` → `summer-data`; image rebuilt with `summer-rebuild` (or `podman load`) |
| tailscale-summer sidecar | same | state volume → `tailscale-summer-state` (keeps the `summer` node) |
| gitea container (1.26.2) | **Forgejo**, native | users re-created, repos adopted from the old volume, ssh host key copied |
| tailscale-gitea sidecar | `tailscale-code`, host netns | state volume → `tailscale-code-state`: the old `gitea` node, renamed to `code` |
| host tailscaled | `services.tailscale` | `/var/lib/tailscale` copied in **before first boot** (keeps `home`, 100.86.205.11) |
| sshd host keys | sshd | `/etc/ssh/ssh_host_*` copied, so no known_hosts warnings |
| readynas-sshfs user unit | CIFS automount at `/mnt/nas` | — |
| — | `rip` + makemkv | new |
| — | restic → planb | new: Forgejo dump, summer export, ~/notes, ~/code |
| copyparty, zennotes | dropped (removed 2026-11-15) | — |
| KDE, browsers, 1Password, ghostty | dropped (headless) | — |
| rustup, cargo tools, nvim, fish, starship, claude | home/core | — |

Not carried over: old pre-quadlet volumes `summer` and `summer-surrealdb-data`.
They're exported to the NAS for reference only.

## 0. Before the day

- **BIOS** (keyboard + monitor on the box): set *AC power recovery* /
  *Restore on AC power loss* to **Power On**. Without it, nothing below helps
  after a power cut. Also check that Secure Boot is **off** for the install.
- **Tailscale admin console**:
  - Remove the dead `copyparty` and `zennotes` nodes.
  - **Disable key expiry** on `home`, `code` (the renamed `gitea` node) and `summer`. An expired node key
    takes the service offline until someone logs in, which is also a manual fix.
- **planb**: add a restic credential for the new client:
  `ssh planb sudo htpasswd -B /srv/backup/restic/.htpasswd home`
  (check the path against `resticData` in hosts/planb). Save the password for step 5.
- **judy**: `nix build ~/nixos#nixosConfigurations.home.config.system.build.toplevel`
  builds cleanly as of this writing.

## 1. Export (on Fedora)

```sh
scp ~/nixos/hosts/home/export-fedora.sh home:
ssh -t home bash export-fedora.sh
```

This writes to `~/mnt/readynas/Backups/home-fedora-<date>/` on the NAS and
**leaves the services stopped**. Check `SHA256SUMS` and the sizes. You should see
a few hundred MB plus the 1.3 GB summer image.

## 2. Install with nixos-anywhere (from judy)

This was done on 2026-11-15. With Fedora still running, and root ssh from judy
working over the LAN (`ssh root@<lan ip>`):

```sh
x=$(mktemp -d); mkdir -p $x/root $x/var/lib
install -m600 <nas-smb.cred> $x/root/nas-smb.cred         # same login as the backup VM
ssh root@<lan ip> 'systemctl stop tailscaled && tar -C /var/lib -cf - tailscale' | tar -C $x/var/lib -xf -
# the LUKS passphrase, in a 600 file on judy (also into 1Password)

nix run github:nix-community/nixos-anywhere -- --flake ~/nixos#home \
  --target-host root@<lan ip> --copy-host-keys --extra-files $x \
  --disk-encryption-keys /tmp/luks.key <local passphrase file>
```

- `--extra-files` puts `/var/lib/tailscale` (the `home` node, 100.86.205.11)
  and `/root/nas-smb.cred` into the new system, owned by root.
- `--copy-host-keys` carries over the sshd host keys from Fedora.
- disko (./disko.nix) partitions the disk, and `/tmp/luks.key` becomes the
  LUKS passphrase.

What went wrong, and how to recover:
- **The kexec installer comes back on a new DHCP address**, not the Fedora one,
  so nixos-anywhere sits retrying `No route to host`. Read the address off the
  console (`ip -br a`), check that its host key matches (the kexec image keeps
  the old keys), stop the run, and resume with
  `--target-host root@<new ip> --phases disko,install,reboot` (same other flags).
- **The firmware tried PXE first** on the first reboot, because the network
  boot entries were at the top of BootOrder. Use the boot menu (F12) once to
  pick *Linux Boot Manager*, then from NixOS:
  `efibootmgr -o <Linux Boot Manager>,<UEFI OS>,…` and
  `efibootmgr -A -b <each PXE entry>`.
- **Boot hung on "A start job is running for Home Manager environment for
  brian"**, because nothing pulled in `network-online.target`, which podman's
  user units poll for. This is fixed in configuration.nix
  (`systemd.targets.network-online.wantedBy`).

First boot asks for the LUKS passphrase on the console. home keeps its
tailnet name, IP and host key. On the LAN it is now on DHCP (192.168.86.66 at
the time).

## 3. Restore user data (as brian)

```sh
x=/mnt/nas/Backups/home-fedora-<date>
tar -C ~ -xf $x/files/home.tar          # notes, code, .ssh, tailscale-sidecar/authkey.env, ...

systemctl --user stop podman-tailscale-summer podman-summer-app podman-summer-surrealdb podman-tailscale-code
podman volume import summer-data            $x/volumes/systemd-summer.tar
podman volume import tailscale-summer-state $x/volumes/systemd-tailscale-summer.tar
podman volume import tailscale-code-state   $x/volumes/systemd-tailscale-gitea.tar
podman load -i $x/summer/summer-app-image.tar     # or: summer-rebuild
systemctl --user start podman-summer-surrealdb podman-summer-app podman-tailscale-summer podman-tailscale-code
```

Check:
- `tailscale status` lists `home`, `summer` and `code`, with no `-1` suffixes
  and no `gitea`. `code` is the old `gitea` node, renamed.
- https://summer.tail42107.ts.net shows recent data. After the restore there
  were 12,144 transactions.

If summer's data looks wrong, import `$x/summer/summer.clean.surql` (the
logical dump, with log lines stripped) into an empty `summer-data`.

## 4. Forgejo (as root)

```sh
fj() { runuser -u forgejo -- forgejo --work-path /var/lib/forgejo --config /var/lib/forgejo/custom/conf/app.ini "$@"; }
```

**Host key.** Copy the old one in, so `code:2222` keeps Gitea's fingerprint
(`SHA256:T/6rEI0…`):

```sh
systemctl stop forgejo
install -o forgejo -g forgejo -m600 $x/gitea/ssh-host-key/gitea.rsa* /var/lib/forgejo/data/ssh/
systemctl start forgejo
```

**Users.** The emails are in `$x/gitea/users-and-keys.csv`. The generated
passwords went to `/root/forgejo-initial-passwords.txt`. Send madeline theirs,
then delete the file.

```sh
fj admin user create --admin --username brian --email … --random-password
fj admin user create --username madeline --email … --random-password --must-change-password
```

**SSH keys and repos** go through the admin API, using a short-lived token:

```sh
tok=$(fj admin user generate-access-token --username brian --token-name migrate \
        --scopes write:admin,write:repository --raw | tail -1)
api() { curl -s -H "Authorization: token $tok" -H 'Content-Type: application/json' "$@"; }

# each user's key from the CSV (plus judy's Yubikey key for brian)
api -X POST -d '{"title":"…","key":"ssh-ed25519 …"}' http://127.0.0.1:3300/api/v1/admin/users/<user>/keys
```

The repos are **adopted** rather than pushed, so madeline's land under their
account directly. Copy the bare repos out of the old Gitea volume into
Forgejo's repository root, then adopt each one:

```sh
t=$(mktemp -d); tar -C $t -xf $x/volumes/systemd-gitea.tar
cp -a $t/git/repositories/{brian,madeline} /var/lib/forgejo/repositories/
chown -R forgejo:forgejo /var/lib/forgejo/repositories
api -X POST http://127.0.0.1:3300/api/v1/admin/unadopted/<owner>/<repo>   # for each of the 6
fj admin regenerate hooks
```

Adoption lowercases names and doesn't keep visibility. Restore both with
`PATCH /api/v1/repos/<owner>/<repo>` and `{"name": …, "private": …}`, using the
values from the old `repository` table (`$t/gitea/gitea.db`):
- `media-tools` and `dotfiles` are private; the rest are public.
- madeline's repos are named `MadReminders` and `WorkLinkRouter`.

Afterwards, remove the token. Stop forgejo, run
`delete from access_token` in `/var/lib/forgejo/data/forgejo.db`, and start it
again. Then `rm -rf $t`.

Check: `git ls-remote ssh://git@code.tail42107.ts.net:2222/brian/summer.git`
from judy.

## 5. Backups

```sh
sudo install -d -m700 /root/restic
head -c32 /dev/urandom | base64 | sudo tee /root/restic/home.pass >/dev/null   # into 1Password
printf 'RESTIC_REST_USERNAME=home\nRESTIC_REST_PASSWORD=<from step 0>\n' | sudo tee /root/restic/home.env >/dev/null
sudo chmod 600 /root/restic/*
sudo systemctl start forgejo-dump restic-backups-home
journalctl -u restic-backups-home -e
```

The summer export in `backupPrepareCommand` is the step most likely to need a
tweak: the `surreal export` flags, and running podman as brian from root. Check
that `/var/backup/summer/summer.surql` is non-empty after the first run.

## 6. Secure Boot + TPM2 (unattended reboots)

```sh
sudo sbctl create-keys                       # into /var/lib/sbctl
# hosts/home/configuration.nix: secureBoot = true;  then deploy from judy:
nixos-rebuild switch --flake ~/nixos#home --target-host home --sudo
sudo sbctl verify       # all signed except /boot/EFI/nixos/kernel-*: expected, lanzaboote's signed stub checks it by hash
```

Reboot into firmware setup. Enable Secure Boot and put it in **Setup Mode**
(clear / delete the factory keys). Boot back into NixOS (with the passphrase), then:

```sh
sudo sbctl enroll-keys --microsoft           # --microsoft keeps option ROMs (GPU/NIC) working
sudo reboot
bootctl status | grep -i 'secure boot'       # enabled (user)
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/cryptroot
```

**Then test it for real.** Pull the power cord and plug it back in. The box should
power on by itself, unlock with no prompt, and have summer and code answering
on the tailnet within a couple of minutes, all without a login.

Firmware updates or Secure Boot changes alter PCR 7. After one, the next boot
asks for the passphrase. Re-enroll with
`systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 …`.

## 7. Ripping

```sh
# once: put the MakeMKV key in ~/.MakeMKV/settings.conf ->  app_Key = "T-..."
rip            # disc name + titles; longest marked *
rip main       # or: rip 3 / rip 3 7 / rip all   ->  /mnt/nas/Videos/Rips/<disc>/
rip eject
```

When a disc needs the GUI, use `waypipe ssh home makemkv` from judy.

## 8. Encoding and the Infuse library

`Videos/` on the NAS is laid out for Infuse:

| Folder | Infuse source on | Holds |
|---|---|---|
| `Movies/` | Apple TV | one copy of each film, the best one, as `Title (Year).ext` (flat, no per-film folders) |
| `Mobile/` | iPad | one copy of each film small enough to download: hardlinks to `Movies/` files of 4 GB or less, plus separate encodes for the big ones |
| `Rips/`, `.encoding/`, `REPLACED/` | none | raw MakeMKV output, encodes in progress, superseded copies |

```sh
encode tv   Rips/<disc>/<title>.mkv "Title (Year)"   # HEVC library copy -> Movies/
encode file Rips/<disc>/<title>.mkv "Title (Year)"   # or keep the remux as is -> Movies/
encode ipad Rips/<disc>/<title>.mkv "Title (Year)"   # iPad copy -> Mobile/ (for big films)
encode status                                        # progress; they run as user units
ENCODE_SAMPLE=60 encode tv ...                       # a 60 s test, left in .encoding/
encode mobile-sync                                   # link anything new in Movies/ into Mobile/
```

`tv` and `file` run `mobile-sync` themselves. `mobile-sync` does its linking
**on the NAS**, over ssh as root with `~/.ssh/readynas_sshfs`. Through the
CIFS mount, `ln` fails for any name with a colon or question mark. On disk a
`:` is either a literal colon or U+F022 (how macOS writes it); Samba shows
both as the same name, and mobile-sync treats them as equal.

2026-11-15 cleanup:
- The Plex and Channels DVR ReadyNAS apps were purged along with their data:
  `.apps/plexmediaserver`, `.apps/channels-dvr`, `Videos/channels-data` and
  `Movies/Plex Versions`.
- The 9 useful Plex "Optimized for TV" encodes became `Mobile/` copies, renamed
  to match their `Movies/` names.
- Smaller duplicate copies moved from `Movies/` to `Mobile/`.
- Old .avi files that have a better .m4v moved to `REPLACED/`.
