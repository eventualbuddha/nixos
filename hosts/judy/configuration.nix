# Host-specific config for "judy". Everything shared across machines lives in
# ../common.nix -- this file should only grow hardware quirks specific to this
# box (GPU driver, extra kernel params, etc).

{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
  ];

  networking.hostName = "judy";

  # The vxsuite VM runs on work, on a libvirt network only work can route to.
  # Reach it through the TCP relay work publishes on the tailnet (:2222 ->
  # guest:22, hosts/work/configuration.nix). User, agent forwarding and
  # connection multiplexing come from the `Host vx` block in ../common.nix;
  # this supplies the address, which is the one part that differs per machine.
  #
  # This used to be `ProxyJump vx-host.ts`. Three reasons it isn't:
  #
  #   - Two authentications means two YubiKey touches. The key here is
  #     touch-only by design -- setup-ssh-yubikey.sh sets no FIDO PIN and
  #     deliberately omits `-O verify-required` -- so every signature costs a
  #     tap: one to authenticate to work, one to the guest. Through the relay
  #     there is no second hop and no second tap.
  #   - Two SSH handshakes per connection, which is the cost
  #     home/desktop/tunnels.nix's master unit exists to amortise and which its
  #     comments called out by name.
  #   - The relay is the path a phone has to use regardless (an iOS client that
  #     won't do ProxyJump with a 1Password key is what prompted building it).
  #     If judy kept a different path, a broken relay would only ever be
  #     discovered from the couch, away from the machine that can fix it.
  #     Sharing it means it fails at a desk instead.
  #
  # What this gives up: work's sshd was a second gate on guest access, and now
  # tailnet membership plus a guest credential is enough. That gate went the
  # moment the relay existed for the phone -- keeping it for judy alone would
  # have protected the machine under physical control while the losable one
  # went without, which is backwards. The answer to a lost device is a
  # per-device guest key to revoke, not judy's transport.
  #
  # Not a DNAT rule on work, which is what the previous version of this comment
  # ruled out: libvirt's `LIBVIRT_FWI/FWO ... -j REJECT` pair rewrites and then
  # drops a DNAT'd packet on its way into virbr-guard. Those are FORWARD-chain
  # rules, and the relay's connection to the guest is locally-originated OUTPUT
  # traffic they never see -- which is why the Fedora-era userspace forward
  # worked for years while DNAT did not.
  #
  # 100.79.161.93 is work's tailnet address, the same one the `vx-host.ts`
  # block in ../common.nix carries. Keep the two in step.
  programs.ssh.extraConfig = ''
    Host vx
      HostName 100.79.161.93
      Port 2222
  '';

  # judy has 16G RAM and no swap, which meant a heavy from-source build (e.g.
  # bambu-studio's CGAL/OpenCASCADE/wxWidgets dependency tree) could blow past
  # physical memory and get OOM-killed instead of paging out. zram gives the
  # kernel somewhere to page under pressure without needing a swap partition.
  zramSwap.enable = true;

  # bambu-studio (wxGTK3) crashes on startup under niri's native Wayland: an
  # early wx log-flush pops a message-box dialog whose underlying GTK window
  # fails to realize, leaving a NULL widget that crashes wx's cleanup path.
  # xwayland-satellite gives it a real X11 display to run through instead --
  # niri only needs to implement xdg_wm_base + wm_viewporter for this to
  # work, which even the plain nixpkgs niri build already does, so no need
  # to switch to niri-flake's niri-unstable package for this.
  home-manager.users.brian.systemd.user.services.xwayland-satellite = {
    Unit = {
      Description = "Xwayland outside your Wayland";
      BindsTo = "graphical-session.target";
      PartOf = "graphical-session.target";
      After = "graphical-session.target";
      Requisite = "graphical-session.target";
    };
    Service = {
      Type = "notify";
      NotifyAccess = "all";
      ExecStart = "${pkgs.xwayland-satellite}/bin/xwayland-satellite :0";
      StandardOutput = "journal";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Bambu Studio: only judy has a Bambu printer, so keep this off other hosts.
  # Wrapped to route through xwayland-satellite (above) instead of niri's
  # native Wayland, which it crashes on.
  environment.systemPackages = [
    (pkgs.symlinkJoin {
      name = "bambu-studio-wrapped";
      paths = [ pkgs.bambu-studio ];
      buildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        rm $out/bin/bambu-studio
        makeWrapper ${pkgs.bambu-studio}/bin/bambu-studio $out/bin/bambu-studio \
          --set GDK_BACKEND x11 \
          --set DISPLAY :0
      '';
    })
  ];

  # --- Prompt ----------------------------------------------------------------
  #
  # judy keeps the gruvbox-rainbow preset it has always had; home/core/shell.nix
  # sets tokyo-night as the default, which work takes as-is and the vxsuite VM
  # overrides with a purple recolor. Three machines, three prompts, so a
  # terminal is identifiable at a glance -- which is the whole point, given
  # judy reaches the other two over ssh.
  home-manager.users.brian.programs.starship.settings = fromTOML (
    builtins.readFile ../../home/core/starship-gruvbox-rainbow.toml
  );

  virtualisation.containers.enable = true;
}
