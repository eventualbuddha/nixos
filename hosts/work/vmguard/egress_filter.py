# egress_filter.py — VMGuard's egress gate (mitmproxy addon).
#
# The guest sits on an isolated libvirt net with no route out; this addon is the ONE place that
# decides what leaves. It started life as `github_filter.py` when GitHub was the only allowed
# destination, and kept that name long after it had grown package registries, OS mirrors, CI and
# toolchain hosts — hence the rename (see NOTES.md item 27).
#
# The policy, in one paragraph: reads flow, writes are pinned to specific orgs. GitHub gets a
# host-side PAT injected so the guest never holds a credential, and every write is logged as an
# audit trail. CircleCI is the same idea at a much smaller scale — one credentialed endpoint,
# "rerun this workflow", org-checked host-side (section 3a). Every other non-GitHub host is
# credential-free and read-only, apart from a short list of exact-path POST exceptions
# (LAUNCHPAD_PATHS, READ_ONLY_POST_PATHS) whose bodies leave the guest uninspected — each is
# commented where it is defined. Anything not named here is denied and logged.
# api.anthropic.com / platform.claude.com never reach this file at all — the systemd unit
# tunnels them with --ignore-hosts, so they're never TLS-bumped.
#
# ONE EXCEPTION to the above, added deliberately: OPEN_HOSTS take any method with any body and
# are therefore an unrestricted way OUT. See that definition before adding to it.
#
# Layout:
#   1. plumbing          — logging + deny helper, shared by every rule
#   2. GitHub policy     — orgs, PAT injection, REST/GraphQL write gates, git smart-HTTP
#   3. non-GitHub policy — read-only host allowlist + narrowly scoped POST exceptions
#   3a. CircleCI policy  — uncredentialed reads + the one credentialed write (workflow rerun)
#   4. handlers/dispatch — one handler per host family, plus the catch-all deny
#
# Two rules for editing this file: fail closed on anything unrecognized, and widen from evidence
# in the deny log (README.md "Operating it" has the queries; ./gql-denies.py names a denied
# GraphQL op) rather than from a guess. Every rule below has a NOTES.md item explaining what
# forced it. Tests: tests/test_filter.py, offline; the README has the nix-shell invocation,
# since this host has no system python.
import os, re, json, base64, time, pathlib, logging, urllib.request
from mitmproxy import http

# mitmproxy 12 removed ctx.log; use the stdlib logging module instead.
log = logging.getLogger("vmguard")

# Non-mutating HTTP methods. Used as the read/write line by every rule in the file, GitHub or
# not, so "read" means the same thing everywhere.
API_READ_METHODS = {"GET", "HEAD"}

# ---- 1. plumbing -----------------------------------------------------------------------

DENY_LOG = pathlib.Path(os.environ.get(
    "VMGUARD_DENYLOG", os.path.expanduser("~/.local/state/vmguard/requests.log")))
DENY_LOG.parent.mkdir(parents=True, exist_ok=True)

def _log(kind, flow, **extra):
    """Append one JSON record per request. Opens and closes the file every time, which is what
    lets logrotate rename-and-recreate without a service reload (NOTES 21)."""
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "kind": kind,
           "host": flow.request.pretty_host, "method": flow.request.method,
           "path": flow.request.path, **extra}
    line = json.dumps(rec)
    with DENY_LOG.open("a") as f:
        f.write(line + "\n")
    (log.warning if kind == "DENY" else log.info)(line)

def _deny(flow, reason, **extra):
    _log("DENY", flow, reason=reason, **extra)
    flow.response = http.Response.make(403, (reason + "\n").encode(),
                                       {"Content-Type": "text/plain"})

# ---- 2. GitHub policy ------------------------------------------------------------------

WRITE_ORGS = {"votingworks", "eventualbuddha"}      # compared lower-cased
PAT  = os.environ["GH_PAT"]                          # host-side only
AUTH = "Basic " + base64.b64encode(f"x-access-token:{PAT}".encode()).decode()

# api.github.com: allow non-mutating REST methods (GET/HEAD) freely, and allow GraphQL
# reads (POST /graphql with no mutation). GraphQL MUTATIONS are allowed only when both:
#   (1) every top-level mutation field is in MUTATION_ALLOW (PR/issue lifecycle only), and
#   (2) every node the mutation touches resolves to an org in WRITE_ORGS — whether that node id
#       arrived in `variables` or inline in the document. Inline ones went unchecked until
#       NOTES 39; read that item before touching the collection logic.
# Everything else (createRepository, createGist, deleteRepository, org/user settings, PR/
# issue mutations in other orgs, ...) stays denied — the write-out/exfil channel.
#
# GraphQL mutation operations we permit (lower-cased, matched against the top-level selection
# field name). Deliberately PR/issue-scoped: no deleteRepository, no org/repo settings, no ref
# deletion (the one destructive exception is the narrow REST branch-cleanup rule below).
# Widen from the deny log as concrete needs appear — ./gql-denies.py names the op.
MUTATION_ALLOW = {
    "createpullrequest", "updatepullrequest", "closepullrequest", "reopenpullrequest",
    "markpullrequestreadyforreview", "convertpullrequesttodraft",
    "mergepullrequest",                                    # gh pr merge
    # Two more shapes of the SAME capability, seen on 2026-08-10 when one merge attempt fell
    # back through all four of its transports in eleven minutes (NOTES 31). Async returns
    # before the merge completes; InStack merges a whole stack in one call. The org gate is
    # unchanged and does the same work: InStack's blast radius is several PRs instead of one,
    # but EVERY id it names must still resolve into WRITE_ORGS or the whole call is denied.
    "mergepullrequestasync", "mergepullrequestsinstack",
    "enablepullrequestautomerge", "disablepullrequestautomerge",  # gh pr merge --auto / --disable-auto
    # Reviewer requests come in two shapes. gh actually sends the *ByLogin form (verified from
    # `gh pr edit --add-reviewer` debug output): reviewers are userLogins/botLogins/teamSlugs
    # strings, so the only node id in play is pullRequestId — which is exactly the target the
    # org gate needs. The node-id form is allowed too, for other clients / `gh api graphql`.
    "requestreviewsbylogin", "requestreviews",
    "createissue", "updateissue", "closeissue", "reopenissue",
    "addcomment", "updateissuecomment",
    "addpullrequestreview",   # gh pr review: PR-scoped body text, same shape as addComment
    # Mark a review conversation resolved (NOTES 38). Carries no content at all — just a thread
    # id and a flag — so it is the narrowest write in this set. Requires the matching
    # PullRequestReviewThread fragment in _RESOLVE_Q below; without it the op is allowlisted here
    # and then dies at the org check, which is a confusing way to be denied.
    # `unresolveReviewThread` is deliberately NOT here: nothing has asked for it, and the deny
    # log is where that decision should come from (same call as DELETE requested_reviewers).
    "resolvereviewthread",
    # Reply to a specific review thread (NOTES 41), the other half of the review-comment loop:
    # address a comment -> reply "done in <sha>" -> resolve. Body text, same shape as addComment.
    # Its input can ALSO carry pullRequestReviewId (a PullRequestReview, when the reply belongs to
    # a pending review), which is why _RESOLVE_Q gained that fragment alongside this line.
    # The REST equivalent (POST /pulls/{n}/comments/{id}/replies) is NOT open — no rule matches
    # it, so it 403s; a test pins that. Add a path regex if a client ever needs that transport.
    "addpullrequestreviewthreadreply",
    "addlabelstolabelable", "removelabelsfromlabelable",
}

# Node types that name a PRINCIPAL (*who*) rather than a location (*where*). requestReviews
# carries reviewer User/Bot/Team ids alongside the PullRequest it targets, and createIssue
# carries assigneeIds — none of which constrain where the write lands, and none of which
# resolve to an owning org (a reviewer's login is a person, not an org), so org-checking them
# would deny every legitimate call. They are therefore recognized and skipped instead.
#
# This does NOT loosen the gate: the mutation's target (Repository/PullRequest/Issue/...) is
# still resolved and still must be in WRITE_ORGS, a typename outside both sets still fails
# closed, and a mutation carrying ONLY principal ids resolves to no owner at all — which the
# caller treats as a deny. Nor is a reviewer request an exfil channel: GitHub only accepts
# review requests for users who already have access to the repo, so a compromised guest can't
# use it to show a private PR to an outside account.
PRINCIPAL_TYPES = {"User", "Bot", "Team", "Mannequin"}

