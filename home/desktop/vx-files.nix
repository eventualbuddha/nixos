# Moving files between this machine and the vxsuite guest (`vx`), both ways,
# without handing the guest anything it can drive on its own.
#
# The guest is assumed compromised. That is the premise of modules/vmguard.nix,
# which makes the egress proxy its only way out, and of the virtiofs shares in
# its domain, which are all <readonly/> so it cannot write into this home. Both
# properties survive anything *this side* initiates over the SSH connection it
# already holds: pulling a file out has a human in the loop, and pushing one in
# is data-in, the same as a download the proxy would have allowed. What would
# break them is a channel the guest can trigger -- a writable share into the
# host, guest-to-host SSH, a shared SPICE clipboard -- so nothing here adds one.
#
# Out of the guest
#
#   `vx-mount` runs sshfs under a user service so the guest's home shows up
#   read-only at ~/vx for every host application: Loupe for a built PNG, the
#   browser's file picker for Slack, wl-copy. It is the mirror image of the
#   virtiofs shares -- the guest's sshd serves reads, and the host firewall
#   still default-denies inbound on the guest bridge, so the guest gains no
#   path back.
#
#   Not an automount, although /mnt/fedora on work shows that is the nicer
#   shape: autofs needs CAP_SYS_ADMIN, and the user manager fails such units
#   with result 'resources' (tested, systemd 261). A system-level fstab entry
#   would mount as root with root's ssh config and no agent, which is wrong
#   for a key that lives in this home. So: a user service, started by hand.
#
#   Not started at login either. The guest is often simply off, and on a host
#   whose key to it is touch-only, a background retry loop is a YubiKey
#   blinking for nobody -- the reason tunnels.nix's master is on demand too.
#   `sshfs -f` keeps the process in the foreground so the unit being active
#   means the mount is real, and stopping the unit takes it down.
#
#   `vxclip` and `vxopen` do not need the mount. Each is one `ssh vx cat`, for
#   the common case of a single image that wants to be pasted somewhere.
#
# Into the guest
#
#   ~/vx-inbox here is shared read-only into the guest at /vx/inbox, over
#   virtiofs like the three shares already in the domain, so a file that lands
#   here is in the guest at once. `vxget` downloads a URL the proxy would deny
#   straight into it; `vxpush` copies local files there. If a *source* recurs,
#   the right fix is a GET-only allow in modules/vmguard/egress_filter.py with
#   a NOTES.md entry, not a wider inbox.
#
#   The share itself is in libvirt's state and the guest's fstab, not in nix
#   (NixOS has no declarative libvirt domains; README "Moving files" has the
#   procedure). The directory is created here so a missing source dir can
#   never keep the domain from starting -- virtiofsd refuses to run without it.
{ pkgs, ... }:

let
  mountPoint = "%h/vx";
