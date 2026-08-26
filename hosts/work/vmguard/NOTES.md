# VMGuard setup — working notes & change journal

**Operator:** brian@voting.works · **Host:** Fedora 44, libvirt/qemu-kvm · **Started:** 2026-07-12
**Source of truth:** `~/Desktop/vmguard-handoff.md`
**Staging/working dir:** `~/Desktop/vmguard-staging/` (this folder)

The goal, threat model, and policy are in the handoff doc; not repeated here. This file
records *what was actually done on this machine*, the deviations from the doc, what still
needs doing, and how to back everything out.

---

## Initial state (captured before any change) → `initial-state/`

- **Networks:** only `default` — NAT (`<forward mode='nat'>`), bridge `virbr0`,
  **`192.168.122.1/24`**, DHCP .2–.254, with a static lease `vxsuite → 192.168.122.120`
  (mac `52:54:00:33:7d:20`).  Snapshot: `net-default.xml`, `net-list.txt`.
- **VM:** `vxsuite` **running**, single NIC on `default` (virtio, mac `52:54:00:33:7d:20`,
  vnet0).  Snapshot: `domain-vxsuite.xml`, `vxsuite-iflist.txt`.
- **Host networking:** LAN `enp191s0` 192.168.86.62, default route via 192.168.86.1;
  `docker0` 172.17.0.0/16 (down).  Snapshot: `host-ip-addr.txt`, `host-ip-route.txt`.
- **VMGuard bits:** none present — no `/opt/vmguard`, `/etc/vmguard`, no `vmguard` user,
  no mitmproxy.  Snapshot: `host-misc.txt`.
- Host reaches the internet normally (example.com → 200).

## Deviations from the handoff doc (important)

1. **Subnet changed `192.168.122.1` → `192.168.124.1`.**  The doc assumes .122.1 is free,
   but the existing `default` network already owns it. Two libvirt nets cannot share an
   IP/subnet, and I deliberately left `default` **untouched** for reversibility. So the
   isolated net `vmguard` uses **`192.168.124.0/24`, host `192.168.124.1`, bridge
   `virbr-guard`**. Every reference (systemd units, guest config) uses .124.1 accordingly.

2. **Addon ported to mitmproxy 12.** Installed mitmproxy is **12.2.3** (doc targets 10/11).
   `ctx.log` **no longer exists in v12** (verified: `hasattr(ctx,'log')==False`) — the doc's
   `github_filter.py` would raise `AttributeError` on *every* request. Fixed to use the
   stdlib `logging` module instead. `--mode regular` / `--mode reverse:URL` syntax is
   unchanged in v12 (verified via `--help`). `inject_anthropic.py` needed no change.

3. **CA is pinned via `--set confdir=/var/lib/vmguard/mitmproxy-conf`** in the units, and
   the CA generated during shakeout (`mitmproxy-conf/`) is copied there by the installer.
   This guarantees the CA the guest trusts == the CA the running service presents.

4. **Anthropic path redesigned for a Pro/Max SUBSCRIPTION — "design B" (major deviation).**
   The user wants to use their existing Pro/Max plan, not pay-per-token API credits. That
   forced a rethink (verified against current Claude Code docs, v2.1.196+):
   - A subscription is **OAuth, not an `sk-ant-` API key**. It cannot be cleanly injected
     host-side: `claude setup-token` produces a 1-year token that is *meant to live as an
     env var on the machine running Claude Code*; proxy-injecting it is undocumented,
     fragile (auth-precedence), and ToS-uncertain. So injection is **out**.
   - **Decision (user-chosen): run Claude Code inside the guest with the subscription
     token living in the guest.** This is the officially-supported headless-subscription
     path. Trade-off, stated honestly: the token is exposed to the (assumed-compromised)
     guest. Blast radius is bounded — inference-only, revocable, plan-capped — unlike a
     stolen API key. The GitHub PAT remains fully host-side.
   - **Because the host no longer injects an Anthropic secret, the whole reverse-proxy
     instance (port 8081 / `inject_anthropic.py`) is deleted.** The guest instead reaches
     Anthropic through the *same* regular proxy on 8080, which **tunnels `api.anthropic.com`
     untouched** via `--ignore-hosts` (no TLS bump ⇒ no cert-pinning risk, and the guest's
     own token never transits the host). Everything else stays bumped, filtered, and
     denied+logged. Guest routes via `HTTPS_PROXY=http://192.168.124.1:8080` (transport
     level — robust regardless of whether subscription-mode honours `ANTHROPIC_BASE_URL`).
   - There is now **one** host secret (GH_PAT) and **one** systemd service (vmguard-github).

5. **Host firewall: opened tcp/8080 in the `libvirt` firewalld zone (discovered during guest
   test).** The `libvirt` zone allows only dhcp/dns/ssh/tftp inbound and rejects the rest, so
   the guest's TCP connect to the proxy at 192.168.124.1:8080 was refused. Fix applied:
   `firewall-cmd --zone=libvirt --add-port=8080/tcp` (runtime + `--permanent`). The proxy
   binds only 192.168.124.1, and the net still has no `<forward>`, so isolation is intact —
   this only lets the guest reach the proxy port on the host. Back-out removes the port.

6. **Guest proxy env must load in NON-login shells too (found during guest test).**
   Symptom: git clone worked but `claude -p` failed "unable to connect to API", and a guest
   `curl https://api.anthropic.com` gave "Could not resolve host" — proof the proxy env was
   NOT active (with the proxy set, the client never resolves; the host does). Cause:
   `/etc/profile.d/vmguard.sh` is sourced only by *login* shells; console/ssh sessions are
   typically non-login. Fix: also source it from `~/.bashrc` (done in guest-setup.sh /
   guest-console-paste.sh). Verified: with `HTTPS_PROXY` set, guest `curl` to
   api.anthropic.com returns **401** through the tunnel (real Anthropic reply) — Anthropic
   path works end-to-end. (git was unaffected because it reads `http.proxy` from git config,
   not the env — which is why it worked while Claude did not.)
   - **fish shells:** fish reads neither `/etc/profile.d/*.sh` nor `.bashrc`. For a guest
     fish user, install `artifacts/vmguard.fish` at `~/.config/fish/conf.d/vmguard.fish`
     (conf.d is sourced by every fish session) and set the token as a fish universal var
     (`set -Ux CLAUDE_CODE_OAUTH_TOKEN …`). GUEST ONLY — never on the host.

7. **Static DHCP reservation added on vmguard: vxsuite → 192.168.124.179** (mac
   ...7d:20), so its IP is stable for the host→guest SSH port-forward (host:2222→VM:22)
   that the cutover broke (it pointed at the old .122.120). Host→guest access does not
   weaken isolation (isolation blocks guest→internet only). The reservation lives in the
   vmguard net config, so back-out removes it along with the network. The 2222 forwarder
   itself is a userspace listener on the host (see below) whose target IP needs updating.
   - **Pre-existing `vx-ssh-forward` systemd socket+service** (host:2222 → VM:22, via
     `systemd-socket-proxyd`) was pointed at the old `192.168.122.120:22` and broke on
     cutover. Fixed by repointing both `/etc/systemd/system/vx-ssh-forward.{socket,service}`
     to `192.168.124.179:22` (sed + daemon-reload + restart). `backout.sh` reverts this to
     `.122.120` when it moves the VM back to the default net. Not a VMGuard component — a
     user forward that our cutover incidentally broke.

8. **api.github.com opened read-only (gh/mason need it).** Added a host branch to
   github_filter.py: GET/HEAD → inject PAT (`Authorization: Bearer`) + log as `APIREAD`;
   any mutating method (POST/PUT/PATCH/DELETE) → denied. Stays inside the exfil model
   (reads pull data in like a clone; write-out via the API stays shut). Blocks gh's GraphQL
   reads (POST /graphql) — revisit with body inspection only if the deny log shows a real
   need. Deployed by copying the addon to /opt/vmguard and restarting vmguard-github.
   For `gh auth status` to report logged-in, the guest needs a *dummy* GH_TOKEN (the proxy
   overwrites the auth header with the real PAT); plain read commands work without it.
   Deny log also revealed other blocked hosts. Decision (user):
   - **Opened read-only (GET/HEAD, no creds):** `api.mason-registry.dev` (neovim mason),
     `downloads.claude.ai` (CC updates), `herdr.dev` — via `READ_ONLY_HOSTS` in the addon.
     These are bumped, so non-system-CA clients need the CA wired in: Claude Code (Node)
     hitting downloads.claude.ai needs `NODE_EXTRA_CA_CERTS=<CA path>` in the guest or the
     bump fails (harmless for the update check, but that's why it'd still error otherwise).
   - **Left blocked:** `mcp-proxy.anthropic.com` (MCP servers — would be an exfil surface),
     `http-intake.logs.us5.datadoghq.com` (datadog telemetry).

9. **gh GraphQL: body-inspected (user-chosen).** gh's main commands POST /graphql; a
   GraphQL request only writes if the document declares a `mutation`, so the addon allows
   POST /graphql when `graphql_is_read_only()` finds no mutation and denies otherwise
   (fail-closed on unparseable/empty/batched-with-mutation). Keeps the write-out boundary
   while letting gh's read commands work. Unit-tested (query/shorthand/named/mutation/
   commented/batch/empty/garbage). Not bulletproof against deliberately obfuscated GraphQL,
   but robust for gh's own traffic.

10. **GitHub release-asset downloads allowed (read-only).** `/{owner}/{repo}/releases/
    download/...` on github.com (GET/HEAD, PAT injected, logged as `RELEASE`) plus the
    `objects.githubusercontent.com` / `release-assets.githubusercontent.com` CDNs they 302
    to (in READ_ONLY_HOSTS). Needed for Mason's registry. NOTE: installing individual Mason
    packages will pull from more hosts (npm/pypi/other release pages) — widen from the deny
    log as they appear; Mason is an inherently open-ended allowlist.

12. **Use Claude Code's NATIVE credential store, not the CLAUDE_CODE_OAUTH_TOKEN env var
    (user call — no security tradeoff).** The env token (from `setup-token`) is inference-
    scoped and can't self-refresh; it worked for `claude -p` but a FULL session 401'd
    ("Invalid authentication credentials · Please run /login") because it conflicts with
    Claude Code's own OAuth store (`~/.claude/.credentials.json` — a team / Max-5x `/login`
    with a refresh token) and lacks `user:mcp_servers` scope. Since the credential lives in
    the guest either way (both mode 600), the env var bought no security — so drop it and let
    Claude Code manage creds: `set -eU CLAUDE_CODE_OAUTH_TOKEN`; `rm ~/.vmguard-claude-token`;
    remove its `.bashrc` line; `claude /login` (code exchange hits the tunneled
    platform.claude.com). Native storage auto-refreshes via platform.claude.com. Same threat
    model. guest-setup.sh / guest-console-paste.sh / vmguard.fish updated to stop provisioning
    the env token and to run `/login` instead.

11. **platform.claude.com tunneled (Claude OAuth refresh — found after it started failing).**
    Claude Code re-mints a short-lived access token at `POST platform.claude.com/v1/oauth/token`;
    that host wasn't allowlisted, so once the initial access token expired, refresh was denied
    and Claude failed (it worked at first only because it had a cached access token). Added
    `platform.claude.com` to `--ignore-hosts` alongside api.anthropic.com (tunnel: no Node-CA
    issue, OAuth exchange stays E2E-encrypted). Deployed by updating the unit + daemon-reload +
    restart. If other Anthropic hosts (e.g. statsig) surface in the deny log and matter, tunnel
    them the same way; statsig/telemetry failures are non-fatal and can stay blocked.