# GitHub stacked pull requests (REST, not GraphQL). The write endpoints are:
#   POST /repos/{owner}/{repo}/stacks                        create a stack from PR numbers
#   POST /repos/{owner}/{repo}/stacks/{n}/add                append PRs to a stack
#   POST /repos/{owner}/{repo}/stacks/{n}/unstack            drop unmerged PRs from a stack
# (the two GET shapes — list and get-by-number — already ride the API_READ_METHODS rule.)
#
# These are org-scoped the EASY way: unlike a GraphQL mutation, whose target hides behind an
# opaque node id, the owner/repo here sit in the URL path that GitHub itself routes on. So we
# read the org straight off the path and check WRITE_ORGS — no resolver round-trip needed.
# This is the same shape of gate as the git-push rule, and stays inside the existing write
# boundary: it only reorders/annotates PRs in repos the guest can already push to and open
# PRs against. It creates no repos, deletes no refs, and touches no settings.
#
# Matched against the RAW path with a strict unreserved charset, deliberately: mitmproxy
# forwards the raw path upstream but `path_components` percent-DECODES, so deciding on the
# decoded form would open a parser differential ('vxsuite%2f..%2f..%2ftorvalds%2flinux'
# decodes to one component containing slashes). A regex over the raw path admits no '%' at
# all, so what we authorize is byte-for-byte what GitHub receives.
STACK_WRITE_RE = re.compile(
    r"^/repos/(?P<owner>[A-Za-z0-9._-]+)/(?P<repo>[A-Za-z0-9._-]+)"
    r"/stacks(?:/[0-9]+/(?:add|unstack))?$")

# Reviewer requests (REST): POST /repos/{owner}/{repo}/pulls/{n}/requested_reviewers.
# This is the `gh api` / Octokit / curl route to "add a reviewer"; gh's own `pr edit
# --add-reviewer` takes the GraphQL requestReviewsByLogin mutation instead, so both are opened.
#
# Org-scoped off the RAW path exactly like STACK_WRITE_RE — unreserved charset only, so no '%'
# can smuggle a different owner past the check (see that comment for the parser differential).
# Reviewer logins ride in the JSON body, which needs no inspection: they only matter if GitHub
# accepts them, and it only accepts users who already have access to the repo.
#
# DELETE on the same path (un-request a reviewer) is deliberately NOT opened — nothing has
# needed it, and the deny log is where that decision should come from.
REVIEWERS_WRITE_RE = re.compile(
    r"^/repos/(?P<owner>[A-Za-z0-9._-]+)/(?P<repo>[A-Za-z0-9._-]+)"
    r"/pulls/[0-9]+/requested_reviewers$")

# Update a pull request (REST): PATCH /repos/{owner}/{repo}/pulls/{n}. Restacking retargets each
# PR's base branch as the stack is reordered or merged, which is this endpoint.
#
# This grants NO capability the guest doesn't already have: `updatePullRequest` has been an
# allowed GraphQL mutation since NOTES 14, and REST PATCH's fields (title, body, state, base,
# maintainer_can_modify) are a strict SUBSET of that mutation's input — which also carries
# assignees, labels, milestone and projects. The deny log shows both sides of that on the same
# day: PATCH denied at 17:46:59, updatePullRequest allowed at 17:51:48. So this is transport
# parity for an existing permission, not a wider write boundary.
#
# Org-scoped off the RAW path with the same unreserved-only charset as the rules above, and
# anchored at the PR number so no subpath rides along: PATCH on /pulls/{n}/merge, /reviews,
# /requested_reviewers etc. does not match and stays denied.
PR_UPDATE_RE = re.compile(
    r"^/repos/(?P<owner>[A-Za-z0-9._-]+)/(?P<repo>[A-Za-z0-9._-]+)"
    r"/pulls/[0-9]+$")

# Merge a pull request (REST): PUT /repos/{owner}/{repo}/pulls/{n}/merge, and the /merge-async
# variant that returns before the merge finishes.
#
# Like PR_UPDATE_RE this is transport parity, not a new permission: `mergePullRequest` has been
# an allowed GraphQL mutation since NOTES 14, and these endpoints do the same thing to the same
# PR. The deny log shows both routes on the same day (NOTES 31) — one merge attempt fell back
# GraphQL -> REST -> async as each transport 403'd.
#
# Org-scoped off the RAW path with the same unreserved-only charset as the rules above, and
# anchored at the merge segment so nothing else on the PR rides along: PUT on /pulls/{n} itself
# stays denied (only PATCH is open there), as does every other subpath.
MERGE_PR_RE = re.compile(
    r"^/repos/(?P<owner>[A-Za-z0-9._-]+)/(?P<repo>[A-Za-z0-9._-]+)"
    r"/pulls/[0-9]+/merge(?:-async)?$")

# Post-merge branch cleanup: DELETE /repos/{owner}/{repo}/git/refs/heads/{branch}
# (`gh pr merge --delete-branch`, and the same cleanup after each merge in a stack).
#
# This IS destructive, unlike the stacks endpoints — but narrowly and recoverably so: it drops
# a branch tip in a WRITE_ORGS repo the guest can already force-push, the commits survive in
# the merged PR and the reflog, and `heads/` in the pattern means tags (release markers) and
# every other ref namespace stay untouchable. No other REST DELETE is opened.
#
# Unlike the stacks rule, this path cannot ban '%' outright: branch names contain slashes and
# gh percent-encodes them (observed: 'brian%2Fesm-migration-spec'). So %2F is the ONE escape
# admitted, and the decoded ref is then segment-checked — otherwise a tail like '..%2F..%2Fx'
# could walk back up the path and retarget a repo outside WRITE_ORGS if GitHub normalizes
# before routing. Git already forbids '.'/'..' ref components, so rejecting them costs nothing.
DELETE_REF_RE = re.compile(
    r"^/repos/(?P<owner>[A-Za-z0-9._-]+)/(?P<repo>[A-Za-z0-9._-]+)"
    r"/git/refs/heads/(?P<ref>(?:[A-Za-z0-9._-]|%2[Ff]|/)+)$")

def _ref_is_plain(raw_ref):
    """True if the (possibly %2F-encoded) branch decodes to conventional, traversal-free
    segments. The regex charset already admits no escape but %2F, so this is the only decode."""
    segs = raw_ref.replace("%2F", "/").replace("%2f", "/").split("/")
    return all(s and s not in (".", "..") for s in segs)

def parse_git(flow):
    """Classify a github.com path as git smart-HTTP read / write / not-git."""
    pc = list(flow.request.path_components)
    if len(pc) < 3:
        return None
    owner, repo = pc[0], pc[1]
    if repo.endswith(".git"):
        repo = repo[:-4]
    tail = "/".join(pc[2:])
    if tail == "info/refs":
        op = {"git-upload-pack": "read",
              "git-receive-pack": "write"}.get(flow.request.query.get("service", ""))
    elif tail == "git-upload-pack":
        op = "read"
    elif tail == "git-receive-pack":
        op = "write"
    else:
        op = None
    return owner, repo, op

# ---- 2a. GraphQL parsing ---------------------------------------------------------------
# We must decide read-vs-mutation and, for mutations, the exact top-level operation fields.
# A naive "does the text contain 'mutation'?" is unsafe: an attacker can hide a second
# top-level mutation field after an allowed one, or bury braces/keywords inside string
# literals. So _scan_mutation_fields is a small string- and bracket-aware scanner.

_IDENT = re.compile(r"[A-Za-z_]\w*")
# 'mutation' as an OPERATION keyword: followed by a name, variable defs '(', or '{'.
_MUT_KW = re.compile(r"\bmutation\b\s*[\w${(]")

