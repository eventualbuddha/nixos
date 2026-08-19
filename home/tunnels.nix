# Port-forward-on-demand for viewing the frontend dev server on vx.ts
# (localhost:3000 there) from localhost:3000 here.
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
# ControlMaster/ControlPersist on the vx.ts Host block (hosts/common.nix)
# is what keeps this from paying a full SSH handshake on every single
# browser reconnect: the first `ssh -W` for vx.ts opens the real
# connection and leaves it parked at ~/.ssh/cm-%r@%h:%p, every subsequent
# one (including concurrent ones) just opens a new multiplexed channel over
# it, and it's torn down on its own after 10 minutes of no channels.
{ pkgs, ... }:

{
  systemd.user.sockets.tunnel-frontend = {
    Unit.Description = "Listen for connections to the vx.ts frontend dev server";
    Socket = {
      ListenStream = "127.0.0.1:3000";
      Accept = true;
    };
    Install.WantedBy = [ "sockets.target" ];
  };

  systemd.user.services."tunnel-frontend@" = {
    Unit.Description = "Forward one connection to vx.ts:3000";
    Service = {
      # Accept=yes sockets pass the accepted connection as stdin/stdout by
      # default; spelled out here since it's easy to misread this unit as
      # doing nothing with the socket at all.
      StandardInput = "socket";
      ExecStart = "${pkgs.openssh}/bin/ssh -W localhost:3000 vx.ts";
    };
  };
}