13. **Package managers opened up (read-only): npm, cargo, apt, + circleci reads (2026-07-13).**
    From the deny log: only `registry.npmjs.org` ever reached the gate; **apt and cargo showed
    ZERO log lines**. Root causes differed:
    - **apt**: run under `sudo`, which uses `env_reset` with the proxy `env_keep` line
      **commented out** in /etc/sudoers → apt got no `http(s)_proxy`, tried a direct connection,
      and died on the isolated net without ever hitting the proxy. Fix: give apt its OWN proxy
      config (env-independent) — wrote `/etc/apt/apt.conf.d/00-vmguard-proxy` in the guest with
      `Acquire::http::Proxy` / `Acquire::https::Proxy` → `192.168.124.1:8080`. Then allowlisted
      the guest's apt hosts: `deb.debian.org`, `security.debian.org`, `www.debian.org`,
      `apt.postgresql.org`, `cli.github.com`. (apt integrity is guaranteed by its own gpg
      signatures, so plain-http mirrors are fine; exfil surface is GET-only.)
    - **cargo / npm / pnpm / yarn**: run as the user, so they DO inherit the proxy env and reach
      the gate — they just hit denied hosts. Added `registry.npmjs.org` (npm/pnpm/yarn),
      `index.crates.io` + `static.crates.io` (cargo's default sparse index + downloads).
      Also `nodejs.org` (added 2026-07-14): pnpm's manage-Node feature fetches the release
      index (`/dist/index.json`) and Node tarballs from there — surfaced as 64 retried denies.
      Node CA was already fine: guest has `NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt`
      (the bundle includes mitmproxy.crt), so bumped npm TLS validates. cargo uses the system
      store too; if a bumped fetch ever fails cert validation, set `CARGO_HTTP_CAINFO` to the
      same bundle.
    - **circleci**: added `circleci.com` to READ_ONLY_HOSTS per request (GET/HEAD only). Note
      circleci's GraphQL/`config validate` uses POST, which this GET/HEAD gate blocks — that's
      intended ("allow reads"); widen deliberately if a POST-read need is confirmed.
    All added to `READ_ONLY_HOSTS` in the addon (GET/HEAD only, no creds injected, writes denied).
    Deploy: copy addon to `/opt/vmguard/github_filter.py` + `systemctl restart vmguard-github`.

14. **GraphQL mutations allowed for PRs/issues, scoped to WRITE_ORGS (2026-07-13).**
    `gh pr create` (and `gh issue create`) issue a `POST /graphql` **mutation**, which the
    addon denied wholesale. Enabling them is subtler than git push: a `createPullRequest`
    mutation carries an opaque `repositoryId` node — not `owner/repo` — so the org can't be
    read off the request. Solution, in `graphql_decision()`:
    - **Parse, don't grep.** `_scan_mutation_fields()` is a string/bracket-aware scanner that
      returns the top-level mutation field names. A plain "contains 'mutation'?" check is
      unsafe — an attacker can append a second top-level field after an allowed one
      (`createIssue{...} deleteRepository{...}`) or hide braces/keywords inside string
      literals. Unparseable / keyword-present-but-unparsed bodies fail closed.
    - **Op allowlist**: every top-level field must be in `MUTATION_ALLOW` (PR/issue lifecycle
      — create/update/close/reopen PR & issue, comments, labels, and PR merge +
      enable/disable auto-merge [added 2026-07-14 on request]). Still deliberately excludes
      destructive/broad ops (deleteRepository, ref/branch deletion, org/user/repo settings),
      so even inside votingworks a compromised guest can't nuke a repo or rewrite settings.
    - **Org resolution**: node IDs pulled from `variables` (keys `*Id`/`*Ids`) are resolved
      to their owning org via a DIRECT (un-proxied, `ProxyHandler({})`) `nodes(ids:)` query
      from the host using the PAT — the guest isn't trusted to name the org. Every resolved
      owner must be in `WRITE_ORGS`; any null/unknown/unresolved id → deny. Logged as `WRITE`.
    - Both conditions required (op AND org). *(Owner resolution refined by item 22 — nodes that
      name a person/team rather than a place are skipped instead of denied.)* Unit-tested offline with a mocked resolver
      (10 decision cases + 8 scanner cases, all pass) — reads pass; PR/issue in the two orgs
      allowed; forbidden org, disallowed-op-in-allowed-org, createGist, sneaky-2nd-field,
      mixed-org batch, and unresolvable ids all denied. Adds one blocking ~8s-timeout call
      to api.github.com per mutation (rare; host has direct egress). REST writes (non-GET)
      stay fully denied — gh uses GraphQL for these anyway.

15. **Loopback excluded from the proxy — `NO_PROXY` added (2026-07-17).** The guest set
    `HTTP(S)_PROXY` but no `NO_PROXY`, so proxy-aware clients sent even `localhost`/
    `127.0.0.1`/`::1` traffic to the proxy, where the egress filter's catch-all 403s it as
    "host not on allowlist" (`github_filter.py:308`). The deny was correct — loopback was
    never meant to be egress — but such traffic shouldn't reach the proxy at all. Fix: set
    `NO_PROXY`/`no_proxy` = `localhost,127.0.0.1,::1` alongside the proxy exports in both
    `guest-setup.sh` (/etc/profile.d/vmguard.sh) and `artifacts/vmguard.fish` (conf.d).
    Note: git (uses `http.proxy` from its config) and apt (own `00-vmguard-proxy`) don't
    honor `NO_PROXY`; not an issue unless you point either at a local endpoint.

16. **github.com opened for ALL GET/HEAD reads (2026-07-17).** `curl|sh` / `xh|bash`
    installers (moon: `moonrepo.dev/install/moon.sh`) broke because the addon only
    allow-listed specific github.com *paths* — release downloads via `/releases/download/`
    but NOT the `/releases/latest/download/` convenience URL, and no `/raw/`, `/archive/`,
    or web paths. Rather than keep whacking moles, `request()` now: (a) classifies git
    smart-HTTP FIRST — `git-upload-pack` reads allowed any repo, `git-receive-pack` pushes
    (incl. their GET `info/refs?service=git-receive-pack` advertisement) stay gated to
    `WRITE_ORGS`; then (b) allows ANY GET/HEAD to github.com (PAT injected), denying every
    non-read method. This only widens *reads*, which were already open across GitHub (git
    fetch any repo, api.github.com GET/HEAD, codeload) — the write/exfil surface is
    unchanged. Also added `raw.githubusercontent.com` + `gist.githubusercontent.com` to
    `READ_ONLY_HOSTS` (separate hosts a github.com rule can't cover; deny log showed 10
    hits). Tests extended to 32 cases (release both-shapes, raw, web, clone reads, and the
    push-advertisement/receive-pack deny for non-orgs). Deploy with `just deploy`.

17. **moon `proto::offline` fixed — probe the proxy, not public DNS (2026-07-17).** `moon run`
    aborted with `proto::offline` ("Internet connection required") before ever using the proxy.
    Root cause: moon's online check (`starbase_utils::net::is_offline`, run *before* proto does
    anything) does a **raw TCP connect** to hardcoded public DNS — `1.1.1.1:53`, `1.0.0.1:53`,
    `8.8.8.8:53`, `8.8.4.4:53` + IPv6 — and never honours the proxy env. On the isolated net all
    are `Network is unreachable`, so moon declared itself offline and refused to download/run any
    tool. NOT the same as the earlier `localhost` NO_PROXY issue (item 15): that was Claude Code
    polling loopback; this is moon's connectivity probe.
    - **Fix (guest env): `PROTO_OFFLINE_HOSTS=192.168.124.1:8080`.** proto maps this env var to
      starbase's `custom_hosts` — an *additional* probe target. The check returns "online" on the
      FIRST reachable host, and the guest CAN TCP-connect to the proxy, so the gate passes; real
      downloads still flow through the proxy + its allowlist. Verified with `moon --log trace`:
      after the added host, `starbase_utils::net Online!`, then proto resolved node 20.19.0 and the
      build pipeline proceeded (it even fetched proto's own release from github.com through the gate).
    - **Gotcha:** `PROTO_OFFLINE_OVERRIDE_HOSTS` is NOT a host list — it's a *boolean* that disables
      the defaults. The address goes in `PROTO_OFFLINE_HOSTS`. (Passing the address to the boolean
      var did nothing — confirmed in the trace.) `host:port` only, no `http://` scheme.
    - Added to both env provisioners: `guest-setup.sh` (`/etc/profile.d/vmguard.sh`, as
      `${PROXY#http://}`) and `artifacts/vmguard.fish` (conf.d). Applied live to the running guest's
      copies of both files; a fresh bash/fish shell now exports it. No host/isolation change.

18. **`launch.moonrepo.app` version check allowed — scoped POST (2026-07-17).** Once moon got past
    the offline gate it does `POST launch.moonrepo.app/moon/check_version` (its "newer moon?" ping),
    which the catch-all denied. It's a POST, so it can't ride `READ_ONLY_HOSTS` (GET/HEAD only). Added
    a dedicated branch: host `launch.moonrepo.app` + method POST + exact path `/moon/check_version`
    → allow (no creds, logged READ); any other method/path on that host → deny. Body is just moon's
    own version string ⇒ fixed, tiny exfil surface. Non-fatal either way (moon continues if it's
    denied), but allowed per request. Tests +3 cases (version POST allow; GET and other-path POST
    deny). Deployed (verified 2026-08-04: `/opt/vmguard/github_filter.py` matched `artifacts/`).

19. **GitHub stacked PRs allowed — scoped REST writes (2026-08-04).** `gh` stack commands were
    403ing. Cause: stacked PRs are a **REST** feature, and the addon allowed *no* REST writes on
    api.github.com — only GraphQL mutations (item 14). Deny log showed exactly
    `POST /repos/votingworks/vxsuite/stacks` → "api.github.com write/mutation denied" (the
    matching `GET .../stacks` passed fine, which is why listing worked and creating didn't).
    Per docs there are five endpoints; the two GETs already rode the read rule, so three POSTs
    needed opening: `/stacks` (create), `/stacks/{n}/add`, `/stacks/{n}/unstack`.
    - **Org scoping is easy here** — unlike a GraphQL mutation, whose target hides behind an
      opaque node id (hence item 14's resolver round-trip), owner/repo sit in the URL path that
      GitHub itself routes on. So `STACK_WRITE_RE` reads the org off the path and checks
      `WRITE_ORGS` directly — same shape of gate as the git-push rule, no network call, no
      added latency.
    - **Matched against the RAW path, on purpose.** mitmproxy forwards the raw path upstream but
      `path_components` percent-DECODES, so deciding on the decoded form is a parser differential:
      verified that `/repos/votingworks/vxsuite%2f..%2f..%2ftorvalds%2flinux/stacks` decodes to
      components `['repos','votingworks','vxsuite/../../torvalds/linux','stacks']` — an org check
      on component[1] would pass while GitHub receives a path pointing at torvalds/linux. The
      regex uses only unreserved chars, so it admits no `%` at all and what we authorize is
      byte-for-byte what GitHub gets.
    - Write boundary unchanged in kind: only reorders/annotates PRs in repos the guest can
      already push to and open PRs against. Creates no repos, deletes no refs, changes no
      settings. Non-POST methods on `/stacks*` (PATCH/DELETE) stay denied, as does any subpath
      other than add/unstack. Logged as `WRITE` with `stack: true` for the audit trail.
    - Tests extended to 51 cases (+19: the read shapes, create/add/unstack, second write org,
      case-insensitive org, query string, forbidden org, PATCH/DELETE, unknown subpath,
      `stacksomething` prefix, non-numeric stack id, and both traversal bypasses).
    - **Deploy pending — run `just deploy` (needs sudo).**

    Two things surfaced alongside this and were then fixed — see items 20 and 21.

20. **Post-merge branch cleanup allowed — scoped REST DELETE (2026-08-04).** Seen in the deny log
    at 10:40:52, immediately after an allowed merge mutation:
    `DELETE /repos/votingworks/vxsuite/git/refs/heads/brian%2Fesm-migration-spec` — i.e.
    `gh pr merge --delete-branch`. Ref deletion was excluded wholesale by item 14 as destructive,
    but a stacked-PR workflow hits it after every merge in the stack, so it's now allowed under a
    tight gate mirroring item 19's: `DELETE_REF_RE` + `WRITE_ORGS` check on the path's owner.
    - **Narrowly destructive, and recoverably so:** it drops a branch tip in a repo the guest can
      already force-push; the commits survive in the merged PR and the reflog. `heads/` is baked
      into the pattern, so **tags** (release markers) and every other ref namespace stay
      untouchable, as does every other REST DELETE (repos, releases, ...).
    - **This path can't ban `%` the way item 19 does** — branch names contain slashes and gh
      percent-encodes them (`brian%2Fesm-migration-spec`). So `%2F` is the one escape the charset
      admits, and `_ref_is_plain()` then segment-checks the decoded ref: no empty, `.`, or `..`
      segments. Without that, a tail like `..%2F..%2F..%2Ftorvalds%2Flinux%2F...` could walk back
      up the path and retarget a repo outside `WRITE_ORGS` if GitHub normalizes before routing.
      Git already forbids `.`/`..` ref components, so the check rejects nothing legitimate.
    - Consequence worth knowing: branches with characters outside `[A-Za-z0-9._-]` (e.g. `+`, or
      unicode) fail closed and won't be deletable through the proxy. No conventional branch name
      hits this.
    - Tests now 74 cases (+23 for this rule: the exact encoded-slash shape from the log, literal
      slash, dotted, both write orgs, case-insensitive org; and denies for forbidden org, tags,
      notes, bare `/git/refs`, repo/release DELETE, encoded + literal traversal, `.`/empty
      segments, non-`%2F` escapes, encoded owner/repo, plus 5 direct `_ref_is_plain()` checks).
    - **Deploy pending — same `just deploy` as item 19.**

21. **logrotate for `requests.log` (2026-08-04).** The log had reached **236 MB** — nothing ever
    rotated it — and ~396k of its last 400k lines were the `localhost` deny flood, which buried
    every real deny. Added `artifacts/vmguard-logrotate.conf` → `/etc/logrotate.d/vmguard`.
    - **Plain rename-and-recreate is safe, no `copytruncate`, no service reload:** the addon's
      `_log()` opens the file, appends one record, and closes it for *every* request, so it holds
      no long-lived fd — the next request just opens the fresh file. (`copytruncate` would risk
      dropping records written during the copy, so it's deliberately not used.)
    - **`su vmguard vmguard` is required** — `/var/lib/vmguard` is owned by vmguard, not root, and
      logrotate refuses to rotate inside a non-root-owned directory without it. Verified with
      `logrotate -d`: config parses, and the `su` resolves to uid 967 / gid 963.
    - `daily`, `rotate 30`, `compress`, `dateext`, plus **`maxsize 100M`** — the maxsize is what
      actually caps growth between daily timer runs. Retention is long on purpose: this is the
      audit trail for every allowed WRITE (pushes, PR/issue mutations, stack changes, branch
      deletes), and the JSON is repetitive enough to compress to near nothing.
    - Wired into `install-host.sh` (new step 6) and removed by `backout.sh`. Since the installer
      already ran here, install it standalone: **`just logrotate-install`**, then
      **`just logrotate-now`** to rotate the existing 236 MB file away immediately.
    - Also filtered loopback out of `just denies` / `just denies-since`, alongside the existing
      datadog/mcp-proxy exclusions, so those recipes are usable again. `just log` still shows
      everything raw.
    - **Root cause of the flood itself is still open** — item 15's `NO_PROXY` didn't fully take;
      some client ignores it, or a process predates the fix / came from a shell that never
      re-sourced the env. Rotation contains the symptom; the client still needs chasing.

22. **Adding a PR reviewer allowed — both the GraphQL and the REST route (2026-08-04).** Deny log,
    three lines in four minutes: `POST /graphql` ×2 → "graphql mutation denied (op not allowed or
    org not permitted)" (11:20:49, 11:24:36), then `POST /repos/votingworks/vxsuite/pulls/9045/
    requested_reviewers` (11:24:59) — i.e. the GraphQL path failed, then `gh api`/REST was tried as
    a fallback and failed too. Bodies aren't logged, so the GraphQL op was inferred from the timing
    and from gh's implementation — **inferred WRONG; the real op is `requestReviewsByLogin`, see
    item 24.** The REST line is exact. Both routes are now open, because which one you hit depends
    on whether you use `gh pr` or `gh api`.
    - **GraphQL: `requestreviews` added to `MUTATION_ALLOW`** — but that alone was NOT enough, and
      the second failure mode is the interesting one. `requestReviews` carries `userIds`/`teamIds`
      (the reviewers) alongside `pullRequestId` (the PR). `_collect_node_ids()` scoops up all of
      them, and item 14's resolver required *every* id to resolve to an owning org — a User node
      resolves to no org at all, so `login` came back empty and the whole mutation failed closed.
      Fix: **`PRINCIPAL_TYPES = {User, Bot, Team, Mannequin}`** — node types that name a *who*, not
      a *where*, are recognized and skipped rather than org-resolved.
    - **This does not widen the write boundary.** The mutation's target (Repository / PullRequest /
      Issue / IssueComment / Label) is still resolved and still must be in `WRITE_ORGS`; a typename
      in neither set still fails closed; and a mutation carrying *only* principal ids now resolves
      to an empty owner set, which the caller already treats as a deny. No new fragments were added
      to `_RESOLVE_Q` — principals are classified by the `__typename` it already selects.
    - **Not an exfil channel:** GitHub only accepts review requests for accounts that already have
      access to the repo, so a compromised guest can't request review from an attacker-owned
      account to get eyes on a private PR.
    - **Side effect worth knowing: this also unbroke `--assignee`.** `createIssue`/`updateIssue`
      with `assigneeIds` was hitting the exact same wall (allowed op, unresolvable User id → deny).
      It was never reported, presumably because nobody tried it.
    - **REST: `REVIEWERS_WRITE_RE`** for `POST /repos/{owner}/{repo}/pulls/{n}/requested_reviewers`,
      org-gated off the raw path with the unreserved-only charset — same easy gate and same
      anti-parser-differential reasoning as item 19 (owner/repo sit in the path GitHub routes on, so
      no resolver round-trip and no added latency). Reviewer logins ride in the JSON body and need no
      inspection: they only matter if GitHub accepts them, per the point above. `DELETE` on that path
      (un-request a reviewer) is deliberately left denied — nothing has asked for it, and the deny
      log is where that call should come from. `PATCH /pulls/{n}` and `POST /pulls/{n}/reviews`
      (submitting an actual review) also stay denied.
    - Tests now 101 cases (+27): the exact logged REST shape, both write orgs, case-insensitive org,
      the GET that already worked; denies for forbidden org, DELETE/PATCH, `/reviews`, `/pulls/{n}`
      PATCH, non-numeric PR id, `requested_reviewers_x` prefix, an extra subpath, and both
      traversals. Plus `requestReviews` decision cases (allowed, forbidden org, principals-only →
      deny, unlisted op with the same variable shape → deny) and 7 direct `_resolve_owners()` checks
      driving the real resolver over a stubbed round-trip (target, skips User, skips Team+Bot,
      principals-only → empty, unknown typename → None, null node → None, no ids → None).
    - **Deploy pending — `just deploy` (needs sudo), same as items 19 and 20, all three ship together.**

23. **GraphQL denies now say WHICH op — plus two resolver false-positives fixed (2026-08-04).**
    After item 22 was deployed (service restarted 11:30:37), one deny remained: a single
    `POST /graphql` "mutation denied" at 11:31:40, one second before an *allowed* mutation and
    right after a successful push to `brian/esm-migration-mark`. **The op behind it is still
    unidentified** — and that's the actual problem, so it got fixed first.
    - **The log couldn't name the op.** Every failed mutation logged the same fixed string,
      "op not allowed or org not permitted", with no indication of which. Item 22's op had to be
      inferred from timestamps and gh's source; that guesswork isn't repeatable. `graphql_decision()`
      now returns `(decision, detail)` and the log carries `why` + `ops` + `bad_ops` / `bad_orgs`:
      `op not in allowlist`, `org not permitted`, `no resolvable target org`, `unparseable graphql`,
      … Allowed mutations record `ops`/`orgs` too, which sharpens the WRITE audit trail.
    - **Metadata only, never the body.** Op names and org logins are what you need to decide a
      widen; the body carries PR/issue titles and comment text and this log is kept 30 days.
    - New recipe **`just gql-denies`** groups graphql denies by why/op/org. Pre-existing entries
      show `?` — they were written before the fields existed.
    - **False positive 1: git SHAs.** `_collect_node_ids()` grabbed any variable whose key ends
      in `id` — which catches `expectedHeadOid`, the SHA `gh pr merge` sends to guard against a
      racing push. It went to `nodes(ids:)`, GitHub returned null for it, and `_resolve_owners()`
      correctly read null as "unresolvable id" and denied. So **`gh pr merge` was denied whenever
      it included the race guard**, despite `mergepullrequest` being allowed since item 14 — which
      explains why merge worked in some runs and not others.
    - **False positive 2: `clientMutationId`**, a caller-chosen echo string present in most
      GitHub mutation inputs, was likewise treated as a node id and likewise denied everything
      that carried it. gh leaves it unset, so this bites hand-written `gh api graphql` calls and
      other clients.
    - Fix: `_is_node_id_key()` excludes `clientmutationid` and any `*oid` suffix. **No gate is
      lost** — neither can name a write target, and genuine node-id variables always end in
      `Id`/`Ids`, so the `oid` exclusion can't swallow one.
    - **Whether either false positive was the 11:31:40 deny is unverified.** Both are real and
      both are fixed; the `why` field will settle it on the next occurrence rather than another
      round of inference.
    - Tests now 118 cases (+17): 9 for the deny detail (each `why`, the exact `bad_ops`/`bad_orgs`
      names, clean detail on allow, empty on read), 6 for `_collect_node_ids` (real ids kept; SHA,
      echo string, bare `oid` skipped), and 2 for `gh pr merge` with the SHA guard (allowed org →
      ok, forbidden org → still denied).
    - **Deploy pending — `just deploy`; then reproduce the blocked action and run `just gql-denies`.**

24. **The actual reviewer op: `requestReviewsByLogin` (2026-08-04, from `gh` debug output).**
    Item 22 guessed `requestReviews` from timing; wrong. `gh pr edit 9042 --add-reviewer kofi-q`
    sends:
    ```
    mutation RequestReviewsByLogin($input:RequestReviewsByLoginInput!){requestReviewsByLogin(input: $input){clientMutationId}}
    {"input":{"pullRequestId":"PR_kwDOEaKHaM76r4Ba","userLogins":["kofi-q"],
              "botLogins":[],"teamSlugs":[],"union":false}}
    ```
    → 403 in 404ms (no resolver round-trip: it failed the op allowlist, the very first gate).
    Fix: **`requestreviewsbylogin` added to `MUTATION_ALLOW`**, alongside the node-id form.
    - **This also explains the DENY-then-WRITE pair in the log** (item 23). `gh pr edit` fires two
      mutations: `updatePullRequest` — allowed, and visible returning 200 in the same debug dump —
      and `requestReviewsByLogin`, denied. One command, two log lines, which is why the deny sat
      next to a success.
    - **The `*ByLogin` form needs no new gating, and is arguably the easier one to secure:**
      reviewers arrive as `userLogins`/`botLogins`/`teamSlugs` **strings**, so the only node id in
      the request is `pullRequestId` — exactly the target the org gate wants. `_collect_node_ids()`
      ignores the login lists (their keys end in `logins`/`slugs`, not `ids`), the PR resolves to
      its owning org, and `WRITE_ORGS` decides as usual.
    - **Consequence for item 22's `PRINCIPAL_TYPES` work: it is not what unblocked this.** Since gh
      names reviewers by login, no User/Bot/Team node id is ever resolved on this path. That change
      is still correct and still earns its keep for `createIssue`/`updateIssue` with `assigneeIds`
      (node ids, and previously denied for the same reason) and for the node-id `requestReviews`
      form — but the record should not imply it fixed the reported symptom. The op allowlist entry
      is what fixed it.
    - Tests now 122 cases (+4): the exact document through the scanner, the exact request decided
      (allowed org → ok, forbidden org → deny), and `_collect_node_ids` over the real variables
      returning only the PR id.
    - **Lesson, since this is twice now:** don't widen from an inferred op name. Item 23's `why`/
      `ops` logging exists so the deny log answers this directly — `just gql-denies` after a
      reproduction, or `GH_DEBUG=api` on the guest side as here.
    - **Deploy pending — `just deploy` ships items 19, 20, 22, 23 and 24 together.**

25. **`dl.google.com` opened read-only — Go toolchain tarballs (2026-08-04).** Added to
    `READ_ONLY_HOSTS` on request: GET/HEAD only, no creds injected, every other method denied.
    Matches the deny log exactly — one hit, `GET /go/go1.26.5.linux-amd64.tar.gz` at 12:03:24.
    Same shape as the `nodejs.org` entry (item 13): a toolchain download host, GET-only, so the
    exfil surface is data-in. Integrity note: unlike apt's mirrors, this is not gpg-signed — it's
    a bumped TLS fetch, so the guest trusts the tarball on the strength of our MITM CA plus
    Google's cert as the host validates it. Go's own `GOSUMDB` covers modules, not the toolchain
    tarball, so this is the same trust posture as the Node tarballs already flowing.
    - **Heads-up, deliberately NOT added:** Go *module* fetches don't use this host — they go to
      `proxy.golang.org` and `sum.golang.org` (and `GOPRIVATE` repos direct to github.com, which
      already works). Neither has ever appeared in the deny log, so nothing is added on spec;
      expect them the first time a `go build` resolves dependencies, and widen the same way.
      `google.com` was denied once back on 07-14 and stays denied — unrelated to this.
    - Tests now 127 cases (+5): the tarball GET and HEAD, POST/PUT denied, and a neighbouring
      Google host (`storage.googleapis.com`) confirming the entry doesn't leak past the exact host.

26. **Go modules + `meat.dev` opened read-only (2026-08-04).** Three more `READ_ONLY_HOSTS`
    entries, GET/HEAD only, no creds, all other methods denied:
    - **`proxy.golang.org` + `sum.golang.org`** — the module proxy and the checksum database,
      i.e. what `go build`/`go mod download` actually talk to (item 25's `dl.google.com` only
      serves the toolchain tarball). Worth noting these two **improve** integrity rather than
      trading it away, unlike the toolchain case flagged in item 25: `sum.golang.org` serves
      Merkle-tree checksums signed by Google's key, and `GOSUMDB` verification happens inside the
      Go client, so module contents are cryptographically verified end-to-end *through* our MITM
      bump — the proxy can't tamper with a module undetected. Blocking the sumdb while allowing the
      proxy would have been the worse combination (it pushes people to `GONOSUMDB`/`GOFLAGS` hacks).
    - **`meat.dev`** — requested for a planned install.
    - **All three added on spec: none has ever appeared in the deny log** (checked; zero lines for
      any of them, including the whole log history). That's a deliberate departure from the usual
      "widen from the deny log" rhythm, on request, and it's the reason the exact hostnames are
      worth double-checking if something still fails — a typo'd entry looks identical to a blocked
      host from the guest's side.
    - **Expect follow-on hosts if `meat.dev` is a `curl | sh` installer.** Same caveat as Mason
      (item 10): the script itself will load, but whatever it fetches next — a release asset, a
      CDN, a package registry — is a separate host and will 403 until added. github.com and the
      githubusercontent CDNs are already open, so a GitHub-hosted payload will just work.
    - Entries are **exact hosts, not suffixes**: `cdn.meat.dev` and `golang.org` stay denied. Tests
      cover both, so nobody later assumes subdomains ride along.
    - Tests now 137 cases (+10): module zip/list and a sumdb lookup allowed, POST denied on both
      Go hosts, meat.dev GET/HEAD allowed and POST denied, plus the two subdomain/bare-host denies.
    - **Deploy pending — `just deploy`, now carrying items 19, 20, 22, 23, 24, 25 and 26.**

27. **Addon renamed `github_filter.py` → `egress_filter.py` and restructured (2026-08-04).**
    The name had stopped describing the file: GitHub was the only destination when it was
    written, but by item 26 it also carried npm/cargo/Go/apt/CI/toolchain hosts, moon's
    version-check endpoint, and the deny-all fallback. Renamed, and the class with it
    (`GithubFilter` → `EgressFilter`).
    - **Structure:** four labelled sections — plumbing (logging/deny), GitHub policy, non-GitHub
      policy, handlers+dispatch — with a header comment stating the policy in one paragraph and
      the two editing rules (fail closed; widen from deny-log evidence, not from a guess).
    - **`request()` split into one handler per host family** (`_handle_github_api`,
      `_handle_github_web`, `_handle_codeload`, `_handle_launchpad`, `_handle_read_only`) behind
      an exact-host `HOST_HANDLERS` dict, with `READ_ONLY_HOSTS` as the tier checked after it and
      deny-all last. The old chain of `if host == ...` was 110 lines in one method and buried the
      non-GitHub rules in the middle of the GitHub ones.
    - **New import-time invariant:** a host present in *both* `HOST_HANDLERS` and
      `READ_ONLY_HOSTS` would silently get whichever tier is checked first — a quiet policy
      change. An `assert` on the intersection now catches that at load instead of in production.
    - **The three path-gated REST write families** (stacks, reviewers, branch cleanup) now share
      `_path_write_decision()` for their common tail (org-check the owner from the URL → inject
      PAT + log WRITE, or deny). Same deny strings, same log fields as before.
    - **Behaviour-preserving, and verified rather than asserted:** besides the 137 unit tests
      passing unchanged, every **distinct (host, method, path) in the whole 227 MB request log —
      211 of them** — was replayed through the old and new modules side by side, comparing both
      the allow/deny outcome and whether a credential got injected. **Zero mismatches.** That
      replay is the check worth repeating after any future restructure of this file.
    - **Deploy note: the unit changed too** (`-s /opt/vmguard/egress_filter.py`), so `just deploy`
      now also installs the unit, runs `daemon-reload`, and removes the pre-rename
      `/opt/vmguard/github_filter.py`. Syncing the unit on every deploy is a fix in its own right:
      item 11 needed a hand-edited unit, which is exactly the drift this prevents.
    - Kept as ONE file on purpose. Splitting into a package would mean sys.path games for a
      mitmproxy `-s` script and would break the single-file `install` + `restart` deploy, which
      is worth more than module separation at ~500 lines.

28. **A single IP opened fully — any port, any HTTP verb (2026-08-04, on request).**
    (Address changed to `100.54.242.68` on 2026-08-05; it was `54.162.59.179` as first added.
    The unit tests pin the exact value, so they failed loudly on the swap — working as intended
    for the one entry where a wrong address means an open channel to a stranger.
    **Retired 2026-08-11 — removed from `OPEN_HOSTS` on request, see item 33.** The rest of this
    item is kept as the rationale for the tier itself, which item 33's entries now use.)
    New `OPEN_HOSTS` set + `_handle_open()`. Unlike every other rule in the addon, this one
    allows all methods with arbitrary bodies.
    - **Stated plainly, because the file's whole purpose makes it worth stating: this is an
      unrestricted exfiltration channel.** Everything else here is read-only, credential-free,
      or org-gated precisely so a compromised guest cannot post data out; a host that accepts
      any verb with any body removes that property for that destination. The blast radius is one
      IP — the rest of the policy is untouched — but within it there is no gate at all. Opened
      on request; the operator's call on the operator's own infrastructure.
    - **No credentials are injected, by design and by test.** The GitHub PAT is the host's
      secret and never goes anywhere but GitHub. There's a unit test asserting the request
      headers stay empty for this host, paired with one asserting github.com *does* get the PAT,
      so the first test can't silently become vacuous.
    - **Everything is logged**, reads as `READ` and non-reads as `WRITE`, both tagged
      `open_host: true`. Writes therefore land in `just writes` next to the GitHub audit trail:
      if data ever leaves this way, the log is the only thing that will show it.
    - **Kept in its own set, never folded into `READ_ONLY_HOSTS`**, so reviewing the file shows
      the escape hatch immediately rather than hiding it in a 30-entry list. The import-time
      overlap assert (item 27) now covers all three tiers pairwise — with OPEN_HOSTS in play, an
      accidental duplicate could make a host far more open than the list it appears in suggests.
    - **"Any port" needed no code**: no rule in this file has ever matched on port, so a host
      entry already applies to all of them.
    - **Narrowing later is easy** if the real need is smaller than "everything" — `LAUNCHPAD_PATHS`
      (item 18) is the worked example of host+method+exact-path scoping, and moving this entry to
      that shape would restore the exfil boundary while keeping whatever actually needs to work.
    - Tests now 147 cases (+10): GET/POST/PUT/DELETE/PATCH and a deep path with a query string
      all allowed, a neighbouring address in the same /24 still denied (entries are exact hosts),
      and the two credential assertions above.

29. **PR update allowed — scoped REST PATCH (2026-08-05).** Restacking retargets each PR's base
    branch as the stack is reordered or merged, which is `PATCH /repos/{owner}/{repo}/pulls/{n}`.
    Deny log had it three times today — PRs 9065, 9070, 9054 — all "api.github.com write/mutation
    denied". New `PR_UPDATE_RE`, org-gated off the path like items 19/20/22.
    - **This grants the guest no capability it didn't already have.** `updatePullRequest` has been
      an allowed GraphQL mutation since item 14, and REST PATCH's fields (title, body, state,
      base, maintainer_can_modify) are a strict SUBSET of that mutation's input, which also
      carries assignees, labels, milestone and projects. The log shows both sides on the same
      day: PATCH denied 17:46:59, `ops: ["updatePullRequest"]` allowed 17:51:48. Transport parity,
      not a wider boundary — the third time this pattern has come up (items 19 and 22 were the
      others), because gh reaches for GraphQL and `gh api`/Octokit reach for REST.
    - **Anchored at the PR number** (`/pulls/[0-9]+$`), so no subpath rides along: PATCH on
      `/pulls/{n}/merge`, `/reviews`, `/requested_reviewers` stays denied, as does PATCH on
      `/repos/{o}/{r}` itself, on `/issues/{n}`, and on `/branches/{b}/protection` — the last
      being the one that would matter, since branch protection is the guard rail the org gate
      leans on. Only PATCH was opened; PUT/POST/DELETE on that path are unchanged.
    - **Verified by differential replay, not just unit tests:** every distinct (host, method,
      path) in the request log — 259 of them — run through the pre-change and post-change addon.
      **Exactly 3 decisions changed, all three the blocked PATCH calls.** Nothing else moved.
    - Tests now 164 cases (+18, −1): the three logged shapes, both write orgs, case-insensitive
      org, query string, the GET that already worked; denies for forbidden org, the three
      subpaths, non-numeric id, `/pulls` root, PUT/POST/DELETE, repo/issue/branch-protection
      PATCH, and both traversals. The removed case is the old `rev/pr_body_denied`, which
      asserted this PATCH was denied — it moved rather than vanished, so the reversal is
      deliberate and visible in the diff.

30. **CI artifacts, rustup, proto's install ping, and the design S3 bucket opened (2026-08-05).**
    Cleared four of the standing deny-log entries surfaced while investigating item 29. All
    read-only except the proto ping, none get credentials:
    - **`output.circle-artifacts.com`** — circleci serves build artifacts from a different host
      than `circleci.com` (already open since item 13), so task stderr/stdout logs and failed
      image-snapshot diffs were 403ing.
    - **`static.rust-lang.org`** — rustup channel manifests + toolchain downloads. Note the same
      integrity caveat as item 25's `dl.google.com`: signed by rustup's own detached signatures
      in principle, but as fetched here integrity rests on the bumped TLS plus our CA.
    - **`vxdesign-staging.s3.us-west-1.amazonaws.com`** — presigned election-package downloads
      for the design app. The presigned URL carries its own AWS signature, which we neither add
      nor need. **One exact bucket host only**: bare `s3.amazonaws.com` (which also appears in
      the deny log, probably an SDK region probe) and every other bucket stay denied, with tests
      pinning both — an S3 wildcard would be an allowlist hole big enough to drive anything
      through, since anyone can create a bucket.
    - **`launch.moonrepo.app POST /proto/install_tool`** — added to `LAUNCHPAD_PATHS` beside the
      version check from item 18. Item 18's justification ("body is just moon's version string,
      so the exfil surface is a fixed tiny payload") does NOT transfer unchanged, so the comment
      was rewritten rather than left to cover a second endpoint by implication: install_tool's
      body names the tool and version being installed — small and structured, but not constant,
      and not inspected. The honest bound is "a small POST body to two fixed endpoints on a known
      host". Still exact paths, not prefixes: `/proto/telemetry` and `/proto/install_tool_x` are
      denied, with tests.
    - **`api.ipify.org` and `ifconfig.me` deliberately left blocked** at the operator's direction.
      Both are public-IP echo services; something in the guest wants to know its external
      address. Probably a tool's connectivity check, but "what is my public IP" is also a
      reconnaissance primitive, and in this threat model that's worth identifying before opening.
      Also still blocked, as before: datadog, vercel and `cafe.github.com` telemetry,
      `mcp-proxy.anthropic.com`, and `cdn.agentclientprotocol.com` (never requested).
    - Tests now 176 cases (+12): reads allowed and writes denied on each of the three hosts, the
      bare-S3 and other-bucket denies, install_tool POST allowed with its GET denied, and the two
      path-prefix denies on the launchpad host.

31. **PR merge + review ops, Playwright/Debian-snapshot reads, doc sites, and two audit POSTs
    (2026-08-10).** Swept the deny log since the 2026-08-08 16:23 deploy — 166,974 records, of
    which all but ~70 are noise (see the bottom of this item). What was actually blocking work:
    - **PR merge, all four transports.** At 14:34–14:45 on 08-10 a single merge of
      `votingworks/vxsuite#9099` fell back through every route it had as each one 403'd:
      GraphQL `mergePullRequestsInStack`, GraphQL `mergePullRequestAsync`, REST
      `PUT /pulls/9099/merge`, REST `PUT /pulls/9099/merge-async`. `mergePullRequest` has been
      allowed since item 14, so all four are the **same capability in different shapes** — the
      same transport-parity argument item 29 made for REST `PATCH /pulls/{n}`. Added the two
      mutations to `MUTATION_ALLOW` and a new `MERGE_PR_RE` + `PUT` branch for the REST pair.
      The org gate is untouched and still does the work: `InStack` merges several PRs at once,
      but every id it names must resolve into `WRITE_ORGS` or the whole call is denied.
    - **Caveat on `mergePullRequestsInStack`:** it was denied at the op-allowlist stage, so its
      variables were never resolved and **we do not know what node ids it carries**. If it names
      a stack id rather than `pullRequestIds`, `_resolve_owners` has no fragment for that
      typename and will fail closed — the deny will then read `"why": "no resolvable target
      org", "ops": ["mergePullRequestsInStack"]`, and the fix is one more `... on X` fragment in
      `_RESOLVE_Q`. Left as-is rather than guessing the typename; the log will name it.
    - **`addPullRequestReview`** (`gh pr review`, denied 08-09 18:38) added to `MUTATION_ALLOW`.
      It is a PR-scoped body-text write, the same shape as `addComment`, which item 14 already
      allowed. Its siblings (`submitPullRequestReview`, `addPullRequestReviewComment`) have
      **not** appeared in the log and stay denied — widen from evidence, not from symmetry.
    - **`playwright.download.prss.microsoft.com`** — `cdn.playwright.dev` had been added
      (uncommitted, but already deployed) and was not enough: the CDN 302s the actual browser
      bundles to this host, so `playwright install` still 403'd on the payload. Same
      redirect-target gap as item 30's `output.circle-artifacts.com`.
    - **`snapshot.debian.org`** — date-pinned pool + the `/mr/binary` metadata API, fetched
      while pinning chromium's runtime deps. Same read-only class as `deb.debian.org`.
    - **`npm.jsr.io`** — JSR's npm-compat registry (one `HEAD /` probe). `crates.io` itself was
      also still missing beside the two `*.crates.io` entries; added here.
    - **Seven documentation sites opened on request**: `docs.github.com`, `bugs.debian.org`,
      `tanstack.com`, `lefthook.dev`, `typicode.github.io`, `rust-lang.github.io`,
      `pre-commit.com`. One GET each — no tool depends on them, this is what the agent reads
      while working. Flagged at the time and worth repeating: this is **whack-a-mole by
      construction**, since the next doc site will 403 too. Still exact hosts, so
      `torvalds.github.io` does not ride along on `rust-lang.github.io` (test pins it).
    - **Two dependency-audit POSTs opened on request**, via a new `READ_ONLY_POST_PATHS`
      `{host: {paths}}` dict consulted by `_handle_read_only`: `registry.npmjs.org POST
      /-/npm/v1/security/advisories/bulk` (`npm audit`) and `api.osv.dev POST /v1/querybatch`.
      **This is the widest thing in this item and the comment says so.** Item 18/30's launchpad
      rationale does not transfer at all: those bodies are a version string and a tool name,
      whereas these are large JSON shaped by the guest's own lockfile, and they are not
      inspected. The honest bound is "a JSON body to two fixed endpoints on two known hosts".
      They log as `WRITE` with `post_exception: true`, so they show up in `just writes` rather
      than passing silently. Revoke by deleting the dict entry — that restores GET/HEAD-only.
    - An import-time assert rejects a `READ_ONLY_POST_PATHS` host that isn't in
      `READ_ONLY_HOSTS`, since dispatch would never reach the handler and the entry would be
      dead config.
    - **Deliberately still denied.** `localhost` (165,507 GETs — item 15's `NO_PROXY` noise, and
      the reason `requests.log` is back to 312 MB), datadog (1,404), `cafe.github.com`
      telemetry POSTs (27, as item 30), `mcp-proxy.anthropic.com`, and `clients2.google.com
      /time/1/current?cup2key=…` (8 — Chrome's component-updater time sync, telemetry-adjacent
      and harmless to fail).
    - **One deny worth a human look:** `2026-08-09T18:40:56`, a git push to
      **`theRizwan/recast`** — a personal repo outside `WRITE_ORGS`. The gate stopped it at the
      `info/refs?service=git-receive-pack` advertisement, exactly as designed, but nothing else
      in the log explains why the guest tried. Not widened.
    - Tests now 233 cases (+57).

32. **Google Antigravity: five read-only hosts plus two POST exceptions (2026-08-11).** The
    Antigravity host block had been added read-only and undocumented; the deny log for
    `13:44`–`13:49` on 08-11 shows the install actually walking the whole flow, and two steps of
    it are POSTs that the GET/HEAD tier could never pass:
    - **Reads (already covered, now tested):** `antigravity.google /cli/install.sh`, the CLI's
      update manifest on the `…run.app` host, the tarball from `storage.googleapis.com`, and
      Unleash's `GET /api/client/features`.
    - **`oauth2.googleapis.com POST /token`** — the OAuth code/refresh exchange. Denied twice
      (`13:47:50`, `13:49:38`), and sign-in cannot complete without it. Body is the standard
      small form-encoded grant. Added to `READ_ONLY_POST_PATHS`, so it rides the existing
      mechanism from item 31 rather than a new one, and logs as `WRITE` with
      `post_exception: true`.
    - **`antigravity-unleash.goog POST /api/client/register`** — the flag SDK's one-time
      handshake before it starts polling `/api/client/features`. Small structured body; like
      every entry in that dict it is **not inspected**.
    - **Deliberately still denied:** `antigravity-unleash.goog POST /api/client/metrics` and
      `play.googleapis.com POST /log` (4 denies) — both pure telemetry, nothing stops working
      without them, and a periodic guest-authored POST body is precisely what this gate is for.
      Same call as item 30/31's `cafe.github.com` telemetry. `play.googleapis.com` is therefore
      not in `READ_ONLY_HOSTS` at all.
    - **Worth a second look, not changed here:** `storage.googleapis.com` is a *multi-tenant*
      bucket host, so unlike `vxdesign-staging.s3…` (one bucket, item 27) the entry admits GETs
      to any public GCS bucket, not just `/antigravity-public/…`. Adding it also removed item
      25's `ro/other_google_host` test, which existed to pin that `dl.google.com` did not admit
      neighbouring Google hosts. Narrowing it would mean a path-prefix rule, which no host rule
      in this file has today.
    - Tests now 247 cases (+14).

33. **Antigravity's Code Assist backend opened fully (2026-08-11).** With sign-in working,
    `just denies-since` showed the post-sign-in session bootstrap 403ing:
    `POST /v1internal:{loadCodeAssist,setUserSettings,listExperiments}` on
    **`cloudcode-pa.googleapis.com`** and its **`daily-`** channel (14 + 6 denies), plus
    `www.googleapis.com GET /oauth2/v2/userinfo` (2).
    - **`www.googleapis.com`** added read-only for the userinfo GET. Same multi-tenant caveat as
      item 32's `storage.googleapis.com`, and sharper here: the guest now holds its own Google
      OAuth token, so this entry is only as narrow as that token's scopes. Not credential-free
      in the way the rest of the tier is — we inject nothing, but the guest supplies its own.
    - **The two `cloudcode-pa` hosts went into `OPEN_HOSTS`, not the POST-path dict.** They were
      first added as three exact paths each; that was reverted the same day, on request, to
      avoid the whack-a-mole — those three RPCs are only the bootstrap, and the model-traffic
      RPCs (`:generateContent` & co.) would have 403'd next, followed by whatever the client
      reaches for after that.
    - **What that costs, stated plainly.** This is the agent's *model* backend, so its request
      bodies are prompts — whatever the guest has read — and nothing in this file can tell a
      prompt from an exfil payload. The honest comparison is `api.anthropic.com`, which the
      systemd unit tunnels with `--ignore-hosts` and never even bumps: the same bargain, already
      struck, and this one is at least logged (`open_host: true`, so it lands in `just writes`).
      No credentials are injected, per the rule that the PAT never leaves GitHub — the guest's
      Google token is its own. Narrowing to `:generateContent` & co. remains possible if it ever
      seems worth it.
    - **Still denied on purpose:** `play.googleapis.com POST /log` (3 more) — telemetry, per
      item 32. Opening the two cloudcode hosts did not open `googleapis.com` generally; a test
      pins that.
    - **`100.54.242.68` removed from `OPEN_HOSTS`** on request — no longer needed, so the
      fully-open tier is now exactly the two cloudcode hosts. The item 28 address is denied
      again like any unlisted host, and two tests pin that. The `open/*` tests that covered the
      tier's behaviour were repointed at `cloudcode-pa.googleapis.com`.
    - Tests now 269 cases (+22).

34. **Playwright's driver mirrors and the Google avatar host (2026-08-11, after the item 33
    deploy).** Four more read-only hosts, all plain GETs, all straight off `just denies-since`:
    - **`playwright{,-akamai,-verizon}.azureedge.net`** — `GET /builds/driver/playwright-
      1.57.0-linux.zip`, all three within three seconds as the client walked its mirror list
      until one answered. Item 31 opened `cdn.playwright.dev` and the prss host, but those carry
      the **browser builds**; the **driver** bundle comes from this trio, so `playwright install`
      was still broken in a second, different place. Third time this tool has needed a host that
      the previous fix didn't reveal — see also item 30's `output.circle-artifacts.com`.
      Listing all three mirrors is deliberate: pinning one just moves the 403 to the next
      fallback. Exact hosts, so `someoneelse.azureedge.net` does not ride along (test pins it).
    - **`lh3.googleusercontent.com`** — the signed-in user's Google profile picture, shown in
      Antigravity's UI. Cosmetic, one GET of an opaque avatar id. Sibling CDNs (`lh4…`) are not
      covered; exact host as always.
    - **`play.googleapis.com POST /log` denied 4 more times and stays denied** — telemetry, per
      items 32 and 33. It keeps reappearing in the log because it retries, not because anything
      is broken; the count is expected noise now.
    - Tests now 278 cases (+9).

35. **GitButler CLI (`but`) install (2026-08-12, requested ahead of first use).** Three
    read-only hosts — `gitbutler.com`, `app.gitbutler.com`, `releases.gitbutler.com` — which
    is the *whole* install, not a first guess at it. Unusually for this file, the chain was
    read out of the installer rather than off the deny log, so it is worth recording what it
    actually does. `curl -fsSL https://gitbutler.com/install.sh | sh` is a 124-line bootstrap
    that downloads and `exec`s a Rust binary, and between them they make five GETs:
    1. `gitbutler.com GET /install.sh` — the bootstrap itself.
    2. `app.gitbutler.com GET /installers/info/linux/x86_64` — metadata JSON naming the
       installer binary.
    3. `releases.gitbutler.com GET /installers/latest/linux/x86_64/but-installer` — that binary
       (~1.7 MB, stripped ELF).
    4. `app.gitbutler.com GET /releases` — the release manifest. Its per-platform entries carry
       the minisign signature **inline, base64 in the JSON**, so there is no separate `.sig`
       fetch to allow; the installer verifies with a public key compiled into itself
       (`minisign-verify` is linked in). `/releases/nightly` and `/releases/version/{v}` are the
       same endpoint's other two shapes, and the installed CLI re-reads them to self-update.
    5. `releases.gitbutler.com GET /releases/release/{ver}/linux/x86_64/but` — the ~42 MB
       binary, installed to `~/.local/bin/but`.

    All five are GETs, so the plain read-only tier fits without a single POST exception — no
    `LAUNCHPAD_PATHS`-style carve-out, nothing uninspected leaving the guest. The installer also
    string-matches its own two redirect guards (`https://app.gitbutler.com/*` on the metadata
    hop, `https://releases.gitbutler.com/*` on both downloads) and aborts on anything else, so
    it cannot be steered off these three hosts even if the manifest is tampered with — a second
    lock that happens to agree with our exact-host rule. Exact hosts as always: `docs.` and
    `api.gitbutler.com` are *not* admitted (tests pin both).

    What this deliberately does **not** open, all of it visible in the shipped binary's strings
    and all of it runtime rather than install:
    - **`eu.i.posthog.com` / `us.posthog.com` / `app.posthog.com`** — product telemetry. Same
      call as items 30/32/33: periodic POST with a guest-authored body is exactly what the gate
      exists to stop, and nothing breaks without it. Expect these in the deny log; that is the
      design, not a bug.
    - **`openrouter.ai`, `api.openai.com`** — the CLI's own AI features. Left shut; `but`'s git
      work does not need them, and Claude Code already has `api.anthropic.com` tunnelled.
    - **`www.gravatar.com`** — commit-author avatars, cosmetic.
    - `docs.gitbutler.com` is only *printed* by the installer as a "for more information" line,
      never fetched. If the agent later reads those docs it will 403 like every other doc site
      in item 31, and that is when to add it — from evidence, not now. *(It did, within half an
      hour of the deploy — see item 36.)*
    - GitButler's forge integrations reach `github.com` / `api.github.com` (already gated,
      including the native stacked-PR endpoints from item 29 that 0.22.0 now uses) and
      `gitlab.com` / `api.bitbucket.org` / `id.atlassian.com` (not opened — no need here).
    - `but agent setup`, which the installer offers interactively, writes a local skill file for
      Claude Code/Codex; no host in the binary corresponds to fetching it, so it should need
      nothing new. Watch the log the first time it runs.
    - Tests now 294 cases (+16).

36. **GitButler's docs and blog (2026-08-12, ~30 min after the item 35 deploy).** Two read-only
    hosts off `just denies-since`, both a single GET, both the agent reading while it worked —
    which is the item 31 doc-site tier exactly:
    - **`docs.gitbutler.com`** — `GET /cli-overview`. Item 35 called this one and deliberately
      left it out pending evidence; the evidence took half an hour.
    - **`blog.gitbutler.com`** — `GET /git-worktrees`, logged in the same second as an allowed
      `github.com GET /gitbutlerapp/gitbutler/issues/10677`, so this was one research pass
      spanning three hosts and only the blog 403'd.

    Five `*.gitbutler.com` subdomains are now open and still no wildcard: `api.gitbutler.com`
    stays denied and is pinned by a test, as is `gitbutler.io`. Worth naming the pattern, since
    item 35 predicted this and item 34 said the same thing about Playwright: for any tool the
    agent actually *uses*, the install hosts and the read-while-working hosts arrive as two
    separate rounds of 403s, and opening the first tells you nothing about the second.

    **`eu.i.posthog.com POST /i/v0/e/` denied 6 times and stays denied** — GitButler's product
    telemetry, called in item 35 and unchanged. It is also the only *positive* evidence in the
    log that `but` installed and ran at all: the read-only tier does not log allowed reads
    (`_handle_read_only` returns before `_log`), so a working install leaves no trace on
    `gitbutler.com`/`app.`/`releases.` — absence of denies there is not confirmation, and the
    telemetry retrying is. Worth remembering the next time this tier gets debugged.
    - Tests now 298 cases (+4).

37. **PyPI and uv (2026-08-12, on request after the item 36 deploy).** The deny log showed
    `pypi.org GET /simple/{pillow,python-barcode}/` and `astral.sh GET /uv/install.sh`, and both
    were requested as read-only hosts. **Four** hosts went in, not the two that 403'd, because in
    both cases the host in the log is an index/vanity host and the bytes live somewhere else —
    the item 36 two-rounds pattern, pre-empted this time instead of waited out:
    - **`pypi.org` + `files.pythonhosted.org`** — `pypi.org` serves the `/simple` index and the
      `/pypi/*/json` API, but every wheel and sdist it links to is on `files.pythonhosted.org`
      (checked: the JSON simple-index for `python-barcode` resolves to that host and no other).
      Opening only the index would resolve a version and then 403 the download. Integrity is
      pip's own hashes, the same bargain as the apt mirrors.
    - **`astral.sh` + `releases.astral.sh`** — `astral.sh/uv/install.sh` is a **302** to
      `releases.astral.sh/installers/uv/latest/uv-installer.sh`, so the vanity host alone
      redirects the installer straight into a deny; that hop is not optional. `releases.astral.sh`
      is also the first of two binary mirrors the script walks (line 39 of the installer lists
      them space-separated), the second being `github.com/astral-sh/uv/releases/download/…`,
      already open via the `github.com` read rule — so the download had a working fallback but
      fetching the script at all did not.
    - Still exact hosts: `test.pypi.org`, the bare `pythonhosted.org`, `docs.astral.sh` and
      `upload.pypi.org` are all denied and pinned by tests. That last one is the point of the
      tier — `twine upload` is a POST to `upload.pypi.org/legacy/`, i.e. publishing a package is
      the exact write-out this gate exists to stop, and GET-only forecloses it.
    - **Three more telemetry endpoints denied and staying denied**, per items 30/32/33/36:
      `telemetry.vercel.com POST /api/turborepo/v1/events` (80 hits — turborepo, by far the
      chattiest yet; `turbo.build` is open for docs and that is all it needs),
      `eu.i.posthog.com POST /i/v0/e/` (8, GitButler), and `cafe.github.com POST
      /twirp/clientappsfe.observability.v1.TelemetryAPI/RecordEvents` (7, item 30's).
    - Tests now 314 cases (+16).

38. **`resolveReviewThread`, and the resolver fragment it needed (2026-08-12, on request).**
    "Mark this review conversation resolved." Denied 11 times — ten inside one second at
    17:22:31 plus a retry 23s later, the same fall-back-and-hammer shape as item 31's merge.
    Requested, and an easy yes on its own merits: the mutation's entire input is a thread id and
    nothing else, so unlike `addComment` or `addPullRequestReview` it carries **no
    caller-authored content at all** — it is the narrowest write in `MUTATION_ALLOW`.

    **The catch, and the reason this is a two-line change and not a one-line one:** allowlisting
    the op by itself does not work. `resolveReviewThread` takes a `PullRequestReviewThread` id
    (`PRRT_…`), and `_RESOLVE_Q` had fragments only for Repository / PullRequest / Issue /
    IssueComment / Label. An unrecognized typename resolves to no owner, so `_resolve_owners`
    returns `None` and the call fails closed — the op would sit in `MUTATION_ALLOW` and still be
    denied, logged as `"no resolvable target org"` rather than `"op not in allowlist"`. Verified
    directly: with the node returning only `__typename`, `_resolve_owners` gives `None`. That is
    a genuinely confusing failure to debug, because the deny reason points away from the fix.

    So `... on PullRequestReviewThread{repository{owner{login}}}` went in alongside it
    (`PullRequestReviewThread.repository` is a non-null `Repository`, so the fragment always
    resolves). **This is the first allowed mutation to name a target type outside the original
    five**, which makes it the worked example of a rule that was implicit until now and is now
    commented at `_RESOLVE_Q`: *adding a mutation whose input takes a new kind of node id means
    adding a fragment too.* A test loop pins all six typenames so the pairing can't silently
    drift, and `resolve/review_thread` covers the classification itself.

    The org gate is untouched and does the same work as always: the thread id resolves through
    its repository to an owner, which must be in `WRITE_ORGS`, so this cannot reach a PR outside
    them. `unresolveReviewThread` is deliberately **not** included — nothing has asked for it and
    the deny log is where that call should come from, same reasoning as the un-request-reviewer
    `DELETE` in item 29. A test pins it as still denied, by op, so adding it later is a
    one-word change with a failing test to flip.
    - Tests now 327 cases (+13).

39. **Inline GraphQL node ids — a bypass of the org gate, found by watching item 38 fail
    (2026-08-12).** Item 38 deployed at 17:38:54 and `resolveReviewThread` was tried once more
    at 17:39:23. It got *further* — `"why"` moved from `"op not in allowlist"` to
    `"no resolvable target org"`, so the allowlist entry worked — and still 403'd. The cause turned
    out to be much more interesting than a missing host.

    **`_collect_node_ids` only ever walked `variables`.** But GraphQL lets a caller write
    arguments straight into the document:

        mutation{resolveReviewThread(input:{threadId:"PRRT_kwABC"}){thread{isResolved}}}

    which is what `gh api graphql -f query=...` and any other unparameterized client sends. For
    that body the collector finds nothing, `_resolve_owners(set())` returns `None`, and the call
    fails closed. That is the *functional* half, and it is why item 38 looked complete but wasn't.

    **The security half:** the same blind spot let a mutation pass the org gate while writing
    somewhere it shouldn't. Put a benign id in `variables` and the real target inline —

        query:     mutation{addComment(input:{subjectId:"PR_<other org>",body:"…"}){clientMutationId}}
        variables: {"id":"PR_<a votingworks PR>"}

    — and the gate resolved only the decoy, found `votingworks`, and returned `mutation-ok`. The
    inline target was never resolved and never checked. Verified before changing anything:
    `_collect_node_ids` on that body returns just the decoy. So the promise at the top of the
    GitHub section — *"every node the mutation touches resolves to an org in `WRITE_ORGS`"* — was
    not true for any argument written inline. The blast radius was bounded by the PAT's own
    scope rather than by this file, which is not where the boundary is supposed to live.

    **Fix: `_scan_inline_node_ids`**, a string-aware scan of the document that collects literals
    under an id-shaped key, unioned with the `variables` walk before resolution. Both halves close
    at once — the inline call now resolves and is *checked* rather than merely denied. Design notes:
    - It reuses `_is_node_id_key`, so `clientMutationId` and `*Oid` are skipped exactly as in
      `variables`, and — the point of the key rule — a comment **body** that happens to quote a
      node id is not mistaken for a target. Collecting every string literal instead would have
      denied any comment discussing another repo's PR.
    - The first version was wrong and a test caught it: `labelIds` ends in `"ids"`, not `"id"`,
      so `_is_node_id_key` rejects it — `_collect_node_ids` handles plural keys in a *separate*
      branch, which the scanner initially didn't mirror. Every id in a `labelIds: [...]` list was
      silently dropped. Hence `_is_node_id_list_key`, with `oids` excluded for the same reason
      `oid` is. Anything relying on parallel logic in two places deserves the paired test.
    - Malformed input (unterminated literal) returns `ok=False` and denies, as elsewhere.
    - `n_ids` was added to the `"no resolvable target org"` deny detail: `0` means nothing
      id-shaped was found in the call at all, `>0` means ids were found and the resolver rejected
      them. Those are completely different bugs and were indistinguishable in the log — the same
      motivation as item 23's `why`/`ops`. A count only, never the body.
    - Tests now 345 cases (+18), including the decoy attack in both a singular and a plural shape,
      which are the regression tests for the bypass itself.

40. **`turborepo.dev` (2026-08-12, on request).** One read-only host, one GET: `/schema.json`.
    Turborepo's older domain, still what a `turbo.json` `"$schema"` can point at, so this is a
    functional read (schema resolution) rather than a doc-site read — the same shape as
    `www.schemastore.org`, already open since the initial import. `turbo.build`, the current
    domain, was already listed; nothing about either admits `telemetry.vercel.com`, whose
    `POST /api/turborepo/v1/events` keeps 403ing per item 37 and stays denied. A test pins that
    contrast, so the distinction between "turborepo's schema" and "turborepo's telemetry" is
    recorded rather than re-litigated.
    - Tests now 349 cases (+4).

41. **Review-thread replies, and an audit of every allowed mutation's inputs (2026-08-13, on
    request).** Three capabilities were asked for. **Two of them were already allowed** — and the
    log shows them working, so nothing was needed:
    - `markPullRequestReadyForReview` / `convertPullRequestToDraft`: in `MUTATION_ALLOW` since
      item 14, with **8 and 2 successful `WRITE`s** in `requests.log` and **zero denies ever**.
      `gh pr ready` is not blocked by this gate; if a flip needed a UI click, the cause is
      elsewhere (client, auth, or a stale `gh`).
    - `enablePullRequestAutoMerge` / `disablePullRequestAutoMerge`: also allowed since item 14,
      but **never once attempted** — no log line of any kind. "Set auto-merge and walk away"
      should already work; the first attempt is the thing to watch.
    - Also confirmed while here: `resolveReviewThread` has now succeeded once (`WRITE`), so items
      38 + 39 together actually landed.

    **`addPullRequestReviewThreadReply` was the one genuinely missing** and is now allowed. Body
    text scoped to a thread, the same shape as `addComment`, and it completes the loop the resolve
    mutation started: address a comment → reply "done in `<sha>`" → resolve. Per the question
    asked: **the REST route is _not_ a way around it** — `POST /pulls/{n}/comments/{id}/replies`
    matches no rule in `_handle_github_api`, so it 403s regardless of org, and there are zero
    attempts at it in the log. Two tests pin that, so the answer is recorded rather than
    re-derived. Adding a path regex for transport parity (as items 29/31 did for PR update and
    merge) is a later call if a client ever insists on REST.

    **The audit.** Item 38's lesson — an allowlisted op whose target type has no `_RESOLVE_Q`
    fragment is allowed *and then denied*, reported misleadingly as "no resolvable target org" —
    is a whole class of latent bug, so rather than fix one instance again, every allowed mutation's
    input was checked against the resolver using GitHub's published schema
    (`octokit/graphql-schema`). Three real gaps, all pre-existing:
    - **`PullRequestReview`** — `addPullRequestReviewThreadReply.pullRequestReviewId`, optional,
      set when the reply belongs to a pending review. Would have broken the new op intermittently:
      fine for a plain reply, denied inside a pending review.
    - **`Milestone`** — `milestoneId` on `createIssue`, `updateIssue` **and** `updatePullRequest`,
      all allowed since item 14. Setting a milestone would have failed closed for the last two
      years of this file's life. Nobody hit it, which is exactly why an audit found it and the
      deny log didn't.
    - **`Discussion`** — `labelableId` on `add`/`removeLabelsFromLabelable` accepts one.

    All three have `repository: Repository!`, so all three are one fragment each, same shape as
    the rest. **`Project` / `ProjectV2` are deliberately left out**: they have no `repository`
    field at all, only `owner`, an interface resolving to an Organization or User, so they are not
    repo-scoped and don't fit `repository{owner{login}}`. `projectIds` on those same three
    mutations therefore still fails closed. Opening it is a policy question — does an org-level
    project count as "in `WRITE_ORGS`"? — not a missing line, and nothing has needed it. Tests pin
    both the nine fragments that must be present and the two that must not.

    **`unresolveReviewThread` now has deny-log evidence** (once, 14:35:26), which is the trigger
    item 38 said to wait for. Still not opened — it wasn't part of this request, and the test
    pinning it as denied-by-op is still passing, so it remains a one-word change.
    - Tests now 363 cases (+14).

42. **moshi-hook: install read-only, daemon backend fully open (2026-08-16, on request).** Asked
    for ahead of use: `curl -fsSL https://getmoshi.app/install.sh | sh` then `moshi serve &`.
    The deny log had `getmoshi.app GET /install.sh` twice (08-10 and again 08-16 08:22) and
    **nothing else** — the install never got past its first byte, so the log could not have
    revealed the rest. Read out of the installer and the shipped binary instead, per item 35.
    **Three hosts, in two very different tiers.**

    **Install — `getmoshi.app` + `cdn.getmoshi.app`, read-only.** The whole chain is four GETs:
    `getmoshi.app/install.sh` → `cdn/hook/latest/version.txt` (resolves `v0.2.85`) →
    `cdn/hook/$VERSION/moshi-hook_Linux_x86_64.tar.gz` → `cdn/hook/$VERSION/checksums.txt`.
    GET-only fits exactly; no POST exception, nothing uninspected leaving the guest. The CDN host
    is overridable (`MOSHI_HOOK_CDN`) but defaults to `cdn.getmoshi.app`, which is what the
    entry pins.
    - **Integrity is corruption-only, not tamper-proof**, and worth stating since item 26 made the
      opposite point about `sum.golang.org`: `checksums.txt` is fetched from the *same host* as the
      tarball it checksums, with no signature over it. It catches a truncated download, not a
      malicious CDN. Same posture as `dl.google.com` (item 25) — bumped TLS plus our CA. Verified
      the published sha256 against the actual bytes by hand while reading it; they matched.

    **Daemon — `api.getmoshi.app`, in `OPEN_HOSTS`.** This is the interesting half, and it is the
    first entry in this file whose tier was chosen for a reason other than "how wide is the need".
    - **A read-only entry could not have constrained it.** `moshi serve` reaches the backend as
      `GET wss://api.getmoshi.app/api/v1/hosts/<hostId>/connect` — a **WebSocket**. The upgrade is
      a GET, so `READ_ONLY_HOSTS` would have admitted it, and the entry would have sat in the
      narrowest-looking tier in this file while this addon implements only `request()`: once
      mitmproxy passes the 101, frames flow **both ways, unfiltered and unlogged**. Method-based
      rules cannot gate a WebSocket. So `OPEN_HOSTS` here is not a widening over the read-only
      tier — it is the same access, labelled honestly and with `open_host: true` in the log.
      **Generalise this**: any future tool that opens a persistent socket gets the same treatment
      regardless of what verb its handshake uses. That's now commented at the entry itself.
    - **What crosses it, from the shipped `docs/api.md`.** Outbound: agent events —
      `cwd`, `projectName`, `toolName`, `modelName`, `contextPercent`, and the command text
      (their own worked example is `"message": "rm -rf node_modules"`), plus usage snapshots.
      Inbound: `approval.decision` frames carrying `actionId` + approve/deny.
    - **That inbound direction is the genuinely new thing in this policy.** Every other rule here
      is data-in or gated data-out; this is the first *control* channel pointing inward — a remote
      party's tap on a phone unblocks a tool call inside the guest. It is bounded by the daemon
      only forwarding hooks it raised and only honouring decisions for its own action ids, but
      that is the daemon's logic, not this gate's. Named plainly because the operator chose it
      knowing that, on the operator's own infrastructure — same call, same reasoning, as item 33.
    - Only the handshake lands in `just writes`; frame traffic after it is invisible here by
      construction. Do not read a quiet log as a quiet channel for this host.

    **Not opened, and worth knowing before first run:**
    - **The installer runs the binary immediately** (`moshi-hook set --first-run`, unless
      `MOSHI_HOOK_SKIP_FIRST_RUN=1`), and the script's own comment says the two options are
      *"always-on-discovery + usage-collection, both on"*. Usage sync is `POST /hosts/:id/usage`
      on the now-open host, so it is allowed — it does not need a separate decision, but nothing
      in this file will stop it either. Set the env var if that isn't wanted.
    - **`moshi install` writes hook configs into the guest's agents** (Claude Code, Codex,
      Antigravity, Gemini CLI, Cursor, Kimi and more per `docs/usage.md`). That is a guest-side
      config change, outside this gate entirely, but it is how agent events start flowing.
    - **`moshi host setup` adds an SSH public key to the guest's `authorized_keys`** and prints a
      QR to claim it. Inbound access, so the egress filter has no view of it; the isolated net has
      no route in either, so a phone can only reach the guest via the existing host:2222 forward
      (item 7). The docs' own warning applies — treat that QR as a bearer token.
    - **Other backends in the binary's strings, all left denied**: `api.openai.com`,
      `chatgpt.com` / `chat.openai.com`, `api.kimi.com`, `cli-chat-proxy.grok.com`, `go.dev`.
      These are per-agent integrations for agents not in use here. `cloudcode-pa.googleapis.com`
      (already open, item 33) and `api.anthropic.com` (tunnelled in the unit) also appear.
    - The daemon's localhost listeners — gateway plus the `moshi diff` viewer on `24543` — are
      loopback and covered by item 15's `NO_PROXY`; they should never reach the proxy.
    - Tests now 379 cases (+16): the four install GETs, HEAD, no-creds and POST denies on both
      install hosts; the WS handshake and four HTTP shapes allowed on the api host with its own
      no-creds assertion; and `moshi.app` / `ws.getmoshi.app` pinned denied so neither tier leaks
      to a neighbour.
    - **Deploy pending — `just deploy` (needs sudo).**