def _scan_mutation_fields(doc):
    """String/bracket-aware scan of a GraphQL document.
    Returns (has_mutation, fields): fields = top-level selection field names of every
    mutation operation. Returns (None, None) on any structural surprise (→ fail closed)."""
    i, n = 0, len(doc)
    depth = paren = 0
    cur_is_mutation = False        # current depth-0 operation body is a mutation?
    pending_op = None              # operation keyword just seen at depth 0
    has_mutation = False
    fields = []
    try:
        while i < n:
            c = doc[i]
            if c == '"':                                   # skip string / block string
                if doc[i:i+3] == '"""':
                    end = doc.find('"""', i + 3)
                    if end < 0:
                        return None, None
                    i = end + 3
                    continue
                i += 1
                while i < n and doc[i] != '"':
                    if doc[i] == '\\':
                        i += 1
                    i += 1
                i += 1
                continue
            if c == '#':                                   # line comment
                nl = doc.find('\n', i)
                i = n if nl < 0 else nl
                continue
            if c == '(':
                paren += 1; i += 1; continue
            if c == ')':
                paren -= 1; i += 1; continue
            if c == '{':
                depth += 1
                if depth == 1:
                    cur_is_mutation = (pending_op == 'mutation')
                    pending_op = None
                i += 1; continue
            if c == '}':
                depth -= 1; i += 1; continue
            if c.isalpha() or c == '_':
                m = _IDENT.match(doc, i)
                word, j = m.group(0), m.end()
                if depth == 0:
                    if word in ('query', 'mutation', 'subscription'):
                        pending_op = word
                elif depth == 1 and cur_is_mutation and paren == 0:
                    k = j
                    while k < n and doc[k] in ' \t\r\n':
                        k += 1
                    if k < n and doc[k] == ':':            # alias: real field follows
                        k += 1
                        while k < n and doc[k] in ' \t\r\n':
                            k += 1
                        m2 = _IDENT.match(doc, k)
                        if not m2:
                            return None, None
                        fields.append(m2.group(0)); j = m2.end()
                    else:
                        fields.append(word)
                    has_mutation = True
                i = j; continue
            i += 1
        if depth != 0 or paren != 0:
            return None, None
        return has_mutation, fields
    except Exception:
        return None, None

# Variable keys that end in 'id' but are NOT GitHub node IDs. These must be excluded, or the
# resolver ships them to nodes(ids:), GitHub returns null for the bogus id, and the whole
# mutation fails closed even though its op and org are fine:
#   clientMutationId — a caller-chosen echo string, present in most GitHub mutation inputs
#   *Oid             — a git object SHA (mergePullRequest's expectedHeadOid, which gh sets to
#                      guard against a racing push; also oid/afterOid/beforeOid elsewhere)
# Neither can name a write target, so skipping them loses no gate: every genuine *Id / *Ids
# is still collected and still org-checked. Node-id variables always end in 'Id'/'Ids', so
# excluding the 'oid' suffix cannot swallow one.
def _is_node_id_key(kl):
    return (kl == "id" or kl.endswith("id")) and kl != "clientmutationid" and not kl.endswith("oid")

# Plural counterpart, for keys like `labelIds` / `assigneeIds`. _collect_node_ids handles these in
# a separate branch (a list under a key ending 'ids'), so a scanner that only asked
# _is_node_id_key would silently miss every id in a list — 'labelids' ends in 's', not 'id'.
# 'oids' is excluded for the same reason 'oid' is: a list of git SHAs names no write target.
def _is_node_id_list_key(kl):
    return kl.endswith("ids") and not kl.endswith("oids")

# GraphQL lets a mutation write its arguments INLINE in the document instead of passing them in
# `variables`, and _collect_node_ids below only walks `variables`. For a document like
#   mutation{resolveReviewThread(input:{threadId:"PRRT_kwABC"}){thread{isResolved}}}
# it therefore finds NOTHING, which has two consequences (NOTES 39):
#   1. the call is denied even when legitimate — no ids means no resolvable target org, which is
#      how resolveReviewThread kept failing after it was added to MUTATION_ALLOW. This is the
#      shape `gh api graphql -f query=...` and other unparameterized clients send.
#   2. the serious one: a mutation could put a BENIGN id in `variables` — resolving cleanly into
#      WRITE_ORGS — while its real target rode inline and was never org-checked at all. The gate
#      would pass on the decoy. Collecting inline ids is what makes the promise at the top of the
#      GitHub section ("every node the mutation touches resolves to an org in WRITE_ORGS") true.
#
# Same key rule as the variables walk (_is_node_id_key), deliberately: only strings under a key
# named like an id count, so a comment body that happens to quote a node id is not mistaken for a
# target (which would deny the comment). String-aware for the same reason _scan_mutation_fields
# is — a quote inside a string must not end the literal, and an id-looking word inside a string
# is not a key.
def _scan_inline_node_ids(doc):
    """Collect node-ID string literals written inline in a GraphQL document, i.e. `someId: "..."`
    or `someIds: ["...", "..."]` at any depth. Returns (ids, ok); ok is False on a structural
    surprise, which the caller turns into a deny."""
    ids = set()
    i, n = 0, len(doc)
    key = None                      # most recent IDENT that was followed by ':'
    try:
        while i < n:
            c = doc[i]
            if c == '"':
                if doc[i:i+3] == '"""':                 # block string
                    end = doc.find('"""', i + 3)
                    if end < 0:
                        return ids, False
                    val, j = doc[i+3:end], end + 3
                else:
                    j, buf = i + 1, []
                    while j < n and doc[j] != '"':
                        if doc[j] == '\\':              # keep escapes out of the value
                            j += 1
                            if j >= n:
                                return ids, False
                        buf.append(doc[j])
                        j += 1
                    if j >= n:                          # unterminated literal
                        return ids, False
                    val, j = "".join(buf), j + 1
                # singular `someId: "..."` and every literal inside a plural `someIds: [...]`
                if key is not None and (_is_node_id_key(key) or _is_node_id_list_key(key)):
                    ids.add(val)
                i = j
                continue
            if c == '#':                                # line comment
                nl = doc.find('\n', i)
                i = n if nl < 0 else nl
                continue
            if c.isalpha() or c == '_':
                m = _IDENT.match(doc, i)
                word, j = m.group(0), m.end()
                k = j
                while k < n and doc[k] in ' \t\r\n':
                    k += 1
                if k < n and doc[k] == ':':             # `word:` — this names the value ahead
                    key = word.lower()
                i = j
                continue
            if c in '}]':               # value finished; the key stops applying to what follows
                key = None
            i += 1
        return ids, True
    except Exception:
        return ids, False

def _collect_node_ids(items):
    """Pull candidate GitHub node IDs out of the GraphQL variables — any string under a key
    named 'id' or ending in 'Id', plus lists under keys ending in 'Ids'. Keys that merely look
    like ids (see _is_node_id_key) are skipped."""
    ids = set()
    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                kl = k.lower()
                if isinstance(v, str) and _is_node_id_key(kl):
                    ids.add(v)
                elif isinstance(v, list) and kl.endswith("ids"):
                    ids.update(x for x in v if isinstance(x, str))
                else:
                    walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    for it in items:
        walk(it.get("variables") or {})
    return ids

