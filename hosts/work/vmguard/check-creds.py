#!/usr/bin/env python3
# Print the guest's Claude Code credential expiry. Meant to be run IN THE GUEST, e.g.
#   ssh vx python3 < scripts/check-creds.py
import json, time, os

p = os.path.expanduser("~/.claude/.credentials.json")
try:
    d = json.load(open(p)).get("claudeAiOauth", {})
except Exception as e:
    print("could not read creds:", e)
    raise SystemExit(1)

exp = d.get("expiresAt", 0) / 1000
left = (exp - time.time()) / 3600
print("subscription:", d.get("subscriptionType"), "| tier:", d.get("rateLimitTier"))
print("expires:", time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(exp)),
      f"({left:.1f}h from now)", "| refreshToken:", bool(d.get("refreshToken")))
raise SystemExit(0 if left > 0 else 2)