43. **CircleCI job retry — the second host-side credential (2026-08-16, on request).** The ask:
    let the guest retry a failed CI job, with an injected credential like GitHub's PAT, and
    **nothing else**. That lands as one endpoint — `POST /api/v2/workflow/{uuid}/rerun` — and it
    is the first time anything but GitHub gets a credential from this gate, so the reasoning is
    written out in full at section 3a of the addon as well as here.

    **No deny-log evidence exists for this, and none could.** `circleci.com` has been allowed
    read-only since item 13, and `_handle_read_only` doesn't log allowed reads — so the only
    circleci lines in the whole log are three pre-allowlist denies from 2026-07-13
    (`GET /api/v2/project/gh/votingworks/vxsuite/pipeline?branch=…`, the shape the agent uses to
    find a run). Designed off the published API instead, like items 35 and 42.

    **Reads did not change, and take no token.** vxsuite is a public project, so its
    pipeline/workflow/job/test endpoints answer unauthenticated; the token is injected on the
    rerun POST only. `circleci.com` did have to *leave* `READ_ONLY_HOSTS` for its own handler —
    not to widen reads, but because `READ_ONLY_POST_PATHS` matches exact paths and this one
    carries a uuid — so the import-time overlap assertion stays satisfied. GET/HEAD behaviour is
    byte-for-byte what the read-only tier gave.

    **Three gates on the write, all of which must pass:**
    - **Path.** `CIRCLE_RERUN_RE` matches the rerun endpoint and nothing else, against the RAW
      path with a hex/dash-only uuid charset — no `%`, so no percent-decoding differential can
      move the target (same reasoning as `STACK_WRITE_RE`, item 19).
    - **Body.** Only the documented rerun fields, correctly typed: `from_failed`, `jobs` (a
      non-empty list of job uuids), `sparse_tree`. This is the **first write in this file whose
      body is fully validated** — `LAUNCHPAD_PATHS` (item 18) and `READ_ONLY_POST_PATHS` (item 31)
      both let guest-authored bytes out uninspected; this one lets out flags and uuids, so it adds
      no exfil surface at all. `enable_ssh` is documented by CircleCI and deliberately **not**
      accepted: it starts the rerun with an SSH session on the job container, which is a debug
      shell on someone else's infrastructure rather than a retry, and it is mutually exclusive
      with `from_failed` so no retry needs it.
    - **Org.** A workflow id is an opaque uuid — the same problem as a GraphQL node id, and it
      gets the same answer: the **host** asks CircleCI `GET /api/v2/workflow/{id}`, reads
      `project_slug` (`gh/votingworks/vxsuite`), and checks the org against
      `CIRCLE_RERUN_ORGS`, which is `WRITE_ORGS`. The guest never names its own target. Any
      failure — unknown id, timeout, junk slug — is a deny. The newer `circleci/<org-uuid>/
      <project-uuid>` slug form parses and then fails the check, because a uuid is not a login;
      that's the right outcome rather than a bug to fix.

    **Status is logged, not gated** (your call, and I agree with it): rerunning a green workflow
    is the same capability — re-running a flaky job to confirm it — and a status gate would also
    race, since the workflow can finish between the resolve and the rerun. `wf_status` goes in
    the WRITE record so `just writes` shows what was retried and in what state.

    **Be clear about what a rerun is.** It re-executes that workflow's config against the commit
    it already ran on: not a way to run new code — the guest can only rerun what someone already
    pushed — but it does spend CI time and it restarts jobs that have the project's own secrets
    in their environment. Scoping it to `WRITE_ORGS`, the repos the guest can already push to, is
    what keeps that inside the boundary item 14 already drew.

    **The token is account-wide, and that is not fixable.** CircleCI does not accept
    project-scoped tokens on API v2 at all, so `CIRCLE_TOKEN` must be a *personal* API token with
    full read/write everywhere the account reaches. Unlike a fine-grained GitHub PAT there is no
    way to scope the credential itself — the addon is the entire narrowing, which is exactly why
    the path/body/org gates above are as tight as they are.

    **Missing token = a per-request deny, not a dead gate.** `GH_PAT` is read with `os.environ[…]`
    and crashes the addon at import if absent; `CIRCLE_TOKEN` is read with `.get()` and, when
    unset, denies just the rerun (`"no CIRCLE_TOKEN configured host-side"`) while everything else
    keeps working. A CI convenience must not be able to take the whole gate — and therefore the
    guest's entire network — down.

    **Deliberately not opened** (the deny log is where these decisions should come from):
    workflow `cancel` and `approve`, `POST /project/{slug}/pipeline` (trigger a *new* build, which
    is more than a retry), env vars, contexts, checkout keys, project settings, the deprecated
    v1.1 `…/{build}/retry`, `app.circleci.com` (the SPA; the workflow uuid is already readable
    from the GitHub check-run URL), and `circleci-tasks-prod.s3.us-east-1.amazonaws.com`, which
    shows up in the log serving snapshot diffs and is a separate question from this one.

    - Tests now 440 cases (+61): the read tier unchanged and uncredentialed; every allowed rerun
      shape; the org gate against votingworks/eventualbuddha/torvalds and all four malformed
      slugs; eleven body rejections including both `enable_ssh` shapes and a smuggled blob in
      `jobs`; every neighbouring API endpoint and every other method on the rerun path denied;
      and a two-way credential assertion — no PAT on circleci.com, no `Circle-Token` on GitHub or
      on the open hosts.
    - `secrets.env.template` gains an **optional** `CIRCLE_TOKEN` line (delete it to opt out),
      `just preflight` reports whether it's set, and there is a new **`just secrets`** recipe:
      `just deploy` syncs the addon and unit but *not* credentials, so a new or rotated secret
      needs `install` + a restart, which is what that recipe does.
    - **Deploy pending — `just secrets` then `just deploy` (both need sudo).** In that order:
      the addon denies reruns until the token is in `/etc/vmguard/secrets.env`.

