#!/usr/bin/env python3
# Denied GraphQL mutations, grouped by the op/org that caused them -- the tool for deciding what
# to widen next. Was `just gql-denies` until the Justfile was retired in the NixOS port; the
# grep-and-count one-liners went into README.md, but this one has real logic, so it stayed a
# script. The host has no system python, so run it through nix-shell:
#
#   nix-shell -p python3 --run './gql-denies.py'          # last 2000 log lines
#   nix-shell -p python3 --run './gql-denies.py 20000'    # look further back
#
# Reads the deployed deny log by default; override with VMGUARD_DENYLOG, which is the same
# variable the addon itself takes.
import collections, json, os, sys

log = os.environ.get("VMGUARD_DENYLOG", "/var/lib/vmguard/requests.log")
tail = int(sys.argv[1]) if len(sys.argv) > 1 else 2000

try:
    with open(log, errors="replace") as fh:
        lines = fh.readlines()[-tail:]
except OSError as e:
    raise SystemExit(f"could not read {log}: {e}")

seen = collections.Counter()
for line in lines:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if r.get("kind") != "DENY" or not r.get("reason", "").startswith("graphql mutation"):
        continue
    key = (r.get("why", "?"),
           ",".join(r.get("bad_ops") or r.get("ops") or []),
           ",".join(r.get("bad_orgs") or []))
    seen[key] += 1

if not seen:
    # 'why'/'ops'/'bad_orgs' are only present on entries logged after NOTES 23 -- an empty
    # result on an old log means "not recorded", not "never happened".
    print("(no graphql denies in the last "
          f"{len(lines)} lines of {log})")
    raise SystemExit(0)

for (why, ops, orgs), n in seen.most_common():
    print(f"{n:6}  {why:32}  ops={ops or '-'}  orgs={orgs or '-'}")
