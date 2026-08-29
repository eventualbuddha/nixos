# VMGuard -- the egress gate for the vxsuite VM.
#
# The guest sits on the isolated `vmguard` libvirt network and has no route off
# its own subnet, deliberately. This proxy, bound to the host's address on that
# bridge, is the only way out, and ./vmguard/egress_filter.py is the policy:
# reads flow, writes are pinned to specific orgs, a host-side GitHub PAT is
# injected so the guest never holds a credential, and anything unrecognized is
# denied and logged. ./vmguard/NOTES.md is the rationale for each rule and
# README.md the day-to-day operations (deny-log triage, audit trail).
#
# Ported from the Fedora install this machine replaces, where it was a
# hand-rolled venv under /opt plus a unit dropped in /etc/systemd/system.
# nixpkgs carries the same mitmproxy the venv had (12.2.3), so the addon runs
# byte-for-byte unchanged against the API it was written for.
#
# Two pieces are deliberately NOT declared here, because a git repo is the wrong
# place for either:
#
#   /etc/vmguard/secrets.env            GH_PAT + CIRCLE_TOKEN, root-owned 0600.
#   /var/lib/vmguard/mitmproxy-conf/    the MITM CA -- including its private key.
#
# The CA in particular has to be *preserved* rather than regenerated: the
# guest's trust store already contains this exact CA (guest-setup.sh installed
# it there), so letting mitmproxy mint a fresh one would break every bumped TLS
# connection inside the guest with no obvious cause. Both are one-time manual
# steps; see the VMGuard section of README.md.

{ lib, pkgs, ... }:

let
  # The host's own address on virbr-guard, and the port the guest's
  # HTTP(S)_PROXY variables already point at (/etc/profile.d/vmguard.sh and
  # /etc/fish/conf.d/vmguard.fish inside the guest). Changing either of these
  # means editing the guest too.
  listenHost = "192.168.124.1";
  listenPort = 8080;

  # Staged into its own store *directory* rather than referenced as a bare
  # `${./vmguard/egress_filter.py}`, so mitmproxy sees a clean
  # `egress_filter.py` basename. It derives the addon's Python module name from
  # the filename, and a bare file reference would hand it the store hash too.
  # Keeping it separate from the tests also means editing a test doesn't change
  # the store path and needlessly restart the proxy on the next rebuild.
  addon = pkgs.writeTextDir "egress_filter.py" (builtins.readFile ./vmguard/egress_filter.py);
in
{
  users.groups.vmguard = { };
  users.users.vmguard = {
    isSystemUser = true;
    group = "vmguard";
    description = "VMGuard egress proxy";
  };

  # Unit name kept as `vmguard-github` from the Fedora setup even though the
  # addon outgrew GitHub long ago: the README's operating commands and NOTES.md
  # both name the unit, and renaming it would break every one of them.
  systemd.services.vmguard-github = {
    description = "VMGuard egress proxy (GitHub filter + Anthropic passthrough)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "libvirtd.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];

    environment.VMGUARD_DENYLOG = "/var/lib/vmguard/requests.log";

    # mitmdump exits straight away if --listen-host isn't already a local
    # address, and virbr-guard only exists once libvirtd has brought the
    # `vmguard` network up. libvirt networks get no systemd unit of their own to
    # order against, so wait for the address itself rather than guessing at a
    # dependency. Restart=on-failure covers the case where this times out.
    preStart = ''
      for _ in $(seq 1 60); do
        if ${pkgs.iproute2}/bin/ip -4 -o addr show | grep -qF " inet ${listenHost}/"; then
          exit 0
        fi
        sleep 1
      done
      echo "vmguard: ${listenHost} never appeared on any interface (is the 'vmguard' libvirt network started?)" >&2
      exit 1
    '';

    serviceConfig = {
      User = "vmguard";
      Group = "vmguard";
      StateDirectory = "vmguard"; # /var/lib/vmguard, owned by vmguard
      EnvironmentFile = "/etc/vmguard/secrets.env";
      Restart = "on-failure";
      RestartSec = 2;

      ExecStart = lib.concatStringsSep " " [
        "${pkgs.mitmproxy}/bin/mitmdump"
        "--mode regular"
        "--set confdir=/var/lib/vmguard/mitmproxy-conf"
        # Tunnelled rather than TLS-bumped, for three separate reasons: it dodges
        # cert pinning, it dodges Node's own CA bundle ignoring the system store,
        # and it keeps the guest's subscription token and OAuth refresh invisible
        # to the host. api.anthropic.com is inference; platform.claude.com is
        # where Claude Code re-mints its short-lived access token. Neither ever
        # reaches the addon.
        "--ignore-hosts '^api\\.anthropic\\.com:443$'"
        "--ignore-hosts '^platform\\.claude\\.com:443$'"
        "--listen-host ${listenHost}"
        "--listen-port ${toString listenPort}"
        "-s ${addon}/egress_filter.py"
      ];

      # The addon needs its state directory and a network socket, and reads its
      # two credentials from the environment -- nothing else.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
    };
  };

  # Without this the guest's connections to the proxy are simply dropped and
  # every network-using tool in there hangs with no explanation. libvirt's own
  # rules open only 53 and 67 on virbr-guard (see the LIBVIRT_INP chain) and the
  # NixOS firewall default-denies the rest. Scoped to the interface so the proxy
  # is not reachable from the LAN or the tailnet.
  networking.firewall.interfaces."virbr-guard".allowedTCPPorts = [ listenPort ];

  # requests.log is the audit trail for every allowed write, so retention is
  # deliberately generous; the content is repetitive JSON and compresses hard.
  # `maxsize` is what actually caps growth between daily runs -- on Fedora
  # nothing ever rotated this and it reached 500 MB.
  #
  # A plain rename-and-recreate is safe here: the addon opens the file, appends
  # one JSON record and closes it again on every request, so it never holds a
  # long-lived fd. That rules out needing `copytruncate` (which can drop records
  # written mid-copy) and means no service reload. `su` is required because
  # /var/lib/vmguard is not root-owned.
  services.logrotate.enable = true;
  services.logrotate.settings.vmguard = {
    files = "/var/lib/vmguard/requests.log";
    frequency = "daily";
    rotate = 30;
    maxsize = "100M";
    compress = true;
    missingok = true;
    notifempty = true;
    dateext = true;
    create = "0644 vmguard vmguard";
    su = "vmguard vmguard";
  };
}
