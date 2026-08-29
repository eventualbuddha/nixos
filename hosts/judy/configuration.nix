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

  # The i915 GuC flip worker (kworker/u:N+i915_flip) has been observed stuck
  # in uninterruptible sleep for 10s+ at a time, stalling any client trying to
  # submit a fresh frame (a new window's first paint, a full-screen redraw)
  # while windows that don't need a new frame stay responsive -- e.g. niri
  # itself keeps switching focus fine, but a new ghostty window or nvim
  # starting up hangs for several seconds.
  #
  # `enable_psr=0` alone did not fix it -- caught live with `/proc/<pid>/stack`
  # (see catch-i915-stall.sh in the chat that added this), and 580/850
  # captures showed intel_atomic_commit_tail blocked in
  # drm_atomic_helper_wait_for_flip_done (waiting on the *previous* flip's
  # completion), versus only 4/850 waiting on a GPU render fence
  # (dma_fence_wait_timeout). That points at the display engine itself being
  # slow to signal flip-done, not PSR's link handshake or GPU rendering --
  # the next suspect is DC5/DC6 display power-state transitions, a separate
  # power-gating path from PSR. `enable_dc=0` disables those. Both flags cost
  # idle power (screen-on idle draws more, though full suspend is unaffected)
  # to trade for finding out which power-saving path is actually wedging the
  # flip queue; once confirmed, narrow back down to whichever one alone fixes
  # it (or, if it's `enable_dc`, to `enable_dc=1` for DC5-only rather than
  # disabling it outright).
  boot.kernelParams = [
    "i915.enable_psr=0"
    "i915.enable_dc=0"
  ];

  # The vxsuite VM runs on work, on a libvirt network only work can route to,
  # so reach it by jumping through work. Everything else about the alias --
  # address, user, agent forwarding, connection multiplexing -- comes from the
  # `Host vx` block in ../common.nix; this only adds the hop.
  #
  # Deliberately not a port forward on work (2222 -> guest:22, the way the
  # Fedora install did it): libvirt gives an isolated network a pair of
  # `LIBVIRT_FWI/FWO ... -j REJECT` rules, so a DNAT'd packet gets rewritten and
  # then dropped on its way into virbr-guard. Making it work means an ACCEPT
  # ordered ahead of libvirt's own rules, which libvirt reinstalls from scratch
  # on every network reload. ProxyJump needs nothing on the far end and exposes
  # no extra port.
  programs.ssh.extraConfig = ''
    Host vx
      ProxyJump vx-host.ts
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