44. **`cdimage.debian.org` and `http.us.debian.org` opened read-only (2026-08-18, on request).**
    Two more entries in the plain GET/HEAD tier, next to the Debian mirrors already there. No
    deny-log evidence for either — `grep debian requests.log` returns nothing for these hosts —
    so this is an ahead-of-first-use request, the same call as `meat.dev` (item 26), GitButler
    (item 35) and moshi's installer (item 42), and it costs nothing to revoke: delete the line.
    - **`cdimage.debian.org`** — installer and live ISO images, plus the `SHA256SUMS`/`SHA512SUMS`
      files and their `.sign` detached signatures that a verified download also fetches. Large
      GETs and nothing else. Integrity is the same story as the pool mirrors: the checksum file
      is signed, so the gate never has to vouch for the bytes it passes.
    - **`http.us.debian.org`** — the older US apt mirror redirector, still what a stock
      `sources.list` can name. `deb.debian.org`, the modern CDN, has been listed since the
      initial import; this is the other name for the same job.

    Two things worth recording rather than re-deriving:
    - **Plain HTTP needs no extra rule.** `http.us.debian.org` is reached over port 80, and no
      rule in this file has ever matched on port or scheme — a host entry applies to every port,
      which is the same fact the `OPEN_HOSTS` port note records. apt's own gpg signatures are
      what provide integrity, exactly as for the https mirrors, so unencrypted transport changes
      nothing about what this gate is protecting.
    - ~~**Neither needs a second host entry.** Both reach their actual mirrors through DNS, not an
      HTTP redirect, so the `Host` header stays put.~~ **Half of this was wrong — see item 45.**
      It holds for `http.us.debian.org` (verified: 200 direct on `Release`, `InRelease` and a pool
      listing). It is false for `cdimage.debian.org`, which 302s every ISO onto a separate mirror
      host, exactly like `cdn.playwright.dev` (item 31) and `astral.sh` (item 37). The claim was
      never checked against the deny log — it was checked against `~/.local/state/vmguard/`, the
      addon's *default* path, while the deployed unit writes `/var/lib/vmguard/requests.log`. The
      empty grep read as "no evidence" when it was really "wrong file". **Grep
      `/var/lib/vmguard/requests.log`.**

    Still exact hosts, as everywhere in this tier: `ftp.us.debian.org`, `http.de.debian.org`,
    `cdimage.debian.net` and bare `debian.org` are all denied, and tests pin each of those so the
    "not a suffix match" property is recorded and not just believed.
    - Tests: both hosts' read shapes (ISO, live image, checksums, `.sign`, HEAD, and apt's
      `InRelease`/`Packages.xz`/pool `.deb`), POST and PUT denied on both, no credentials
      injected on either, and the four neighbouring-host denies above.
    - **Deploy pending — `just deploy` (needs sudo).** No secrets change, so `just secrets` is
      not needed this time; until the addon is synced both hosts still 403.