in
{
  home.packages = [ pkgs.sshfs ];

  # The source directory of the inbox share. Nothing in this file writes to it
  # except vxget/vxpush; the guest side is a <readonly/> mount.
  home.file."vx-inbox/.keep".text = "";

  systemd.user.services.vx-mount = {
    Unit.Description = "Mount the vxsuite guest's home read-only at ~/vx over sshfs";
    Service = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${mountPoint}";
      # ro:               nothing on this side should ever write into the guest
      #                   through this path; the inbox share is the way in.
      # reconnect:        a suspend or a guest reboot comes back as a stall,
      #                   not a dead mount that has to be torn down by hand.
      # ServerAlive*:     with reconnect, a vanished guest is noticed in ~45s.
      # idmap=user:       the guest's `vx` (uid 1001) reads as this user, so
      #                   file managers show ownership as "me" and not as a
      #                   number that happens not to exist here.
      # follow_symlinks:  the guest's symlinks resolve on the guest, where
      #                   their targets are; here they would point at nothing.
      ExecStart = toString [
        "${pkgs.sshfs}/bin/sshfs -f"
        "-o ssh_command=${pkgs.openssh}/bin/ssh"
        "-o ro,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3"
        "-o idmap=user,follow_symlinks"
        "vx:/home/vx"
        mountPoint
      ];
      # sshfs unmounts itself on SIGTERM; this is for a mount it left behind
      # after dying some other way. The setuid wrapper, since fusermount3
      # needs to be privileged and the store copy is not.
      ExecStopPost = "-/run/wrappers/bin/fusermount3 -u -z ${mountPoint}";
      # No Restart: a failure here is answered by whoever typed `vx-mount`,
      # and the function prints the status so they see why.
    };
  };

  programs.fish.functions = {
    # Tab-completion for guest paths, for vxclip and vxopen. Lists the
    # directory part of the current token over SSH, with `/` on directories so
    # fish (auto_space) leaves off the trailing space and the next Tab descends
    # into it. One ssh handshake per Tab; on a local guest that is a fraction
    # of a second, and BatchMode keeps a guest that is off from hanging the
    # prompt on a password it would never get. `~` is the one shell expansion
    # worth preserving through the quoting, since it is how a path in the
    # guest home is naturally typed.
    __vx_complete_guest_path = {
      description = "Complete a path inside the vxsuite guest";
      body = ''
        set -l tok (commandline -ct)
        set -l dir (string replace -r '[^/]*$' "" -- $tok)
        # Dotfiles only once the name part starts with a dot, as fish does for
        # local paths.
        set -l flags -1pL
        string match -q '.*' -- (string replace -r '^.*/' "" -- $tok); and set flags -1ApL
        switch "$dir"
          case ""
            set -f remote .
          case "~/*"
            set -f remote '"$HOME"'(string escape -- (string sub -s 2 -- $dir))
          case "*"
            set -f remote (string escape -- $dir)
        end
        ssh -o BatchMode=yes -o ConnectTimeout=3 vx "ls $flags -- $remote" 2>/dev/null \
          | string replace -r '^' -- $dir
      '';
    };

    vx-mount = {
      description = "Mount the vxsuite guest's home read-only at ~/vx";
      body = ''
        systemctl --user start vx-mount.service
        and echo "guest home is at ~/vx (read-only); vx-umount to drop it"
        or systemctl --user status --no-pager vx-mount.service
      '';
    };

    vx-umount = {
      description = "Unmount ~/vx";
      body = "systemctl --user stop vx-mount.service";
    };

    vxclip = {
      description = "Put a file from the vxsuite guest on the clipboard";
      body = ''
        if test (count $argv) -ne 1
          echo "usage: vxclip <path in guest, relative to /home/vx or absolute>" >&2
          return 2
        end
        set -l tmp (mktemp -t vxclip.XXXXXX); or return
        if ssh vx cat -- (string escape -- $argv[1]) > $tmp
          set -l mime (${pkgs.file}/bin/file -b --mime-type $tmp)
          # wl-copy offers a text payload under every text type a paste target
          # might ask for, but only when it is left to recognise text itself;
          # an explicit --type is offered alone. So name the type only for the
          # images, PDFs and the like that `file` can pin down and wl-copy
          # cannot be trusted to.
          if string match -q 'text/*' -- $mime
            ${pkgs.wl-clipboard}/bin/wl-copy < $tmp
          else
            ${pkgs.wl-clipboard}/bin/wl-copy --type $mime < $tmp
          end
          echo "$argv[1] ($mime) is on the clipboard"
        end
        set -l status_ $status
        rm -f $tmp
        return $status_
      '';
    };

    vxopen = {
      description = "Copy files out of the vxsuite guest into ~/vx-stage and open them";
      body = ''
        if test (count $argv) -lt 1
          echo "usage: vxopen <path in guest>..." >&2
          return 2
        end
        set -l stage $HOME/vx-stage
        mkdir -p $stage; or return
        for p in $argv
          # scp's SFTP mode takes the remote path as-is (no remote shell), so
          # it must not be quoted for one; a leading ~ is still expanded.
          scp -q vx:$p $stage/; or return
          xdg-open $stage/(path basename -- $p)
        end
      '';
    };

    vxget = {
      description = "Download URLs here and drop them into the guest's /vx/inbox";
      body = ''
        if test (count $argv) -lt 1
          echo "usage: vxget <url>..." >&2
          return 2
        end
        set -l inbox $HOME/vx-inbox
        mkdir -p $inbox; or return
        for url in $argv
          # -O -J: name the file as the server does (Content-Disposition, else
          # the URL's last segment). curl refuses to overwrite with -J, so a
          # repeat download fails loudly instead of replacing something.
          curl -fL -O -J --output-dir $inbox -- $url; or return
        end
        echo "in the guest under /vx/inbox:"
        ls -t $inbox | head -n (count $argv)
      '';
    };

    vxpush = {
      description = "Copy local files into the guest's /vx/inbox";
      body = ''
        if test (count $argv) -lt 1
          echo "usage: vxpush <file>..." >&2
          return 2
        end
        set -l inbox $HOME/vx-inbox
        mkdir -p $inbox; or return
        cp -r -t $inbox -- $argv; or return
        for p in $argv
          echo /vx/inbox/(path basename -- $p)
        end
      '';
    };
  };

  # Autoloaded completions (fish reads ~/.config/fish/completions/<cmd>.fish on
  # first use). -f turns off local-file completion, which would otherwise
  # offer this machine's files for a path that is resolved in the guest.
  xdg.configFile = {
    "fish/completions/vxclip.fish".text =
      "complete -c vxclip -f -a '(__vx_complete_guest_path)'\n";
    "fish/completions/vxopen.fish".text =
      "complete -c vxopen -f -a '(__vx_complete_guest_path)'\n";
  };
}
