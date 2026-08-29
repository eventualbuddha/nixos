# nixos

Personal NixOS flake. Primary desktop is [niri](https://github.com/niri-wm/niri)
(scrollable-tiling Wayland compositor) + [ghostty](https://ghostty.org/) +
[noctalia](https://github.com/noctalia-dev/noctalia) (shell/bar/launcher), with
GNOME + GDM kept fully intact as a fallback session -- pick either at login.

Loosely inspired by [ctknightdev/nixos](https://github.com/ctknightdev/nixos),
rebuilt from scratch for this hardware/setup rather than adapted from it.

## Layout

```
flake.nix
hosts/
  common.nix              # shared system config across every machine
  <hostname>/
    configuration.nix     # host-specific: just hostname + hardware quirks
    hardware-configuration.nix   # from `nixos-generate-config` on that machine
home/                     # home-manager, user "brian", shared across hosts
  niri.nix                # compositor settings, keybinds, window rules
  noctalia.nix            # shell/bar config
  terminal.nix            # ghostty
  editor.nix              # neovim + LazyVim bootstrap
  dev.nix                 # git/signing + rust/node/dev CLI tooling
  shell.nix               # fish + starship
  apps.nix                # browsers, chat, CLI utilities
  theme.nix               # gtk/cursor theme
  tunnels.nix             # socket-activated SSH forwards
```

Adding a new machine: run `nixos-generate-config`, drop the two files under
`hosts/<name>/`, add `<name> = mkHost "<name>";` in `flake.nix`. Everything in
`hosts/common.nix` and `home/` applies automatically.

## Applying changes

```
nixos-rebuild build --flake .#<host>          # no root needed, just evaluates/builds
sudo nixos-rebuild switch --flake .#<host>    # or: ./apply.sh
```

`./apply.sh` builds the host it is run on. Pass a name (`./apply.sh judy`) to
build a different one.

## If niri doesn't work out

1. **Easiest**: log out, and on the GDM login screen pick "GNOME" from the
   session dropdown instead of "niri". Nothing about GNOME/GDM is touched by
   this config -- it's the exact same session that was there before.
2. **If GDM itself won't come up**: reboot, and at the systemd-boot menu pick
   an earlier generation (on judy, that includes the ones from before niri was
   ever added).
3. **judy only**: plain `sudo nixos-rebuild switch` (no `--flake` flag) run from
   `/etc/nixos` still rebuilds the original, untouched, GNOME-only
   `/etc/nixos/configuration.nix` as a manual last resort, entirely independent
   of this flake. Machines installed straight from this flake (work) have no
   such file -- `/etc/nixos` is empty there, so only 1 and 2 apply.

## YubiKey (sudo / polkit)

Run `./enroll-yubikey.sh` once per machine, after the first switch. `pam_u2f`
is configured with `control = "sufficient"`, so your password always still
works even without the key.

Per machine, not once ever: the script enrolls against `pam://$HOSTNAME`,
which is what `pam_u2f` looks up when `security.pam.u2f.settings.origin` is
unset. A credential enrolled under another host's origin is simply never
matched, and because the control is `sufficient` that failure is silent -- it
falls back to the password prompt, which looks exactly like the enrollment not
having taken.

## Git commit signing

Commits are signed with a YubiKey-backed SSH key, per machine. The key is
non-resident, so `~/.ssh/id_ed25519_sign_sk` is the **only** copy -- it cannot
be re-downloaded from the token (`ssh-keygen -K` needs a FIDO PIN, and this
setup is touch-only by design). Back that file up.

Setting up a new machine:

```
ssh-keygen -t ed25519-sk -f ~/.ssh/id_ed25519_sign_sk -C "<email> (git signing, <host>)"
```

Then add the `.pub` line to `signingKeys` in `home/dev.nix` and re-apply, and
register it at https://github.com/settings/keys as a **Signing Key** (not an
Authentication Key -- GitHub treats those as distinct roles). Every machine
trusts every key in that list, which is what lets `git log --show-signature`
verify commits made on the other machine.

## Bootstrapping a new vxsuite VM

A fresh Debian 12 guest with nothing on it but a `vx` user becomes a working
build VM with one command, run inside the guest:

```
curl -fsSL https://raw.githubusercontent.com/eventualbuddha/nixos/main/bootstrap-vm.sh | bash
```

`bootstrap-vm.sh` does the eight things that are otherwise hand-work: passwordless
sudo, apt prerequisites, the multi-user nix install, flakes, the nix-daemon proxy
drop-in, cloning this repo, and activating `homeConfigurations."vx@vxdev"`. It is
idempotent -- re-running it on a configured box changes nothing -- and `CHECK=1`
prints what each step would do without touching anything.

Two things about it are worth knowing before you use it.

**Where it goes in the vmguard order.** The provisioning sequence in
`hosts/work/vmguard/Justfile` is `net-up → install → firewall-open → guest-setup
→ move-nic`, and this script goes anywhere after **`guest-setup`** -- either side
of `move-nic`. Everything it fetches is allowlisted read-only: the four nixos.org
hosts (NOTES 46), `deb.debian.org` and `security.debian.org` for apt, and
`github.com` for the clone. The hard rule is that `guest-setup` must come first
if the guest is already on the isolated net, since without the MITM CA and the
proxy env it writes there is no egress at all. The script checks reachability
before running the nix installer, so that case fails with a reason rather than as
a download timeout.

**The nix-daemon proxy drop-in.** On a multi-user install the *daemon* does all
substituter traffic, and systemd units inherit nothing from the shell -- so behind
vmguard, every user-side proxy variable can be perfectly correct and nix still
cannot reach the binary cache. `/etc/systemd/system/nix-daemon.service.d/override.conf`
is what fixes it. The existing VM has had that file since its own setup, written
by hand and recorded nowhere; the script is now where it lives.

What the script deliberately does **not** do is the vmguard guest side -- the MITM
CA into the trust store, `/etc/profile.d/vmguard.sh`, the apt proxy config. That
is `guest-setup.sh` on `work` (`just guest-setup`), it needs the CA off the host,
and that key does not belong in this repo. The script detects whether it has run
and adapts. Still by hand afterwards: `claude /login`, `just move-nic`, and
cloning vxsuite into `~/code/vxsuite`.

## VMGuard: the vxsuite VM's egress proxy (work only)

The vxsuite guest sits on an isolated libvirt network (`vmguard`) with no route
off its own subnet. `hosts/work/vmguard.nix` runs the mitmproxy-based egress
gate that is its *only* way out: reads flow, writes are pinned to specific orgs,
a host-side GitHub PAT is injected so the guest never holds a credential, and
anything unrecognized is denied and logged. `hosts/work/vmguard/` holds the
policy addon, its offline tests, and `NOTES.md` -- the rationale for every rule
in it, which is what to read before widening anything.

The service is declarative. Two files are not, because a git repo is the wrong
place for either, and the service will not work without them:

1. **`/etc/vmguard/secrets.env`** -- root-owned `0600`, `GH_PAT` and optionally
   `CIRCLE_TOKEN`. Copy `hosts/work/vmguard/secrets.env.template` and fill it
   in. Without this the unit fails to start at all (`EnvironmentFile`).

2. **`/var/lib/vmguard/mitmproxy-conf/`** -- the MITM CA, private key included.
   This has to be **preserved, never regenerated**. The guest's trust store
   already contains this exact CA, so if mitmproxy mints a fresh one on an empty
   confdir the service comes up looking perfectly healthy and every TLS-bumped
   connection inside the guest fails with no obvious cause. Restore the old
   directory, `chown -R vmguard:vmguard` it, and restart.

The guest half is not managed from here at all -- it lives in the VM's disk
image: the CA in its trust store, `/etc/profile.d/vmguard.sh` (bash),
`~/.config/fish/conf.d/vmguard.fish` (fish, and `vx`'s shell *is* fish, so this
is the one that matters interactively), and `/etc/apt/apt.conf.d/00-vmguard-proxy`
(`sudo` strips proxy env, so apt needs its own). Those proxy variables are the
only egress path there is; commenting them out looks exactly like a broken
network.

### Changing the policy

Edit `hosts/work/vmguard/egress_filter.py`, run the tests, then apply. That is the
whole deploy -- the addon is staged into the Nix store by `vmguard.nix` and the
unit's `ExecStart` names that store path, so an edit changes the path, which
changes the unit, which makes the switch restart the service.

```
cd hosts/work/vmguard
nix-shell -p python3 --run 'GH_PAT=dummy VMGUARD_DENYLOG=/tmp/t.log python3 tests/test_filter.py'
cd ../../.. && ./apply.sh                    # sudo nixos-rebuild switch --flake .#work
systemctl show vmguard-github -p ExecStart --value | grep -o 'egress_filter[^ ]*'
```

The tests are offline (they stub mitmproxy and mock the org resolver) and need a
dummy `GH_PAT` only because the addon reads it at import. The last line confirms
the running service picked up the new store path; compare it against
`nix eval --raw '.#nixosConfigurations.work.config.systemd.services.vmguard-github.serviceConfig.ExecStart'`.

Read `hosts/work/vmguard/NOTES.md` before widening anything -- it carries the
rationale for every rule, and the deny log is the evidence a new rule should be
built from.

### Operating it

The host has no system `python3` and no `just`; commands needing python go
through `nix-shell -p python3`.

```
systemctl status vmguard-github                     # is it up?
ss -ltn | grep 192.168.124.1:8080                   # is it listening?
sudo journalctl -u vmguard-github -n 50             # service log (crashes, addon tracebacks)
tail -n 30 /var/lib/vmguard/requests.log            # the request/deny log
```

**What got denied** -- the first thing to run when something in the guest "has no
network". Hosts are collapsed and counted, with the noise we block on purpose
filtered out (datadog telemetry, mcp-proxy, and loopback polls that should never
have reached the proxy -- NOTES 15):

```
tail -n 1000 /var/lib/vmguard/requests.log | grep '"kind": "DENY"' \
  | grep -oP '"host": "\K[^"]+' \
  | grep -viE 'datadoghq|mcp-proxy|^localhost$|^127\.0\.0\.1$|^::1$' \
  | sort | uniq -c | sort -rn
```

Same thing but only since the last restart, so stale pre-fix entries don't
muddy the picture after a deploy:

```
awk -F'"' -v t="$(date -d "$(systemctl show vmguard-github -p ActiveEnterTimestamp --value)" +%Y-%m-%dT%H:%M:%S)" \
    '/"kind": "DENY"/ && $4 >= t' /var/lib/vmguard/requests.log \
  | grep -oP '"host": "\K[^"]+' | sort | uniq -c | sort -rn
```

**The audit trail** -- every allowed write: pushes, PR/issue/merge mutations, the
CircleCI rerun, and anything that went out through an `OPEN_HOSTS` entry:

```
tail -n 1000 /var/lib/vmguard/requests.log | grep '"kind": "WRITE"'
```

**Denied GraphQL mutations**, grouped by the op and org that caused them -- what to
read when deciding whether to widen `MUTATION_ALLOW`:

```
cd hosts/work/vmguard && nix-shell -p python3 --run './gql-denies.py'
```

**The guest's Claude credential expiry** (runs in the guest, over ssh):

```
ssh vx python3 < hosts/work/vmguard/check-creds.py
```

**Rotating a credential.** `secrets.env` is deliberately outside the repo and
outside the store, so a switch never touches it. Edit it as root, then restart:

```
sudoedit /etc/vmguard/secrets.env && sudo systemctl restart vmguard-github
```

**Log rotation** is declarative (`services.logrotate` in `vmguard.nix`: daily,
30 kept, forced at 100M). There is no `/etc/logrotate.d` on NixOS -- the config
is a store path -- so to force a rotation now, run the timer's service:

```
sudo systemctl start logrotate.service
```

### A note on the old Fedora tooling

This setup was ported from a Fedora install where it was a hand-rolled venv in
`/opt` plus a unit dropped in `/etc/systemd/system`, driven by a `Justfile`. That
Justfile was deleted in the NixOS port: `just` and `python3` are not installed
here, every path it referenced (`artifacts/`, `install-host.sh`, `guest-setup.sh`,
`mitmproxy-conf/`, `/opt/vmguard`) is gone, and its `deploy` recipe would have
overwritten `/etc/systemd/system/vmguard-github.service` -- which NixOS now owns
as a symlink into the store -- and quietly fought the next switch. Its useful
recipes are the commands above. Its one-time install steps (`net-up`, `install`,
`firewall-open`, `logrotate-install`) are now declared in `vmguard.nix`, and the
guest-side steps (`guest-setup`, `move-nic`) were done once and live in the VM's
disk image. `NOTES.md` keeps the full Fedora-era record.