45. **The `cdimage.debian.org` ISO redirect chain — nine more read-only hosts (2026-08-18).**
    Item 44 opened `cdimage.debian.org` and an ISO download still 403'd, on
    `laotzu.ftp.acc.umu.se`. Item 44's "no HTTP redirect" claim was wrong (corrected above); the
    chain was then traced with `curl` and against the real deny log rather than assumed.

    **What actually happens.** `cdimage.debian.org` serves the *small* files itself — `SHA256SUMS`,
    `SHA512SUMS`, `.sign` — and 302s every actual ISO onto a mirror backend. That split is why
    item 44 looked like it worked: the checksum fetch at 16:54 succeeded in shape, and only the
    image fetch at 17:19 revealed the redirect. `get.debian.org` is the same site under a second
    name (both are CNAMEs to `mirror.accum.se`) and redirects the same way on an `/images/` path.

    **The pool is bounded, and not by guesswork.** The backends are all one operator — ACC Umeå,
    Debian's primary cdimage host, everything in `194.71.11.0/24`. A single TLS cert
    (`CN=mirror.accum.se`) carries every backend name *plus* both front doors, which is the
    operator's own statement of what it serves, so the list is closed by the cert rather than
    discovered one 403 at a time. That is the difference between this and the doc sites of item 31,
    which are whack-a-mole by nature. All nine are now open, read-only:
    `get.debian.org`, `ftp.acc.umu.se`, and `laotzu` / `gemmei` / `chuangtzu` / `saimei` /
    `hammurabi` / `napoleon` / `tutankhamon`, each `.ftp.acc.umu.se`.

    Two observed properties worth recording, because listing fewer hosts would fail *intermittently*
    — the worst way for this gate to fail:
    - **They rotate per FILE, not per request.** The same ISO redirects to the same backend every
      time (12 probes of the netinst → `laotzu` 12/12), but a *different* ISO goes elsewhere
      (DVD-1 → `gemmei` 8/8). So "it worked for the netinst" predicts nothing about the DVD.
    - **They are not layered into fronts and backends.** `laotzu`/`gemmei`/`chuangtzu` answer 200,
      while `ftp.acc.umu.se`, `saimei`, `hammurabi`, `napoleon` and `tutankhamon` 302 *again* into
      the pool. A download can therefore pass through any of them.

    **Deliberately NOT opened**, though they sit in the deny log beside these:
    - `mirrors.kernel.org` and `mirror.us.leaseweb.net` — these are **not in the redirect chain**.
      The 16:55 cluster is Debian's published mirror *list* being tried by hand after `cdimage`
      403'd. Opening them means opening arbitrary third-party mirrors on no evidence anything
      needs them; the chain above is what the tooling actually follows.
    - `cloud.debian.org` — on the *same* ACC cert and denied at 16:55:55, but it serves the qcow2
      cloud images, a different artifact and a separate ask. Pinned as denied by a test so "it was
      on the cert" never becomes the reason it quietly rode along. Say the word if that image is
      wanted; it is a one-line change.
    - `votingworks-apt-snapshots.s3.us-west-2.amazonaws.com`, denied at 16:56:54 in the same
      session — unrelated to Debian upstream, and an S3 bucket rather than a mirror, so it is its
      own decision. Not opened.
    - Tests now 479 cases (+40 across items 44 and 45): every backend allowed for GET/HEAD
      including the `/mirror/`-prefixed path shape from the log, POST/PUT denied on each, no
      credentials injected, and explicit denies pinning `mirrors.kernel.org`,
      `mirror.us.leaseweb.net`, `cloud.debian.org`, the `.ftp.ac2.se` alias names on the same
      cert, `mirror.accum.se`, bare `acc.umu.se`, and an unlisted ACC sibling (`caesar`).
    - **Deploy pending — `just deploy` (needs sudo)**, still the only step; nothing here touches
      secrets.

