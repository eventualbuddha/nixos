# Dead man's switch: report systemd units to healthchecks.io.
#
# For each entry in `services.healthchecks-ping`, keyed by systemd SERVICE name
# (e.g. "restic-backups-nas"), the unit:
#   - pings <url>/start when it starts, so healthchecks measures run time and
#     can flag a run that hangs (like the 2026-11-14 SMB directory loop);
#   - pings <url>/<exit code> when it stops, with the last 50 journal lines of
#     THIS run as the body. ExecStopPost runs on success, on failure, AND when
#     systemd stops the unit from outside (the 2026-11-15 automount idle-timeout
#     kill), so every way a run can end gets reported.
# healthchecks alerts (email) when a failure ping arrives, or when NO success
# ping arrives within the check's schedule + grace -- which is the part that
# catches "the timer silently stopped firing" or "the host is gone".
#
# The ping URL is a secret-ish capability (anyone with it can mark the check
# up), so it lives in a root-only file on the host, NOT in this repo:
#   install -D -m 600 /dev/stdin /root/healthchecks/<service>.url <<< 'https://hc-ping.com/<uuid>'
# If the file is missing the ping is skipped with a journal warning, and the
# backup still runs. healthchecks then goes "down" after the grace period, which
# is the right outcome for a misconfigured host.
#
# Both pings are prefixed "-" in systemd terms: an unreachable healthchecks.io
# must never fail (or block) the backup itself.
#
# Note: on failure, the journal tail can include file paths from the NAS (restic
# lists unreadable files). That goes to healthchecks.io. Accepted on purpose:
# knowing WHICH file broke is the useful part (cf. the `:`/`?` filenames).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.healthchecks-ping;

  pingScript =
    name: urlFile:
    pkgs.writeShellScript "healthchecks-ping-${name}" ''
      set -u
      if [ ! -r ${lib.escapeShellArg urlFile} ]; then
        echo "healthchecks: ${urlFile} missing, not pinging" >&2
        exit 0
      fi
      url=$(tr -d '[:space:]' < ${lib.escapeShellArg urlFile})

      # healthchecks pairs /start with its finish ping via ?rid=<uuid>. systemd's
      # INVOCATION_ID is 32 hex chars; reformat it as a canonical UUID.
      id=''${INVOCATION_ID:-}
      rid=""
      if [ ''${#id} -eq 32 ]; then
        rid="?rid=''${id:0:8}-''${id:8:4}-''${id:12:4}-''${id:16:4}-''${id:20:12}"
      fi

      ping() {
        ${pkgs.curl}/bin/curl -fsS -m 15 --retry 5 --retry-all-errors \
          -o /dev/null "$@"
      }

      case "$1" in
        start)
          ping "$url/start$rid"
          ;;
        finish)
          # SERVICE_RESULT/EXIT_STATUS are set by systemd for ExecStopPost.
          # EXIT_STATUS can be a signal name (TERM) when the unit was killed;
          # healthchecks wants 0-255, so anything non-numeric becomes 1.
          if [ "''${SERVICE_RESULT:-}" = success ]; then
            code=0
          else
            code=''${EXIT_STATUS:-1}
            case "$code" in "" | *[!0-9]* | 0) code=1 ;; esac
          fi
          ${pkgs.systemd}/bin/journalctl --no-pager -o cat \
              "_SYSTEMD_INVOCATION_ID=$id" 2>/dev/null \
            | tail -n 50 \
            | ping --data-binary @- "$url/$code$rid"
          ;;
      esac
    '';
in
{
  options.services.healthchecks-ping = lib.mkOption {
    description = "systemd services that report start/finish to a healthchecks.io check.";
    default = { };
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options.urlFile = lib.mkOption {
            type = lib.types.str;
            default = "/root/healthchecks/${name}.url";
            description = "Root-only file holding the check's ping URL (https://hc-ping.com/<uuid>).";
          };
        }
      )
    );
  };

  config.systemd.services = lib.mapAttrs (
    name: c:
    let
      script = pingScript name c.urlFile;
    in
    {
      serviceConfig = {
        ExecStartPre = lib.mkBefore [ "-${script} start" ];
        ExecStopPost = lib.mkAfter [ "-${script} finish" ];
      };
    }
  ) cfg;
}