# Resolve node IDs -> owning org login, via a direct (un-proxied) call from the host.
# We can't trust the guest to tell us the org, so we ask GitHub ourselves with the PAT.
_DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # never loop via proxy
# Every typename any allowed mutation can name as its TARGET must have a fragment here, or the
# node resolves to no owner and _resolve_owners fails closed — the op would be in MUTATION_ALLOW
# and still be denied, reported as "no resolvable target org". Adding a mutation whose input takes
# a new kind of node id therefore means adding a fragment too (NOTES 38 is the worked example).
_RESOLVE_Q = ("query($ids:[ID!]!){nodes(ids:$ids){__typename "
              "... on Repository{owner{login}} "
              "... on PullRequest{repository{owner{login}}} "
              "... on Issue{repository{owner{login}}} "
              "... on IssueComment{repository{owner{login}}} "
              "... on PullRequestReviewThread{repository{owner{login}}} "
              "... on PullRequestReview{repository{owner{login}}} "
              # Milestone and Discussion are reachable from mutations that were ALREADY allowed —
              # milestoneId on createIssue/updateIssue/updatePullRequest, and labelableId on
              # add/removeLabelsToLabelable, which accepts a Discussion. Both were latent item-38
              # bugs: setting a milestone would have been allowlisted and then denied as "no
              # resolvable target org". Found by auditing every allowed mutation's input against
              # this list (NOTES 41), not by waiting for the 403.
              "... on Milestone{repository{owner{login}}} "
              "... on Discussion{repository{owner{login}}} "
              "... on Label{repository{owner{login}}}}}")
# NOT here, deliberately: Project / ProjectV2 (projectIds on createIssue/updateIssue/
# updatePullRequest). Unlike everything above they have no `repository` — only `owner`, an
# interface resolving to an Organization or a User — so they are not repo-scoped and do not fit
# the `repository{owner{login}}` shape this resolver is built on. A project write therefore still
# fails closed. Opening it means deciding whether an org-level project counts as "in WRITE_ORGS",
# which is a policy question, not a missing fragment. Nothing has needed it (NOTES 41).

def _resolve_owners(ids):
    """Return the set of owner logins for the TARGET node IDs, or None on ANY failure /
    unresolved id / no target at all (fail closed). Principal nodes — reviewers, assignees —
    are skipped rather than resolved to an org; see PRINCIPAL_TYPES."""
    if not ids:
        return None
    payload = json.dumps({"query": _RESOLVE_Q, "variables": {"ids": sorted(ids)}}).encode()
    req = urllib.request.Request(
        "https://api.github.com/graphql", data=payload,
        headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json",
                 "User-Agent": "vmguard"})
    try:
        with _DIRECT.open(req, timeout=8) as r:
            data = json.loads(r.read())
    except Exception:
        return None
    nodes = (data.get("data") or {}).get("nodes")
    if not isinstance(nodes, list):
        return None
    owners = set()
    for node in nodes:
        if not node:                       # invalid/unknown id -> deny
            return None
        if node.get("__typename") in PRINCIPAL_TYPES:
            continue                       # a person/team, not a place -> nothing to org-check
        owner = node.get("owner") or (node.get("repository") or {}).get("owner")
        login = (owner or {}).get("login")
        if not login:                      # typename we don't understand -> deny
            return None
        owners.add(login)
    # empty set = the mutation named no target we could place in an org -> caller denies
    return owners

def graphql_decision(flow):
    """Classify a POST /graphql request. Returns (decision, detail):
    decision is 'read' | 'mutation-ok' | 'deny'; detail is a small dict of METADATA for the
    log — which ops were asked for, which orgs they resolved to, and which check failed.

    Deliberately never includes the request body: it carries PR/issue titles and comment text,
    and requests.log is a 30-day-retained audit trail. Op names and org logins are enough to
    tell what to widen, which is the whole point (before this, a deny said only 'op not allowed
    or org not permitted' and the op had to be guessed from timing — see NOTES 23)."""
    try:
        body = json.loads(flow.request.get_text() or "")
    except Exception:
        return "deny", {"why": "body is not JSON"}
    items = body if isinstance(body, list) else [body]
    saw_mutation = False
    all_fields = []
    for it in items:
        if not isinstance(it, dict):
            return "deny", {"why": "malformed batch item"}
        q = it.get("query", "")
        if not q:
            return "deny", {"why": "no query in body"}
        q_nostr = re.sub(r'"(?:[^"\\]|\\.)*"', '', q)      # strip strings for keyword check
        has_mut, fields = _scan_mutation_fields(q)
        if has_mut is None:
            return "deny", {"why": "unparseable graphql"}  # fail closed
        # belt & suspenders: 'mutation' keyword present but scanner saw none -> distrust
        if not has_mut and _MUT_KW.search(q_nostr):
            return "deny", {"why": "mutation keyword but no field parsed"}
        if has_mut:
            saw_mutation = True
            all_fields.extend(fields)
    if not saw_mutation:
        return "read", {}
    if not all_fields:
        return "deny", {"why": "mutation with no top-level field"}
    bad_ops = sorted(f for f in all_fields if f.lower() not in MUTATION_ALLOW)
    if bad_ops:
        return "deny", {"why": "op not in allowlist", "ops": sorted(all_fields),
                        "bad_ops": bad_ops}
    # Targets can arrive either in `variables` or inline in the document; both are collected, and
    # every one of them is org-checked below (NOTES 39).
    ids = _collect_node_ids(items)
    for it in items:
        inline, ok = _scan_inline_node_ids(it.get("query", "") or "")
        if not ok:
            return "deny", {"why": "unparseable graphql", "ops": sorted(all_fields)}
        ids |= inline
    owners = _resolve_owners(ids)
    if not owners:
        # resolver failed, an id was unknown, or the mutation named no org-placeable target.
        # n_ids separates those: 0 means nothing id-shaped was found in the call at all, >0 means
        # ids were found and the resolver rejected them. A count only — no body, per NOTES 23.
        return "deny", {"why": "no resolvable target org", "ops": sorted(all_fields),
                        "n_ids": len(ids)}
    bad_orgs = sorted(o for o in owners if o.lower() not in WRITE_ORGS)
    if bad_orgs:
        return "deny", {"why": "org not permitted", "ops": sorted(all_fields),
                        "orgs": sorted(owners), "bad_orgs": bad_orgs}
    return "mutation-ok", {"ops": sorted(all_fields), "orgs": sorted(owners)}

# ---- 3. non-GitHub policy --------------------------------------------------------------