## Running it: `Justfile`

A `Justfile` wraps the install/setup/ops commands (run `just` from this dir to list them;
needs `just`, already at `~/.cargo/bin/just`). Setup order: `preflight` → `net-up` →
fill `secrets.env` → `install` (sudo) → `firewall-open` (sudo) → `guest-setup` → `move-nic`.
Day-to-day: `just deploy` (tests, then copies the addon **and the systemd unit** to /opt +
/etc, daemon-reloads and restarts), `just secrets` (pushes `secrets.env` to /etc and restarts —
`deploy` does *not* sync credentials, see item 43), `just denies`, `just gql-denies`,
`just writes`, `just creds`, `just log`, `just status`, `just backout`. Recipes that need
root call `sudo` (interactive prompt); guest recipes go over `ssh vx`. Addon regression
tests live in `tests/test_filter.py` (`just test`, offline — stubs mitmproxy, mocks the org
resolver); creds helper in `scripts/check-creds.py`.

## What has been DONE (safe / reversible, no root needed)

- Created this staging area + captured initial state (`initial-state/`).
- Built `venv/` and installed **mitmproxy 12.2.3** (Python 3.14.3). Note: builds & runs
  fine on Python 3.14 — no wheel issues.
- Wrote & **live-tested** `github_filter.py` under mitmproxy 12 (see `artifacts/`):
  - deny: example.com → 403 "host not on allowlist"; github non-git path → 403;
    write to non-allowed org (torvalds) → 403 "…not in allowed orgs". JSON deny-log written.
  - allow: read advert to any repo is **not** denied (passed upstream).
  - **`--ignore-hosts` tunnelling verified**: a tunnelled host presents its REAL server
    cert (no MITM bump) and bypasses the addon, while non-tunnelled hosts are still
    bumped + 403'd. This is the mechanism the guest uses to reach api.anthropic.com.
