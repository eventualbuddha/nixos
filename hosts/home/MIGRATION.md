# home: Fedora 44 → NixOS

Runbook for moving `home` (i5-10400T, 256 GB NVMe, BD-RE drive) from Fedora to
`nixosConfigurations.home`. Written 2026-11-15.

## What moves, what doesn't

| Fedora | NixOS | How it moves |
|---|---|---|
| summer-app + summer-surrealdb (quadlets) | same containers, home-manager `services.podman` | volume `systemd-summer` → `summer-data`; image rebuilt with `summer-rebuild` (or `podman load`) |
| tailscale-summer sidecar | same | state volume → `tailscale-summer-state` (keeps the `summer` node) |
| gitea container (1.26.2) | **Forgejo**, native | users re-created, repos pushed, ssh host key copied |
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
  (check the path against `resticData` in hosts/planb). Save the password for step 6.
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

## 2. Partition (NixOS minimal ISO)

Boot the installer. Set a root password, or add your key, so judy can reach it
over ssh. Then:

```sh
disk=/dev/nvme0n1
sgdisk --zap-all $disk
sgdisk -n1:0:+1G -t1:ef00 -c1:NIXBOOT -n2:0:0 -t2:8309 -c2:cryptroot $disk
mkfs.fat -F32 -n NIXBOOT /dev/disk/by-partlabel/NIXBOOT
cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/cryptroot   # recovery passphrase: into 1Password
cryptsetup open /dev/disk/by-partlabel/cryptroot cryptroot
mkfs.btrfs -L nixos /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@root /mnt/@home /mnt/@nix
umount /mnt
o=compress=zstd:1,noatime,ssd,discard=async,space_cache=v2
mount -o $o,subvol=@root /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/{home,nix,boot}
mount -o $o,subvol=@home /dev/disk/by-label/nixos /mnt/home
mount -o $o,subvol=@nix  /dev/disk/by-label/nixos /mnt/nix
mount -o fmask=0077,dmask=0077 /dev/disk/by-label/NIXBOOT /mnt/boot
```

Running `nixos-generate-config --show-hardware-config` and diffing it against
`hardware-configuration.nix` is a cheap check on the kernel-module list.

## 3. Seed state, then install

Copy the export onto the installer first, with `scp` from judy or a CIFS mount
of the NAS. Then:

```sh
x=/path/to/home-fedora-<date>
mkdir -p /mnt/var/lib /mnt/etc/ssh /mnt/root
tar -C /mnt/var/lib -xf $x/files/var-lib-tailscale.tar     # BEFORE first boot
tar -C /mnt/etc/ssh -xf $x/files/etc-ssh-host-keys.tar
printf 'username=...\npassword=...\n' > /mnt/root/nas-smb.cred; chmod 600 /mnt/root/nas-smb.cred
```

Install from a copy of the flake. Either `rsync -a ~/nixos/ root@<installer>:/root/nixos/`
from judy, or, once pushed, `github:eventualbuddha/nixos#home`:

```sh
nixos-install --flake /root/nixos#home --no-root-passwd
reboot
```

The first boot asks for the LUKS passphrase on the console. After that, `ssh home`
should work from judy over the tailnet: same name, same IP, same host key, now
sshd with your Yubikey.

## 4. Restore user data (on home, as brian)

```sh
x=/mnt/nas/Backups/home-fedora-<date>
tar -C ~ -xf $x/files/home.tar          # notes, code, .ssh, tailscale-sidecar/authkey.env, ...

systemctl --user stop podman-tailscale-summer podman-summer-app podman-summer-surrealdb podman-tailscale-code
podman volume import summer-data            $x/volumes/systemd-summer.tar
podman volume import tailscale-summer-state $x/volumes/systemd-tailscale-summer.tar
podman volume import tailscale-code-state  $x/volumes/systemd-tailscale-gitea.tar

podman load -i $x/summer/summer-app-image.tar     # or: summer-rebuild
systemctl --user start podman-summer-surrealdb podman-summer-app podman-tailscale-summer podman-tailscale-code
```

Check:
- https://summer.tail42107.ts.net shows recent transactions. The last good
  write is from before the disk filled on 2026-11-13.
- `tailscale status` lists `summer` and `code` online, **without** `-1` suffixes, and no `gitea`.

If summer's data looks wrong, restore the logical dump instead. Run
`surreal import` with `$x/summer/summer.surql` into an empty `summer-data`.

## 5. Forgejo

Copy the old host key first. The hostname changes to `code`, but clients that pinned the key by fingerprint still recognise it:

```sh
sudo systemctl stop forgejo
sudo install -d -o forgejo -g forgejo -m700 /var/lib/forgejo/data/ssh
sudo install -o forgejo -g forgejo -m600 $x/gitea/ssh-host-key/gitea.rsa* /var/lib/forgejo/data/ssh/
sudo systemctl start forgejo
```

Users are listed in `$x/gitea/users-and-keys.csv`:

```sh
fj() { sudo -u forgejo forgejo --work-path /var/lib/forgejo --config /var/lib/forgejo/custom/conf/app.ini "$@"; }
fj admin user create --admin --username brian    --email <from csv> --random-password
fj admin user create         --username madeline --email <from csv> --random-password --must-change-password
```

Set passwords, add each user's ssh keys from the CSV in the web UI, and send
madeline their temporary password.

Repos: the bare repos are inside the old Gitea volume. Pushing creates them, as
private repos, because `ENABLE_PUSH_CREATE_USER` is on:

```sh
mkdir -p ~/gitea-old && tar -C ~/gitea-old -xf $x/volumes/systemd-gitea.tar
for r in summer media-tools dotfiles bob-kids-sunscreen-case; do
  git -C ~/gitea-old/git/repositories/brian/$r.git push --mirror ssh://git@code.tail42107.ts.net:2222/brian/$r.git
done
```

madeline's two repos (`madreminders`, `worklinkrouter`) can only be push-created
by madeline. Do one of these:
- Have them push once they're logged in. Send them the two bare repos, or a `git bundle`.
- Push them yourself as `brian/…` and use *Settings → Transfer ownership* to madeline.

Visibility, descriptions and collaborators aren't carried over, so re-set them
in the UI. There were no issues, PRs, releases or Actions runners to carry over.
Once all six check out, delete `~/gitea-old`.

## 6. Backups

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

## 7. Secure Boot + TPM2 (unattended reboots)

```sh
sudo sbctl create-keys                       # into /var/lib/sbctl
# hosts/home/configuration.nix: secureBoot = true;  then deploy from judy:
nixos-rebuild switch --flake ~/nixos#home --target-host home --sudo
sudo sbctl verify                            # everything in /boot signed
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

## 8. Ripping

```sh
# once: put the MakeMKV key in ~/.MakeMKV/settings.conf ->  app_Key = "T-..."
rip            # disc name + titles; longest marked *
rip main       # or: rip 3 / rip 3 7 / rip all   ->  /mnt/nas/Videos/Rips/<disc>/
rip eject
```

When a disc needs the GUI, use `waypipe ssh home makemkv` from judy.