# Third-party hosts allowed for reads only (GET/HEAD), no creds injected. Data-in only;
# writes stay denied. These are bumped (guest must trust the MITM CA); clients that don't
# use the system trust store (e.g. Node -> downloads.claude.ai) also need the CA wired in
# (NODE_EXTRA_CA_CERTS) or the bump fails.
#
# Entries are EXACT hosts, not suffixes: adding 'meat.dev' does not admit 'cdn.meat.dev'.
# Most of these were added from deny-log evidence; a few on request ahead of first use.
READ_ONLY_HOSTS = {"api.mason-registry.dev", "downloads.claude.ai", "herdr.dev",
                   "meat.dev",                                 # requested for an install (2026-08-04)
                   # githubusercontent CDNs that github.com release downloads 302 to:
                   "objects.githubusercontent.com", "release-assets.githubusercontent.com",
                   # raw file / gist content (read-only; many `curl | sh` installers fetch here):
                   "raw.githubusercontent.com", "gist.githubusercontent.com",
                   # language package registries (all GET-only; tarballs served from same hosts):
                   "registry.npmjs.org",                       # npm / pnpm / yarn
                   "pnpm.io",                                  # pnpm docs / self-install script
                   "nodejs.org",                               # pnpm manage-Node: /dist index + node tarballs
                   "dl.google.com",                            # Go toolchain tarballs (/go/go1.x.*.tar.gz)
                   "proxy.golang.org", "sum.golang.org",       # Go modules + the checksum database
                   "crates.io", "index.crates.io", "static.crates.io",      # cargo (sparse index + downloads)
                   "npm.jsr.io",                               # JSR's npm-compat registry
                   # PyPI, on request (NOTES 37). Both halves are needed: pypi.org serves the
                   # /simple index and the /pypi/*/json API, but every wheel/sdist it links to
                   # lives on files.pythonhosted.org, so the index host alone resolves a version
                   # and then 403s the download. Integrity is pip's own hashes, as with apt.
                   "pypi.org", "files.pythonhosted.org",
                   # uv/uvx, on request (NOTES 37). Same two-host shape for the same reason:
                   # astral.sh/uv/install.sh is a 302 to releases.astral.sh, so opening only the
                   # vanity host redirects the installer straight into a deny. releases.astral.sh
                   # is also the first of the two binary mirrors the script walks (the second is
                   # github.com/astral-sh/uv/releases, already open via the github.com read rule).
                   "astral.sh", "releases.astral.sh",
                   # OS package mirrors (apt over http/https; integrity via apt's own gpg sigs):
                   "deb.debian.org", "security.debian.org", "www.debian.org",
                   "snapshot.debian.org",                      # date-pinned pool + /mr/binary API
                   # Debian ISO images (NOTES 44, corrected and completed in NOTES 45): installer,
                   # live and archived images, plus the SHA*SUMS files and their .sign detached
                   # sigs. All plain GETs, with the same integrity story as the pool mirrors above
                   # — the checksum file is signed, so the gate never vouches for the bytes.
                   #
                   # TWO FRONT DOORS. cdimage.debian.org serves the small files (SHA*SUMS, .sign)
                   # itself, but 302s every actual ISO onto one of the backends below.
                   # get.debian.org is the same site under a second name — both are CNAMEs to
                   # mirror.accum.se — and redirects the same way, on a /images/ path.
                   "cdimage.debian.org", "get.debian.org",
                   #
                   # THE BACKENDS, i.e. where an ISO download actually lands. These are all ONE
                   # operator: ACC Umeå, Debian's primary cdimage host. That the list is closed is
                   # not a guess — a single TLS cert (CN=mirror.accum.se) carries every name below
                   # alongside both front doors, which is the operator's own statement of what it
                   # serves, so the set is bounded by the cert rather than discovered one 403 at a
                   # time (contrast the doc sites in NOTES 31, which are whack-a-mole by nature).
                   # They rotate per FILE, not per request — the same ISO redirects to the same
                   # backend every time, a different ISO to a different one — and they are not
                   # layered: laotzu/gemmei/chuangtzu answer 200, while ftp.acc.umu.se and the
                   # remaining three 302 again into the pool. So a download can land on any of
                   # them, and listing fewer would fail intermittently and confusingly.
                   "ftp.acc.umu.se",
                   "laotzu.ftp.acc.umu.se", "gemmei.ftp.acc.umu.se",
                   "chuangtzu.ftp.acc.umu.se", "saimei.ftp.acc.umu.se",
                   "hammurabi.ftp.acc.umu.se", "napoleon.ftp.acc.umu.se",
                   "tutankhamon.ftp.acc.umu.se",
                   #
                   # NOT opened, deliberately, though they sit in the deny log right next to these:
                   # mirrors.kernel.org and mirror.us.leaseweb.net are NOT in the redirect chain —
                   # they are entries from Debian's published mirror LIST, tried by hand after
                   # cdimage 403'd. Opening them means opening arbitrary third-party mirrors on no
                   # evidence that anything needs them. cloud.debian.org is also denied and is also
                   # on the ACC cert, but it serves the qcow2 cloud images: a different artifact
                   # and a separate ask (NOTES 45).
                   # The older US apt mirror redirector — still what a stock sources.list can name,
                   # alongside deb.debian.org (the modern CDN) already listed above. Reached over
                   # plain HTTP, which needs no extra rule: no rule in this file matches on port or
                   # scheme, and integrity is apt's own gpg signatures either way. Unlike cdimage
                   # above, this one really does answer 200 directly — verified on Release,
                   # InRelease and a pool listing — so it needs no companion entry.
                   "http.us.debian.org",
                   "apt.postgresql.org", "cli.github.com",     # extra apt repos on the guest
                   # CI. `circleci.com` itself is NOT in this tier any more — it has its own
                   # handler (section 3a) because one endpoint on it takes a credential. Its
                   # reads are unchanged: GET/HEAD, no creds, exactly as this tier would give.
                   "output.circle-artifacts.com",   # circleci build artifacts: task logs, snapshot diffs
                   "static.rust-lang.org",          # rustup channel manifests + toolchain downloads
                   # presigned election-package downloads for the design app (GET-only; the
                   # presigned URL carries its own AWS signature, which we neither add nor need):
                   "vxdesign-staging.s3.us-west-1.amazonaws.com",
                   "moonrepo.dev",                  # moon build tooling
                   "ghcr.io",
                   "pkg-containers.githubusercontent.com",
                   "www.schemastore.org",
                   "turbo.build",
                   # Turborepo's older domain, still what a turbo.json "$schema" can point at
                   # (seen: GET /schema.json). Same read as www.schemastore.org above (NOTES 40).
                   "turborepo.dev",
                   "nubjs.com",
                   "cafe.github.com",
                   "cdn.playwright.dev",
                   # cdn.playwright.dev 302s the actual browser bundles to here, so opening the
                   # CDN alone left every `playwright install` still 403ing on the payload:
                   "playwright.download.prss.microsoft.com",
                   # ...and the driver bundle (playwright-<ver>-linux.zip) comes from a different
                   # place again: an azureedge trio the client walks in order until one answers.
                   # All three 403'd in three seconds, so all three are listed (NOTES 34).
                   "playwright.azureedge.net", "playwright-akamai.azureedge.net",
                   "playwright-verizon.azureedge.net",
                   # OSV vulnerability database — reads here, plus one POST (see the dict below):
                   "api.osv.dev",
                   # Documentation / reference sites. No tool depends on these; they're what the
                   # agent reads while working, and each was a single GET that 403'd (NOTES 31).
                   # Opening them is whack-a-mole by nature — the next doc site will 403 too.
                   "docs.github.com", "bugs.debian.org", "tanstack.com", "lefthook.dev",
                   "typicode.github.io", "rust-lang.github.io", "pre-commit.com",
                   # GitButler's docs + blog, both 403'd on a single GET each once `but` was in
                   # (NOTES 36). Predicted in NOTES 35 and now evidence, per the item 31 rule.
                   "docs.gitbutler.com", "blog.gitbutler.com",

                   # Claude Code's release bucket. `claude install` and the native build's own
                   # self-update fetch their tarballs from here, which is what makes the
                   # bootstrap in the flake's home/core/claude-code.nix work — claude.ai itself
                   # is deliberately NOT listed, so the documented `curl claude.ai/install.sh`
                   # one-liner 403s here and the subcommand is used instead.
                   #
                   # This whole block was originally Google Antigravity's (install script, update
                   # manifest, Unleash flags, OAuth, userinfo, avatar CDN). Antigravity was
                   # removed on 2026-08-29 and those hosts went with it; storage.googleapis.com
                   # is the one entry that turned out to be load-bearing for something else.
                   "storage.googleapis.com",

                   # GitButler CLI (`but`) install, requested ahead of first use (NOTES 35). The
                   # whole `curl -fsSL https://gitbutler.com/install.sh | sh` chain is five GETs
                   # across these three hosts and nothing else: install.sh -> the installer's
                   # metadata JSON on app.gitbutler.com -> the but-installer binary on
                   # releases.gitbutler.com -> app.gitbutler.com/releases (which carries the
                   # minisign signature inline, so there is no separate .sig fetch) -> the `but`
                   # binary itself. GET-only suits it exactly; the installer's own two redirect
                   # guards refuse anything that leaves app./releases.gitbutler.com, so the
                   # download cannot walk off these hosts even if the metadata says otherwise.
                   "gitbutler.com", "app.gitbutler.com", "releases.gitbutler.com",

                   # moshi-hook INSTALL only, requested ahead of first use (NOTES 42). The whole
                   # `curl -fsSL https://getmoshi.app/install.sh | sh` chain is four GETs across
                   # these two hosts: install.sh -> cdn /hook/latest/version.txt -> the tarball
                   # -> checksums.txt (which the installer verifies with sha256sum). GET-only fits
                   # it exactly, and the tarball is the only thing that lands on disk.
                   #
                   # NOTE: this covers installing the binary, NOT running it. `moshi serve` talks to
                   # api.getmoshi.app, which is in OPEN_HOSTS — deliberately, and NOT in this tier,
                   # because a read-only entry could not have constrained it anyway. See the
                   # comment on that entry and NOTES 42.
                   "getmoshi.app", "cdn.getmoshi.app",

                   # Nix, on request (NOTES 46). nixos.org 403'd in the deny log; the rest of
                   # the chain was walked ahead of its own 403s rather than one at a time. The
                   # whole flow — installing with
                   # `curl … https://nixos.org/nix/install | sh -s -- --daemon`, then
                   # pulling and installing packages — is these four hosts and nothing else, all
                   # GET/HEAD, so this tier fits it exactly. Nix never POSTs in the fetch path;
                   # the one write it knows how to do is `nix copy --to`, pushing store paths OUT
                   # to a cache, and a read-only entry is precisely what refuses it.
                   #
                   #   nixos.org           the install entry point (/nix/install) and nothing
                   #                       else — it 302s straight to releases.nixos.org.
                   #   releases.nixos.org  where everything downloadable actually lives: the
                   #                       install script the redirect lands on, the ~27 MB
                   #                       binary tarball it then fetches, and every channel
                   #                       snapshot's nixexprs.tar.xz.
                   #   channels.nixos.org  the redirector `nix-channel --update` walks
                   #                       (/nixpkgs-unstable -> a releases.nixos.org snapshot).
                   #                       The installer writes this exact URL into
                   #                       ~/.nix-channels and updates it as its last step, so an
                   #                       install fails at the finish line without it. Also
                   #                       /flake-registry.json, which bare flake refs resolve
                   #                       through.
                   #   cache.nixos.org     the binary cache: /nix-cache-info, <hash>.narinfo and
                   #                       /nar/*.nar.zst. This is the "installing packages"
                   #                       half. It serves directly (Fastly over S3, no
                   #                       redirect), and nix HEADs as well as GETs here.
                   #
                   # Integrity is nix's own, the same story as apt and the Debian ISOs: the
                   # install script carries the tarball's sha256 inline, and every narinfo is
                   # signed by cache.nixos.org-1 and checked against the key in nix's own config.
                   # The gate vouches for none of the bytes.
                   #
                   # Flake refs like `github:NixOS/nixpkgs` need nothing new here —
                   # api.github.com and codeload.github.com reads have always been open to any
                   # repo.
                   #
                   # NOT opened, and each a separate ask: search.nixos.org, nixos.wiki and
                   # nix.dev (docs, per the item 31 rule — add them when one actually 403s), any
                   # *.cachix.org (third-party caches, written by arbitrary uploaders), and
                   # install.determinate.systems (a different installer than the one asked for).
                   "nixos.org", "releases.nixos.org",
                   "channels.nixos.org", "cache.nixos.org",
                   }

