# Port-forward-on-demand for viewing the vxsuite frontend dev server (port 3000
# in the `vx` guest) at localhost:3000 here.
#
# Worth doing even on work, where the guest's address is directly reachable and
# http://192.168.124.179:3000 would load: browsers only grant a secure context
# to localhost, so service workers, WebAuthn, clipboard and device APIs are
# available on localhost:3000 and silently absent on the LAN address. The
# forward is about the origin, not just about reachability.
#
# Deliberately not a persistent `autossh -L ...` unit: that has to be started
# by hand, has to be found again to check on, and needs its own reconnect
# logic. Instead this is systemd socket activation, inetd-style: `tunnel-
# frontend.socket` is the only thing that's ever listening, and only when
# something connects to 127.0.0.1:3000 does systemd spawn a `tunnel-
# frontend@.service` instance with that connection wired to its stdin/stdout,
# which `ssh -W` turns into a forward. Close the browser tab, the process
# exits -- nothing to remember to stop.
#
# The one long-lived piece is `tunnel-frontend-master.service`, which holds a
# single real SSH connection to vx and does nothing else; every `ssh -W` is a
# plain client opening a channel over it. That split keeps a browser reconnect
# from paying a full SSH handshake -- but the reason it's a separate unit
# rather than `ControlMaster
# auto` is that it keeps master setup and teardown out of the request path.
#
# Pulled in on demand by `tunnel-frontend@`'s `Wants=`, not started at login:
# the identity that authenticates to the guest is a touch-only YubiKey-backed
# key, and an eagerly-started master with `Restart=always` reconnects in the
# background every time the SSH connection drops -- which suspend does every
# time, on its own timer, with no browser tab open to explain it. That turned
# into the YubiKey blinking for a touch ~30s after every resume, for a
# connection nobody had asked to make yet. `StopWhenUnneeded` closes the loop:
# once nothing wants it (the last forward exited), systemd stops it too,
# instead of leaving it running to silently reconnect -- and prompt -- on some
# later resume.
#
# When each forward could become the master itself, a request that arrived while
# a master was expiring found the socket still on disk, connected to it, and got
# `mux_client_request_stdio_fwd: read from master failed: Broken pipe` -- ssh
# exit 255, accepted connection dropped, failed request in the browser. Grout
# sends every API call as a POST, so the browser can't silently retry it the way
# it would a GET, and a polling app surfaced this as occasional dropped
# requests. Concurrent first connections also raced to create the socket, with
# every loser logging `ControlSocket ... already exists, disabling multiplexing`
# and doing its own handshake. With a single owner there's nothing to race: the
# shared connection is either up, or absent and each forward quietly makes a
# direct connection instead (`ControlMaster no` in hosts/common.nix falls back
# on its own when the ControlPath can't be opened). A failing master is slow,
# never broken.
{ pkgs, ... }:

{
  systemd.user.sockets.tunnel-frontend = {
    Unit.Description = "Listen for connections to the vxsuite frontend dev server";
    Socket = {
      ListenStream = "127.0.0.1:3000";
      Accept = true;
    };
    Install.WantedBy = [ "sockets.target" ];
  };

  systemd.user.services.tunnel-frontend-master = {
    Unit.Description = "Hold the shared SSH connection to vx that the forwards ride on";
    Service = {
      # -N: no remote command, since this connection exists only to be the
      # master. ControlMaster=yes overrides the `no` in hosts/common.nix -- this
      # unit is the only thing that's allowed to create the socket.
      #
      # ControlPersist=no keeps ssh in the foreground instead of forking a
      # background master, so systemd is tracking the actual connection: the
      # unit being active means the socket is real, and stopping the unit takes
      # it down. ServerAlive* makes a wedged or vanished guest (a suspended VM,
      # a dropped Tailscale route) show up as an exit within ~45s rather than a
      # master that answers but can't open channels.
      ExecStart = toString [
        "${pkgs.openssh}/bin/ssh -N"
        "-o ControlMaster=yes"
        "-o ControlPersist=no"
        "-o ServerAliveInterval=15"
        "-o ServerAliveCountMax=3"
        "vx"
      ];
      # The guest is a VM that's often simply off, and that's not an error worth
      # escalating: the forwards work without a master, so this retries at a
      # slow enough interval to stay out of the journal's way.
      Restart = "always";
      RestartSec = 30;
    };
    Unit.StopWhenUnneeded = true;
  };

  systemd.user.services."tunnel-frontend@" = {
    Unit = {
      Description = "Forward one connection to vx:3000";
      # Wants, not Requires: if the master can't come up the forward should
      # still run and make its own direct connection.
      Wants = [ "tunnel-frontend-master.service" ];
      After = [ "tunnel-frontend-master.service" ];
    };
    Service = {
      # Accept=yes sockets pass the accepted connection as stdin/stdout by
      # default; spelled out here since it's easy to misread this unit as
      # doing nothing with the socket at all.
      StandardInput = "socket";
      # Without this, ssh's stderr ends up inside the browser's TCP stream.
      # With StandardInput=socket, StandardOutput defaults to `inherit` -- a
      # dup of stdin, i.e. the accepted connection -- and StandardError in turn
      # inherits stdout, so anything ssh prints is written inline as response
      # bytes, on top of the real HTTP response.
      StandardError = "journal";
      ExecStart = "${pkgs.openssh}/bin/ssh -W localhost:3000 vx";
    };
  };
}
