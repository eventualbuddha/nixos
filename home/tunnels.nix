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
# ControlMaster/ControlPersist on the `vx` Host block (hosts/common.nix) is what
# keeps this from paying a full SSH handshake on every single browser reconnect:
# the first `ssh -W` for vx opens the real connection and leaves it parked at
# ~/.ssh/cm-%r@%h:%p, every subsequent one (including concurrent ones) just
# opens a new multiplexed channel over it, and it's torn down on its own after
# 10 minutes of no channels. On hosts where `vx` goes through a ProxyJump that
# saves two handshakes rather than one.
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

  systemd.user.services."tunnel-frontend@" = {
    Unit.Description = "Forward one connection to vx:3000";
    Service = {
      # Accept=yes sockets pass the accepted connection as stdin/stdout by
      # default; spelled out here since it's easy to misread this unit as
      # doing nothing with the socket at all.
      StandardInput = "socket";
      ExecStart = "${pkgs.openssh}/bin/ssh -W localhost:3000 vx";
    };
  };
}