# Exact POST paths permitted on a READ_ONLY_HOSTS host, as {host: {paths}}. Everything else on
# these hosts keeps the plain GET/HEAD policy, and no credentials are injected either way.
#
# The first two are dependency-audit calls: npm's and OSV's "here is my dependency tree, which of
# it is vulnerable?" endpoints, which are POSTs because the tree doesn't fit in a URL. That is
# also the honest cost — unlike LAUNCHPAD_PATHS, whose bodies are a version string and a tool
# name, these bodies are LARGE and shaped by the guest's own lockfile. They are not inspected.
# The bound is "a JSON body to two fixed endpoints on two known hosts", which is a real, if
# bounded, write-out channel, and a wider one than anything else in this tier. Opened
# deliberately on request (NOTES 31); revoke by deleting the entry, which restores GET/HEAD-only.
#
# Two Antigravity entries lived here (an OAuth token exchange and an Unleash flag handshake)
# until Antigravity was removed on 2026-08-29; they went with it, along with the two
# cloudcode-pa OPEN_HOSTS entries that were its model backend.
#
# The rule those left behind is worth keeping: telemetry POSTs stay shut even when the log shows
# them 403ing. `play.googleapis.com POST /log` was refused on exactly that basis — nothing stops
# working without it, and a periodic POST with a guest-authored body is the shape this gate
# exists to keep closed, same call as cafe.github.com's telemetry in NOTES 30.
READ_ONLY_POST_PATHS = {
    "registry.npmjs.org":       {"/-/npm/v1/security/advisories/bulk"},  # npm audit
    "api.osv.dev":              {"/v1/querybatch"},                      # osv-scanner batch query
}

# FULLY-OPEN HOSTS — the one exception to the whole model. Every other rule in this file is
# read-only, credential-free, or org-gated, because the guest is assumed compromised and the
# point of the gate is that data cannot get OUT. A host listed here bypasses all of that: any
# method, any path, any port, arbitrary request bodies. That is an unrestricted exfiltration
# channel by construction — a compromised guest can POST anything it can read to it.
#
# It is kept in its own set with its own log marker (never folded into READ_ONLY_HOSTS) so that
# reviewing this file shows the escape hatch immediately instead of hiding it in a long list.
#
# NO CREDENTIALS ARE INJECTED HERE, and that is not negotiable per-host: the GitHub PAT is the
# host's secret and must never be sent anywhere but GitHub.
#
# Port note: no rule in this file has ever matched on port — a host entry already applies to
# every port — so "any port" needs no extra code.
#
# Added on request; narrow it to specific methods/paths (see LAUNCHPAD_PATHS for that shape) if
# the real need turns out to be narrower than "everything".
#
# `100.54.242.68` lived here from 2026-08-04 (NOTES 28) until 2026-08-11, when it was removed on
# request — no longer needed. It is denied again like any unlisted host.
OPEN_HOSTS = {
              # moshi-hook's daemon backend (NOTES 42), opened on request. This one is here for a
              # reason worth reading before adding anything like it: `moshi serve` reaches it as
              # `GET wss://…/api/v1/hosts/<hostId>/connect` — a WebSocket. The upgrade is a GET, so
              # READ_ONLY_HOSTS would have admitted it and it would have *looked* like the
              # narrowest tier in this file, but this addon implements only `request()`: once
              # mitmproxy passes the 101, frames flow in BOTH directions, unfiltered and unlogged.
              # A method-based rule cannot gate a WebSocket, so listing it here is not a widening
              # over the read-only tier — it is the same access, honestly labelled.
              #
              # Two things this host does that no other entry in this file does. (a) The outbound
              # frames are agent events: cwd, project name, tool name, model, and the command text
              # itself. (b) The INBOUND direction carries `approval.decision` frames that unblock
              # the guest's agent — the only inbound control channel in this policy; everything
              # else here is data-in or gated data-out. Bounded by the daemon only forwarding hook
              # events and only honouring decisions for action ids it raised itself, which is the
              # daemon's own logic and not something this gate enforces.
              #
              # Logged as open_host: true, so the handshake lands in the WRITE audit trail — but only the
              # handshake. Frame traffic after the upgrade is invisible here by construction.
              "api.getmoshi.app"}

# moon/proto reach launch.moonrepo.app with POSTs, so they can't ride READ_ONLY_HOSTS (GET/HEAD
# only). Scope to the exact host + exact paths, inject no creds, deny everything else there.
#
# Honest accounting of the exfil surface: these bodies are NOT inspected. check_version's is
# moon's own version string — fixed and tiny. install_tool's names the tool and version being
# installed, so it's small and structured but not a constant. Either could in principle carry
# smuggled bytes; the bound is "a small POST body to two fixed endpoints on a known host",
# which is a deliberate, bounded exception rather than a free channel.
LAUNCHPAD_HOST = "launch.moonrepo.app"
LAUNCHPAD_PATHS = {"/moon/check_version",     # "is there a newer moon?"
                   "/proto/install_tool"}     # proto's install ping (NOTES 30)