- Generated the MITM **CA** → `mitmproxy-conf/mitmproxy-ca-cert.pem` (this is the file the
  guest must trust).
- **Defined + started + autostarted the isolated `vmguard` network** (192.168.124.1/24, no
  `<forward>` ⇒ fail-closed). Verified `virbr-guard` has `192.168.124.1/24`. `default` and
  `vxsuite` are still exactly as they were — nothing is routed through vmguard until a VM
  attaches to it.

## What is NOT yet done — needs YOU (blocked on secrets / root / disruption / guest)

1. **GitHub PAT (required, host-side).** I won't invent it. Fill
   `artifacts/secrets.env.template` → save as `secrets.env` here. Scope it tightly (read
   reach = what the VM can clone; write reach = VotingWorks / eventualbuddha repos you push
   to). One of the two host secrets — the other is the optional `CIRCLE_TOKEN` (item 43),
   which must be a *personal* CircleCI token because v2 rejects project-scoped ones.
2. **Subscription token (required, guest-side — design B).** On a machine with a browser
   (your laptop/host, NOT the isolated guest) run `claude setup-token` (needs Pro/Max) to
   mint a 1-year `CLAUDE_CODE_OAUTH_TOKEN`. It gets placed in the guest by `guest-setup.sh`.
3. **Privileged host install (needs sudo — sudo requires a password here, so I can't run it).**
   Review then run:  `! sudo bash ~/Desktop/vmguard-staging/install-host.sh`
   Creates the `vmguard` user, `/opt/vmguard` (fresh venv + addon), `/var/lib/vmguard`
   (pinned CA), `/etc/vmguard/secrets.env`, and the single `vmguard-github` service.
4. **Move the VM onto the isolated net (DISRUPTIVE — cuts vxsuite's internet, cold-reboots it).**
   Only after step 3 is up.  `bash ~/Desktop/vmguard-staging/move-vm-nic.sh`
5. **Guest side (needs access to the guest; has passwordless sudo).** Copy
   `mitmproxy-conf/mitmproxy-ca-cert.pem` in out-of-band, then run `guest-setup.sh` (trusts
   CA, sets HTTPS_PROXY, installs the subscription token). Also `/login` or rely on the token.
6. **Verify:** clone works; push to non-allowed org → 403; `curl https://example.com` fails;
   `claude -p 'hi'` works via subscription. Watch `/var/lib/vmguard/requests.log` and widen
   `--ignore-hosts` if Claude Code turns out to need hosts beyond api.anthropic.com.

## Files in this staging area

- `artifacts/vmguard.xml` — isolated network (already applied).
- `artifacts/egress_filter.py` — the one addon: the whole egress policy (GitHub gates + PAT
  inject, the CircleCI rerun gate + token inject, third-party read-only hosts, deny-all
  fallback). Was `github_filter.py` until item 27.
- `artifacts/vmguard-github.service` — the one systemd unit (regular proxy on 192.168.124.1:8080,
  with `--ignore-hosts` tunnelling api.anthropic.com).
- `artifacts/secrets.env.template` — fill in GH_PAT (and optionally CIRCLE_TOKEN) → `secrets.env`.
- `mitmproxy-conf/` — generated CA (guest trusts `mitmproxy-ca-cert.pem`).
- `install-host.sh` (sudo), `move-vm-nic.sh` (virsh, disruptive), `guest-setup.sh` (in guest).
- `backout.sh` — undo everything, restore initial state.
- `venv/` — local shakeout venv (the installer builds a fresh one in /opt; this one stays here).

## Back-out summary

`bash ~/Desktop/vmguard-staging/backout.sh` (sudo parts prompt) reverses, in order:
services → VM NIC back to `default` → remove `vmguard` net → remove host files/user →
prints guest cleanup commands. The only change made so far that it touches is the `vmguard`
network (steps 1/2/4 are no-ops until you run the installer/cutover). To undo *only* the
network right now:  `virsh net-destroy vmguard && virsh net-undefine vmguard`.