# ---- 3a. CircleCI policy ---------------------------------------------------------------
# One capability: "retry the failed jobs in this workflow" (NOTES 43). This is the only host
# besides GitHub that gets a host-side credential, so it is worth being precise about the split:
#
#   READS  — GET/HEAD, NO credential, exactly as when circleci.com sat in READ_ONLY_HOSTS.
#            vxsuite is a public project, so its pipelines/workflows/jobs/tests endpoints answer
#            unauthenticated; nothing in the read path needs the token and it is not injected
#            there. A private project would 404 these instead, which is a deny by another name.
#   WRITE  — exactly one endpoint, POST /api/v2/workflow/{uuid}/rerun, with the token injected
#            host-side and the target org checked before it goes out.
#
# Three things bound the write, and all three have to pass:
#   1. the PATH must be the rerun endpoint and nothing else (CIRCLE_RERUN_RE). Cancel, approve,
#      trigger-pipeline, env vars, checkout keys, contexts, project settings: no rule matches
#      them, so they 403 like any unlisted path.
#   2. the BODY must be one of the four documented rerun fields, correctly typed
#      (_circle_rerun_body). See that function for why `enable_ssh` is deliberately not among
#      them.
#   3. the workflow must resolve to a project in CIRCLE_RERUN_ORGS (_circle_workflow +
#      _circle_org), asked of CircleCI by the HOST — never taken from the guest.
#
# Understand what the capability actually is before widening it: a rerun re-executes that
# workflow's config against the commit it already ran on. It is not a way to run new code —
# the guest can only rerun what someone already pushed — but it does spend CI time, and the
# jobs it restarts have the project's own secrets in their environment. Scoping it to the orgs
# the guest can already push to (below) is what keeps that inside the existing boundary.
#
# The token is a PERSONAL API token, because CircleCI does not accept project-scoped tokens on
# API v2 at all. So the credential itself is account-wide — everything above is what narrows it
# to one action, and the token never enters the guest.
CIRCLE_HOST = "circleci.com"
CIRCLE_TOKEN = os.environ.get("CIRCLE_TOKEN")   # host-side only; unset -> reruns denied (below)

# Same orgs the guest can already push to and merge PRs in (WRITE_ORGS). Rerunning CI in a repo
# you can push to grants nothing you did not already have; rerunning it anywhere else would.
# Kept as its own name so it can diverge from the git write list later without hunting for the
# use site. Compared lower-cased, like WRITE_ORGS.
CIRCLE_RERUN_ORGS = WRITE_ORGS

# A CircleCI workflow id is a UUID. Matched against the RAW path with a strict hex/dash charset
# for the same reason the GitHub path rules use an unreserved-only charset: no '%' is admitted,
# so what we authorize is byte-for-byte what CircleCI receives, and no percent-decoding
# differential can move the target.
_UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
_UUID_RE = re.compile(rf"^{_UUID}$")
CIRCLE_RERUN_RE = re.compile(rf"^/api/v2/workflow/(?P<wf>{_UUID})/rerun$")

# The four documented fields of a rerun body. Everything here is a flag or a list of job ids, so
# unlike LAUNCHPAD_PATHS / READ_ONLY_POST_PATHS — whose bodies leave the guest uninspected — this
# body is fully validated: no free-form bytes ride out on it. That is deliberate, and it is why
# this write does not widen the exfil surface at all.
#
# `enable_ssh` is NOT accepted, though CircleCI documents it: it starts the rerun with SSH access
# enabled on the job container, which is a debug session on someone else's infrastructure rather
# than a retry, and it is mutually exclusive with `from_failed` so no retry needs it. Add it here
# if that ever changes.
CIRCLE_RERUN_KEYS = {"from_failed",    # rerun starting from the failed job — the ask
                     "jobs",           # rerun these specific job ids (mutually excl. with above)
                     "sparse_tree"}    # only-this-subgraph optimization; rides with `jobs`

def _circle_rerun_body(flow):
    """Validate a workflow-rerun body. Returns (ok, why); why is a short reason for the log.
    An empty body is valid and means 'rerun the whole workflow from the start'."""
    text = (flow.request.get_text() or "").strip()
    if not text:
        return True, None
    try:
        body = json.loads(text)
    except Exception:
        return False, "body is not JSON"
    if not isinstance(body, dict):
        return False, "body is not a JSON object"
    extra = sorted(k for k in body if k not in CIRCLE_RERUN_KEYS)
    if extra:                                   # includes enable_ssh, deliberately
        return False, "unexpected keys: " + ",".join(extra)
    for k in ("from_failed", "sparse_tree"):
        if k in body and not isinstance(body[k], bool):
            return False, f"{k} is not a boolean"
    jobs = body.get("jobs")
    if jobs is not None and not (isinstance(jobs, list) and jobs
                                 and all(isinstance(j, str) and _UUID_RE.match(j) for j in jobs)):
        return False, "jobs is not a non-empty list of job uuids"
    # Job ids are NOT org-checked individually, and don't need to be: CircleCI only reruns jobs
    # that belong to the workflow named in the path, and that workflow's project IS org-checked.
    # Same shape of reasoning as reviewer logins on the GitHub side — they only matter if the
    # server accepts them, and it only accepts them for the target we already authorized.
    return True, None

def _circle_workflow(wf_id):
    """Ask CircleCI which project a workflow belongs to. Returns (project_slug, status), or
    (None, None) on ANY failure — unknown id, HTTP error, timeout, junk response (fail closed).

    Asked by the HOST, un-proxied (_DIRECT), with the host's token: the guest cannot be trusted
    to say which project it is retrying, exactly as it cannot be trusted to name the org behind
    a GraphQL node id (_resolve_owners)."""
    req = urllib.request.Request(
        f"https://{CIRCLE_HOST}/api/v2/workflow/{wf_id}",
        headers={"Circle-Token": CIRCLE_TOKEN or "", "User-Agent": "vmguard"})
    try:
        with _DIRECT.open(req, timeout=8) as r:
            data = json.loads(r.read())
    except Exception:
        return None, None
    if not isinstance(data, dict):
        return None, None
    slug = data.get("project_slug")
    return (slug if isinstance(slug, str) else None), data.get("status")

def _circle_org(project_slug):
    """'gh/votingworks/vxsuite' -> 'votingworks'; None if it isn't a 3-part vcs/org/repo slug.

    CircleCI's newer 'circleci/<org-uuid>/<project-uuid>' slug form parses fine here and then
    fails the org check, because a uuid is not a login — which is the correct outcome: those
    projects can't be placed in an org by name, so they stay denied until someone decides how."""
    parts = (project_slug or "").split("/")
    if len(parts) != 3 or not all(parts):
        return None
    return parts[1]

# ---- 4. handlers + dispatch ------------------------------------------------------------

def _path_write_decision(flow, mo, label, **extra):
    """Shared tail of the path-gated REST write rules (stacks, reviewers, branch cleanup):
    check the owner taken from the URL against WRITE_ORGS, then either inject the PAT and log
    a WRITE, or deny. Always decides the request."""
    owner, repo = mo.group("owner"), mo.group("repo")
    if owner.lower() not in WRITE_ORGS:
        return _deny(flow, f"{label} {owner}/{repo} not in allowed orgs",
                     owner=owner, repo=repo, op="write")
    flow.request.headers["authorization"] = f"Bearer {PAT}"
    _log("WRITE", flow, owner=owner, repo=repo, **extra)   # audit trail for the sensitive op

def _handle_codeload(flow):
    """codeload = archive/tarball downloads, read-only by nature -> allow (any repo)."""
    flow.request.headers["authorization"] = AUTH

def _handle_github_api(flow):
    """api.github.com: REST reads (GET/HEAD) and GraphQL reads always allowed; GraphQL
    mutations allowed only for PR/issue ops scoped to WRITE_ORGS. The three REST write
    families (stacked PRs, reviewer requests, branch deletion) are org-gated off the URL
    path. PAT injected host-side. Everything else denied."""
    m = flow.request.method
    path_only = flow.request.path.split("?", 1)[0]
    if m in API_READ_METHODS:
        flow.request.headers["authorization"] = f"Bearer {PAT}"
        _log("APIREAD", flow)
        return
    if m == "POST" and path_only == "/graphql":
        decision, detail = graphql_decision(flow)
        if decision == "read":
            flow.request.headers["authorization"] = f"Bearer {PAT}"
            _log("APIREAD", flow, gql=True)
            return
        if decision == "mutation-ok":
            flow.request.headers["authorization"] = f"Bearer {PAT}"
            _log("WRITE", flow, gql=True, **detail)
            return
        return _deny(flow, "graphql mutation denied", op="write", **detail)
    if m == "POST":
        mo = STACK_WRITE_RE.match(path_only)               # stacked PRs: create/add/unstack
        if mo:
            return _path_write_decision(flow, mo, "stack write to", stack=True)
        mo = REVIEWERS_WRITE_RE.match(path_only)           # add a reviewer
        if mo:
            return _path_write_decision(flow, mo, "reviewer request on", reviewers=True)
    if m == "PATCH":
        mo = PR_UPDATE_RE.match(path_only)                 # retarget/edit a PR (restacking)
        if mo:
            return _path_write_decision(flow, mo, "PR update in", pr_update=True)
    if m == "PUT":
        mo = MERGE_PR_RE.match(path_only)                  # merge a PR (sync or async)
        if mo:
            return _path_write_decision(flow, mo, "PR merge in", merge=True)
    if m == "DELETE":
        mo = DELETE_REF_RE.match(path_only)                # post-merge branch cleanup
        if mo and _ref_is_plain(mo.group("ref")):
            return _path_write_decision(flow, mo, "branch delete in", ref=mo.group("ref"))
    return _deny(flow, "api.github.com write/mutation denied", op="write")

def _handle_github_web(flow):
    """github.com: git smart-HTTP is classified FIRST, so pushes stay org-restricted even
    through the GET info/refs advertisement (service=git-receive-pack). Everything else is
    open to GET/HEAD from any repo — web pages, release assets (both /releases/download/{tag}/
    and the /releases/latest/download/ convenience URL), /raw/ & /archive/ redirects. Reads
    were already open across GitHub (git fetch any repo, api.github.com GET/HEAD, codeload),
    so that closes the whack-a-mole gap without widening the write surface."""
    parsed = parse_git(flow)
    if parsed is not None:
        owner, repo, op = parsed
        if op == "read":                    # clone/fetch: info/refs upload-pack + git-upload-pack
            flow.request.headers["authorization"] = AUTH
            return
        if op == "write":                   # push: git-receive-pack — allowed orgs only
            if owner.lower() not in WRITE_ORGS:
                return _deny(flow, f"write to {owner}/{repo} not in allowed orgs",
                             owner=owner, repo=repo, op=op)
            flow.request.headers["authorization"] = AUTH
            _log("WRITE", flow, owner=owner, repo=repo)   # audit trail for the sensitive op
            return
        # op is None -> not a git service path; fall through to the generic read rule.
    if flow.request.method in API_READ_METHODS:
        flow.request.headers["authorization"] = AUTH
        _log("READ", flow)
        return
    return _deny(flow, "github.com non-read method denied", op="write")

def _handle_launchpad(flow):
    """moon version check: allow only the one POST endpoint, no creds; deny anything else."""
    if flow.request.method == "POST" and flow.request.path.split("?", 1)[0] in LAUNCHPAD_PATHS:
        _log("READ", flow)
        return
    return _deny(flow, "launchpad: only the version-check POST is allowed", op="write")

def _handle_circleci(flow):
    """circleci.com: GET/HEAD through uncredentialed (unchanged from when this host sat in
    READ_ONLY_HOSTS), plus exactly one credentialed write — POST /api/v2/workflow/{uuid}/rerun,
    body-validated and org-checked host-side. Everything else denied. See section 3a."""
    if flow.request.method in API_READ_METHODS:
        return                                     # no token on reads: the project is public
    path_only = flow.request.path.split("?", 1)[0]
    mo = CIRCLE_RERUN_RE.match(path_only) if flow.request.method == "POST" else None
    if not mo:
        return _deny(flow, "circleci: only the workflow rerun POST is allowed", op="write")
    if not CIRCLE_TOKEN:
        # Deliberately a per-request deny rather than a KeyError at import (which is how GH_PAT
        # is handled): a missing CircleCI token must not take the whole gate down and cut the
        # guest off the network. Fill CIRCLE_TOKEN in /etc/vmguard/secrets.env, then restart.
        return _deny(flow, "circleci: no CIRCLE_TOKEN configured host-side", op="write")
    ok, why = _circle_rerun_body(flow)
    if not ok:
        return _deny(flow, "circleci: rerun body rejected", op="write", why=why)
    wf = mo.group("wf")
    slug, status = _circle_workflow(wf)
    org = _circle_org(slug)
    if org is None:
        return _deny(flow, "circleci: workflow did not resolve to a project", op="write", wf=wf)
    if org.lower() not in CIRCLE_RERUN_ORGS:
        return _deny(flow, f"circleci: rerun in {slug} not in allowed orgs",
                     op="write", wf=wf, project=slug)
    flow.request.headers["circle-token"] = CIRCLE_TOKEN
    # audit trail, same shape as the GitHub writes. wf_status records what the workflow looked
    # like when it was retried; it is NOT a gate (a green workflow may be rerun — NOTES 43).
    _log("WRITE", flow, project=slug, wf=wf, wf_status=status, rerun=True)

def _handle_read_only(flow):
    """third-party read-only hosts: GET/HEAD allowed, no creds injected; writes denied — except
    the exact POST paths in READ_ONLY_POST_PATHS, which are logged as WRITE because their bodies
    leave the guest uninspected."""
    if flow.request.method in API_READ_METHODS:
        return
    if (flow.request.method == "POST"
            and flow.request.path.split("?", 1)[0]
            in READ_ONLY_POST_PATHS.get(flow.request.pretty_host, ())):
        _log("WRITE", flow, post_exception=True)
        return
    return _deny(flow, "read-only host: non-read method denied", op="write")

def _handle_open(flow):
    """Fully-open host (OPEN_HOSTS): every method allowed, no creds injected, every request
    logged. Non-read methods are recorded as WRITE so they show up in the audit trail next to the
    GitHub audit trail — if data ever leaves this way, the log is the only thing that will
    show it, so nothing here is silent."""
    kind = "READ" if flow.request.method in API_READ_METHODS else "WRITE"
    _log(kind, flow, open_host=True)

# Exact-host dispatch. Each of these hosts has its own policy; READ_ONLY_HOSTS is the plain
# GET/HEAD tier checked after them, and anything in neither is denied.
HOST_HANDLERS = {
    "codeload.github.com": _handle_codeload,
    "api.github.com":      _handle_github_api,
    "github.com":          _handle_github_web,
    LAUNCHPAD_HOST:        _handle_launchpad,
    CIRCLE_HOST:           _handle_circleci,
}

# A host in two tiers would silently get whichever the dispatch checks first, quietly
# downgrading (or upgrading) its policy — and with OPEN_HOSTS in the mix that could mean a
# host being far more open than the list it appears in suggests. Catch it at import instead.
for _a, _b, _names in ((HOST_HANDLERS.keys(), READ_ONLY_HOSTS, "HOST_HANDLERS/READ_ONLY_HOSTS"),
                       (HOST_HANDLERS.keys(), OPEN_HOSTS,      "HOST_HANDLERS/OPEN_HOSTS"),
                       (READ_ONLY_HOSTS,      OPEN_HOSTS,      "READ_ONLY_HOSTS/OPEN_HOSTS")):
    _overlap = _a & _b
    assert not _overlap, f"host in both {_names}: {sorted(_overlap)}"

# A POST exception on a host that isn't in the read-only tier is dead config: dispatch would
# never reach _handle_read_only, so the entry would silently do nothing and the POST would be
# denied (or, worse for a HOST_HANDLERS host, quietly answered by a different policy).
_orphans = set(READ_ONLY_POST_PATHS) - READ_ONLY_HOSTS
assert not _orphans, f"READ_ONLY_POST_PATHS host not in READ_ONLY_HOSTS: {sorted(_orphans)}"

class EgressFilter:
    def request(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host
        handler = HOST_HANDLERS.get(host)
        if handler is not None:
            return handler(flow)
        if host in OPEN_HOSTS:
            return _handle_open(flow)
        if host in READ_ONLY_HOSTS:
            return _handle_read_only(flow)
        return _deny(flow, "host not on allowlist")

addons = [EgressFilter()]
