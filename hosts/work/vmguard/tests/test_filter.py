#!/usr/bin/env python3
"""Offline unit tests for egress_filter.py.

No mitmproxy install and no network needed: we stub the `mitmproxy` module and mock the
node-ID -> org resolver. The host has no system python, so run it through nix-shell:
  nix-shell -p python3 --run 'GH_PAT=dummy VMGUARD_DENYLOG=/tmp/t.log python3 tests/test_filter.py'
"""
import types, sys, json, os, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", "egress_filter.py"))  # was ../artifacts/ in the Fedora staging layout

# --- stub mitmproxy so the addon imports standalone ---
mit = types.ModuleType("mitmproxy")
http = types.ModuleType("mitmproxy.http")
class _Resp:
    @staticmethod
    def make(*a, **k):
        return object()
http.Response = _Resp
mit.http = http
sys.modules["mitmproxy"] = mit
sys.modules["mitmproxy.http"] = http

# the addon reads these at import time
os.environ.setdefault("GH_PAT", "dummy-pat-for-tests")
os.environ.setdefault("CIRCLE_TOKEN", "dummy-circle-token-for-tests")
os.environ.setdefault("VMGUARD_DENYLOG", os.path.join(HERE, "test-requests.log"))

spec = importlib.util.spec_from_file_location("gf", ADDON)
gf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gf)

# grabbed before decide() below monkey-patches the module attribute away
_real_resolve = gf._resolve_owners

_fails = 0
def check(name, got, want):
    global _fails
    ok = got == want
    if not ok:
        _fails += 1
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {got!r}" + ("" if ok else f"  (want {want!r})"))

# ---- scanner: string/bracket-aware top-level mutation field extraction ----
S = gf._scan_mutation_fields
check("scan/read",            S("query($o:String!){repository(owner:$o){id}}"), (False, []))
check("scan/shorthand",       S("{viewer{login}}"), (False, []))
check("scan/create_pr",       S("mutation X($i:CreatePullRequestInput!){createPullRequest(input:$i){pullRequest{id}}}"), (True, ["createPullRequest"]))
check("scan/alias",           S("mutation{cp: createPullRequest(input:$i){pullRequest{id}}}"), (True, ["createPullRequest"]))
check("scan/two_fields",      S("mutation{createIssue(input:$a){issue{id}} deleteRepository(input:$b){clientMutationId}}"), (True, ["createIssue", "deleteRepository"]))
check("scan/brace_in_string", S('mutation{createIssue(input:{title:"a{b}c",body:"}}}"}){issue{id}}}'), (True, ["createIssue"]))
check("scan/word_in_string",  S('query{search(query:"mutation deleteRepository",type:ISSUE,first:1){issueCount}}'), (False, []))
# the exact document gh sends for `pr edit --add-reviewer` (named op + typed variable)
check("scan/request_reviews_by_login",
      S("mutation RequestReviewsByLogin($input:RequestReviewsByLoginInput!){requestReviewsByLogin(input: $input){clientMutationId}}"),
      (True, ["requestReviewsByLogin"]))

# ---- decision: op-allowlist AND org-resolution (resolver mocked) ----
def _decide_full(query, variables, owners):
    gf._resolve_owners = lambda ids: owners
    flow = types.SimpleNamespace(request=types.SimpleNamespace(
        get_text=lambda: json.dumps({"query": query, "variables": variables or {}}),
        path="/graphql", method="POST"))
    return gf.graphql_decision(flow)

def decide(query, variables, owners):
    return _decide_full(query, variables, owners)[0]

def why(query, variables, owners):
    """the 'why' the deny log will now carry — the diagnostic added in NOTES 23"""
    return _decide_full(query, variables, owners)[1].get("why")

check("decide/read",              decide('query{repository(owner:"x"){id}}', {}, None), "read")
check("decide/pr_allowed",        decide("mutation{createPullRequest(input:$i){pullRequest{id}}}", {"input": {"repositoryId": "R_1"}}, {"votingworks"}), "mutation-ok")
check("decide/pr_forbidden_org",  decide("mutation{createPullRequest(input:$i){pullRequest{id}}}", {"input": {"repositoryId": "R_9"}}, {"torvalds"}), "deny")
check("decide/merge_allowed",     decide("mutation{mergePullRequest(input:$i){pullRequest{merged}}}", {"input": {"pullRequestId": "PR_1"}}, {"votingworks"}), "mutation-ok")
check("decide/merge_forbidden",   decide("mutation{mergePullRequest(input:$i){pullRequest{merged}}}", {"input": {"pullRequestId": "PR_9"}}, {"torvalds"}), "deny")
check("decide/automerge_allowed", decide("mutation{enablePullRequestAutoMerge(input:$i){clientMutationId}}", {"input": {"pullRequestId": "PR_1"}}, {"eventualbuddha"}), "mutation-ok")
# merge variants added 2026-08-10 (NOTES 31) — same org gate as mergePullRequest
check("decide/merge_async_allowed",   decide("mutation{mergePullRequestAsync(input:$i){clientMutationId}}", {"input": {"pullRequestId": "PR_1"}}, {"votingworks"}), "mutation-ok")
check("decide/merge_async_forbidden", decide("mutation{mergePullRequestAsync(input:$i){clientMutationId}}", {"input": {"pullRequestId": "PR_9"}}, {"torvalds"}), "deny")
# InStack names several PRs: ALL of them must land in WRITE_ORGS, not just one
check("decide/merge_stack_allowed",   decide("mutation{mergePullRequestsInStack(input:$i){clientMutationId}}", {"input": {"pullRequestIds": ["PR_1", "PR_2"]}}, {"votingworks"}), "mutation-ok")
check("decide/merge_stack_mixed_org", decide("mutation{mergePullRequestsInStack(input:$i){clientMutationId}}", {"input": {"pullRequestIds": ["PR_1", "PR_9"]}}, {"votingworks", "torvalds"}), "deny")
# gh pr review
check("decide/add_review_allowed",   decide("mutation{addPullRequestReview(input:$i){clientMutationId}}", {"input": {"pullRequestId": "PR_1", "body": "lgtm"}}, {"votingworks"}), "mutation-ok")
check("decide/add_review_forbidden", decide("mutation{addPullRequestReview(input:$i){clientMutationId}}", {"input": {"pullRequestId": "PR_9", "body": "lgtm"}}, {"torvalds"}), "deny")
# resolve a review conversation (NOTES 38) — the exact document seen 11 times in the deny log.
# threadId is a PRRT_ node id, hence the new _RESOLVE_Q fragment; the org gate is unchanged.
check("decide/resolve_thread_allowed",   decide("mutation{resolveReviewThread(input:$i){thread{isResolved}}}", {"input": {"threadId": "PRRT_1"}}, {"votingworks"}), "mutation-ok")
check("decide/resolve_thread_forbidden", decide("mutation{resolveReviewThread(input:$i){thread{isResolved}}}", {"input": {"threadId": "PRRT_9"}}, {"torvalds"}), "deny")
# threadId must be COLLECTED as a node id, or the mutation resolves no target and fails closed
check("decide/resolve_thread_collects_id", sorted(gf._collect_node_ids([{"variables": {"input": {"threadId": "PRRT_1", "clientMutationId": "abc"}}}])), ["PRRT_1"])
check("decide/resolve_thread_no_target",  decide("mutation{resolveReviewThread(input:$i){thread{isResolved}}}", {"input": {"threadId": "PRRT_1"}}, set()), "deny")
# the inverse was deliberately left out, so it must still be denied by op
check("decide/unresolve_denied",         decide("mutation{unresolveReviewThread(input:$i){thread{isResolved}}}", {"input": {"threadId": "PRRT_1"}}, {"votingworks"}), "deny")
check("decide/unresolve_why",            why("mutation{unresolveReviewThread(input:$i){thread{isResolved}}}", {"input": {"threadId": "PRRT_1"}}, {"votingworks"}), "op not in allowlist")
# reply to a review thread (NOTES 41) — the other half of the address/reply/resolve loop
check("decide/thread_reply_allowed",   decide("mutation{addPullRequestReviewThreadReply(input:$i){comment{id}}}", {"input": {"pullRequestReviewThreadId": "PRRT_1", "body": "done in abc123"}}, {"votingworks"}), "mutation-ok")
check("decide/thread_reply_forbidden", decide("mutation{addPullRequestReviewThreadReply(input:$i){comment{id}}}", {"input": {"pullRequestReviewThreadId": "PRRT_9", "body": "x"}}, {"torvalds"}), "deny")
# its optional pullRequestReviewId is collected too, so BOTH ids must land in an allowed org
check("decide/thread_reply_two_ids",   gf._collect_node_ids([{"variables": {"input": {"pullRequestReviewThreadId": "PRRT_1", "pullRequestReviewId": "PRR_1", "body": "x"}}}]), {"PRRT_1", "PRR_1"})
# these three already-allowed mutations can carry a milestoneId; before NOTES 41 that failed closed
check("decide/milestone_collected",    sorted(gf._collect_node_ids([{"variables": {"input": {"pullRequestId": "PR_1", "milestoneId": "MI_1"}}}])), ["MI_1", "PR_1"])
check("decide/delete_repo_denied", decide("mutation{deleteRepository(input:$i){clientMutationId}}", {"input": {"repositoryId": "R_1"}}, {"votingworks"}), "deny")
check("decide/gist_denied",       decide("mutation{createGist(input:$i){gist{url}}}", {"input": {"files": []}}, set()), "deny")
check("decide/sneaky_2nd_field",  decide("mutation{createIssue(input:$a){issue{id}} deleteRepository(input:$b){clientMutationId}}", {"input": {"repositoryId": "R_1"}}, {"votingworks"}), "deny")
check("decide/mixed_org_batch",   decide("mutation{addLabelsToLabelable(input:$i){clientMutationId}}", {"labelableId": "I_1", "labelIds": ["L_1"]}, {"votingworks", "torvalds"}), "deny")
check("decide/unresolvable_id",   decide("mutation{createIssue(input:$i){issue{id}}}", {"input": {"repositoryId": "bad"}}, None), "deny")
# the real `gh pr edit --add-reviewer` request, verbatim from its debug output: reviewers are
# LOGIN strings, so pullRequestId is the only node id and the org gate keys off it as usual
_GH_REVIEW_Q = "mutation RequestReviewsByLogin($input:RequestReviewsByLoginInput!){requestReviewsByLogin(input: $input){clientMutationId}}"
_GH_REVIEW_V = {"input": {"pullRequestId": "PR_kwDOEaKHaM76r4Ba", "userLogins": ["kofi-q"],
                          "botLogins": [], "teamSlugs": [], "union": False}}
check("decide/gh_add_reviewer",      decide(_GH_REVIEW_Q, _GH_REVIEW_V, {"votingworks"}), "mutation-ok")
check("decide/gh_add_reviewer_org",  decide(_GH_REVIEW_Q, _GH_REVIEW_V, {"torvalds"}), "deny")
# only the PR id is collected — reviewer logins are not node ids and must not reach the resolver
check("ids/gh_add_reviewer", sorted(gf._collect_node_ids([{"variables": _GH_REVIEW_V}])), ["PR_kwDOEaKHaM76r4Ba"])
# requestReviews (node-id form): allowed too, and its reviewer ids must not break the org check
check("decide/reviewers_allowed", decide("mutation{requestReviews(input:$i){clientMutationId}}", {"input": {"pullRequestId": "PR_1", "userIds": ["U_1"], "union": True}}, {"votingworks"}), "mutation-ok")
check("decide/reviewers_forbidden_org", decide("mutation{requestReviews(input:$i){clientMutationId}}", {"input": {"pullRequestId": "PR_9", "userIds": ["U_1"]}}, {"torvalds"}), "deny")
# a mutation whose ids resolve to NO target org (only principals) must fail closed
check("decide/reviewers_no_target", decide("mutation{requestReviews(input:$i){clientMutationId}}", {"input": {"pullRequestId": "PR_1", "userIds": ["U_1"]}}, set()), "deny")
# the op allowlist still binds: an unlisted op with the same variable shape stays denied
check("decide/reviewers_op_not_allowed", decide("mutation{removeEnterpriseAdmin(input:$i){clientMutationId}}", {"input": {"pullRequestId": "PR_1", "userIds": ["U_1"]}}, {"votingworks"}), "deny")

# ---- _collect_node_ids: real node ids only; look-alike keys must not reach the resolver ----
# (a bogus id makes GitHub return null, which fails the whole mutation closed — see NOTES 23)
C = lambda v: sorted(gf._collect_node_ids([{"variables": v}]))
check("ids/basic",        C({"input": {"pullRequestId": "PR_1"}}), ["PR_1"])
check("ids/list",         C({"input": {"userIds": ["U_1", "U_2"]}}), ["U_1", "U_2"])
check("ids/plain_id",     C({"id": "R_1"}), ["R_1"])
check("ids/skips_sha",    C({"input": {"pullRequestId": "PR_1", "expectedHeadOid": "a1b2c3"}}), ["PR_1"])
check("ids/skips_echo",   C({"input": {"pullRequestId": "PR_1", "clientMutationId": "abc"}}), ["PR_1"])
check("ids/skips_bare_oid", C({"input": {"oid": "deadbeef"}}), [])
# `gh pr merge` sends the SHA guard: op allowed, org fine, must no longer fail closed
check("decide/merge_with_oid",
      decide("mutation{mergePullRequest(input:$i){pullRequest{merged}}}",
             {"input": {"pullRequestId": "PR_1", "expectedHeadOid": "a1b2c3d4"}}, {"votingworks"}), "mutation-ok")
check("decide/merge_with_oid_bad_org",
      decide("mutation{mergePullRequest(input:$i){pullRequest{merged}}}",
             {"input": {"pullRequestId": "PR_9", "expectedHeadOid": "a1b2c3d4"}}, {"torvalds"}), "deny")

# ---- deny detail: the log must name the failing op/org, not just "denied" ----
check("why/op_not_allowed",  why("mutation{deleteRepository(input:$i){clientMutationId}}", {"input": {"repositoryId": "R_1"}}, {"votingworks"}), "op not in allowlist")
check("why/bad_org",         why("mutation{createPullRequest(input:$i){pullRequest{id}}}", {"input": {"repositoryId": "R_9"}}, {"torvalds"}), "org not permitted")
check("why/no_target",       why("mutation{requestReviews(input:$i){clientMutationId}}", {"input": {"userIds": ["U_1"]}}, set()), "no resolvable target org")
check("why/unresolvable",    why("mutation{createIssue(input:$i){issue{id}}}", {"input": {"repositoryId": "bad"}}, None), "no resolvable target org")
check("why/unparseable",     why("mutation{createIssue(input:$i){issue{id}", {}, {"votingworks"}), "unparseable graphql")
check("why/allowed_is_clean",_decide_full("mutation{createPullRequest(input:$i){pullRequest{id}}}", {"input": {"repositoryId": "R_1"}}, {"votingworks"})[1],
      {"ops": ["createPullRequest"], "orgs": ["votingworks"]})
# the exact op name must reach the log, so a future widen needs no guessing
check("why/names_the_op",    _decide_full("mutation{deleteRepository(input:$i){clientMutationId}}", {"input": {"repositoryId": "R_1"}}, {"votingworks"})[1].get("bad_ops"),
      ["deleteRepository"])
check("why/names_the_org",   _decide_full("mutation{createPullRequest(input:$i){pullRequest{id}}}", {"input": {"repositoryId": "R_9"}}, {"torvalds"})[1].get("bad_orgs"),
      ["torvalds"])
# a read carries no detail at all
check("why/read_no_detail",  _decide_full('query{repository(owner:"x"){id}}', {}, None)[1], {})

# ---- _resolve_owners: principal nodes are skipped, unknown typenames still fail closed ----
# (decide() mocks the resolver out; here we drive the REAL one with a stubbed HTTP round-trip,
# so the node-classification logic itself is under test)
def resolve(nodes):
    class _R:
        def __enter__(s): return s
        def __exit__(s, *a): return False
        def read(s): return json.dumps({"data": {"nodes": nodes}}).encode()
    gf._DIRECT = types.SimpleNamespace(open=lambda req, timeout=None: _R())
    return _real_resolve({"X_1"})

check("resolve/pr_target",   resolve([{"__typename": "PullRequest", "repository": {"owner": {"login": "votingworks"}}}]), {"votingworks"})
check("resolve/skips_user",  resolve([{"__typename": "PullRequest", "repository": {"owner": {"login": "votingworks"}}},
                                      {"__typename": "User"}]), {"votingworks"})
check("resolve/skips_team_bot", resolve([{"__typename": "Repository", "owner": {"login": "eventualbuddha"}},
                                        {"__typename": "Team"}, {"__typename": "Bot"}]), {"eventualbuddha"})
check("resolve/only_principals", resolve([{"__typename": "User"}, {"__typename": "Bot"}]), set())
check("resolve/unknown_type",  resolve([{"__typename": "Enterprise"}]), None)

# ---- inline node ids (NOTES 39): args written into the document, not passed in `variables` ----
IN = gf._scan_inline_node_ids
check("inline/thread_id",     IN('mutation{resolveReviewThread(input:{threadId:"PRRT_1"}){thread{isResolved}}}'), ({"PRRT_1"}, True))
check("inline/nested_input",  IN('mutation{addComment(input:{subjectId:"PR_1",body:"hi"}){clientMutationId}}'), ({"PR_1"}, True))
check("inline/id_list",       IN('mutation{addLabelsToLabelable(input:{labelableId:"I_1",labelIds:["LA_1","LA_2"]}){clientMutationId}}'), ({"I_1", "LA_1", "LA_2"}, True))
# same key rule as the variables walk, so these two are skipped for the same reasons
check("inline/cmid_skipped",  IN('mutation{closeIssue(input:{issueId:"I_1",clientMutationId:"abc"}){clientMutationId}}'), ({"I_1"}, True))
check("inline/oid_skipped",   IN('mutation{mergePullRequest(input:{pullRequestId:"PR_1",expectedHeadOid:"deadbeef"}){clientMutationId}}'), ({"PR_1"}, True))
# a body that merely QUOTES a node id is not a target — otherwise the comment would be denied
check("inline/body_not_id",   IN('mutation{addComment(input:{body:"see PR_9 in torvalds/linux"}){clientMutationId}}'), (set(), True))
check("inline/cursor_not_id", IN('mutation{a(id:"R_1"){b(after:"CURSOR_X"){c}}}'), ({"R_1"}, True))
# string-aware: an id-looking key inside a string literal is not a key
check("inline/quote_in_str",  IN('mutation{addComment(input:{body:"a \\"subjectId:\\" b",subjectId:"PR_1"}){clientMutationId}}'), ({"PR_1"}, True))
# the parameterized form has nothing inline, which is why the variables walk still exists
check("inline/vars_form",     IN('mutation X($i:AddCommentInput!){addComment(input:$i){clientMutationId}}'), (set(), True))
# structural surprises fail closed
check("inline/unterminated",  IN('mutation{addComment(input:{subjectId:"PR_1}){x}}')[1], False)
# plural exclusion mirrors the singular one: a LIST of git SHAs names no target either
check("inline/oids_skipped",  IN('mutation{x(input:{commitOids:["deadbeef","cafe1234"],pullRequestId:"PR_1"}){y}}'), ({"PR_1"}, True))
# a batched body: inline ids are collected from every item, not just the first
check("inline/batch", sorted(gf._scan_inline_node_ids('mutation{closeIssue(input:{issueId:"I_1"}){x}}')[0]
                          | gf._scan_inline_node_ids('mutation{closeIssue(input:{issueId:"I_2"}){x}}')[0]), ["I_1", "I_2"])

# end-to-end, with a resolver that answers PER ID — so a decoy cannot stand in for a real target
def _decide_ids(query, variables, owner_of):
    gf._resolve_owners = lambda ids: ({owner_of[i] for i in ids}
                                      if ids and all(i in owner_of for i in ids) else None)
    flow = types.SimpleNamespace(request=types.SimpleNamespace(
        get_text=lambda: json.dumps({"query": query, "variables": variables or {}}),
        path="/graphql", method="POST"))
    return gf.graphql_decision(flow)[0]

_OWN = {"PR_ok": "votingworks", "PRRT_ok": "votingworks", "PR_evil": "torvalds"}
# THE BYPASS this scanner closes: benign id in `variables`, real target inline. Before NOTES 39
# only the decoy was resolved, so this returned "mutation-ok" and wrote to another org.
check("inline/decoy_denied",  _decide_ids('mutation{addComment(input:{subjectId:"PR_evil",body:"x"}){clientMutationId}}', {"id": "PR_ok"}, _OWN), "deny")
# an inline target inside WRITE_ORGS still works — the point is that it is now CHECKED, not shut
check("inline/inline_allowed", _decide_ids('mutation{addComment(input:{subjectId:"PR_ok",body:"x"}){clientMutationId}}', {}, _OWN), "mutation-ok")
# and the requested capability, in the exact shape the deny log showed (NOTES 38/39)
check("inline/thread_inline_ok", _decide_ids('mutation{resolveReviewThread(input:{threadId:"PRRT_ok"}){thread{isResolved}}}', {}, _OWN), "mutation-ok")
# n_ids on the deny separates "found no target at all" from "resolver rejected the ids"
check("inline/decoy_denied_2", _decide_ids('mutation{closeIssue(input:{issueId:"PR_evil"}){x}}', {"issueId": "PR_ok"}, _OWN), "deny")
check("inline/n_ids_zero",    _decide_full('mutation{resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}', {}, set())[1].get("n_ids"), 0)
check("inline/n_ids_counts",  _decide_full('mutation{resolveReviewThread(input:{threadId:"PRRT_1"}){thread{isResolved}}}', {}, None)[1].get("n_ids"), 1)
# review threads are a TARGET type (NOTES 38), so they must resolve to an owner, not be skipped
check("resolve/review_thread", resolve([{"__typename": "PullRequestReviewThread",
                                         "repository": {"owner": {"login": "votingworks"}}}]), {"votingworks"})
# ...which only works because _RESOLVE_Q asks for the field. Guard the pairing: every typename
# an allowed mutation can target needs a fragment, or it fails closed at the org check.
for _t in ("Repository", "PullRequest", "Issue", "IssueComment", "PullRequestReviewThread",
           "PullRequestReview", "Milestone", "Discussion", "Label"):
    check(f"resolve/q_has_{_t}", f"... on {_t}{{" in gf._RESOLVE_Q, True)
# Projects are deliberately absent: no `repository` field, so they don't fit this resolver (NOTES 41)
for _t in ("Project", "ProjectV2"):
    check(f"resolve/q_lacks_{_t}", f"... on {_t}{{" in gf._RESOLVE_Q, False)
# the types added in NOTES 41 classify like any other target
check("resolve/pr_review",  resolve([{"__typename": "PullRequestReview",
                                      "repository": {"owner": {"login": "votingworks"}}}]), {"votingworks"})
check("resolve/milestone",  resolve([{"__typename": "Milestone",
                                      "repository": {"owner": {"login": "votingworks"}}}]), {"votingworks"})
# ...and a Project still fails closed, because the query asks it for nothing it can answer
check("resolve/project_closed", resolve([{"__typename": "ProjectV2"}]), None)
check("resolve/null_node",     resolve([{"__typename": "User"}, None]), None)
check("resolve/no_ids",        _real_resolve(set()), None)

# ---- request(): github.com access rule (any GET/HEAD read; writes stay org-gated) ----
# Returns "allow" if the request was permitted, else "deny" if a 403 response was set.
def gh(path, method="GET", host="github.com"):
    base, _, qs = path.partition("?")
    query = {}
    for kv in (qs.split("&") if qs else []):
        k, _, v = kv.partition("="); query[k] = v
    flow = types.SimpleNamespace(request=types.SimpleNamespace(
        pretty_host=host, method=method, path=path,
        path_components=[c for c in base.split("/") if c], query=query, headers={}))
    flow.response = None
    gf.EgressFilter().request(flow)
    return "deny" if flow.response is not None else "allow"

# reads: releases (both URL shapes), raw/archive redirects, plain web pages — all GET/HEAD
check("gh/release_versioned",  gh("/moonrepo/moon/releases/download/v1.31.0/moon-linux"), "allow")
check("gh/release_latest",     gh("/moonrepo/moon/releases/latest/download/moon_cli-installer.sh"), "allow")
check("gh/release_latest_head",gh("/moonrepo/moon/releases/latest/download/moon-linux", "HEAD"), "allow")
check("gh/release_latest_page",gh("/moonrepo/moon/releases/latest"), "allow")
check("gh/raw_redirect",       gh("/votingworks/vxsuite/raw/main/README.md"), "allow")
check("gh/web_page",           gh("/votingworks/vxsuite"), "allow")
# clone/fetch reads (git-upload-pack is a POST but classified read) — allowed any repo
check("gh/clone_inforefs",     gh("/torvalds/linux/info/refs?service=git-upload-pack"), "allow")
check("gh/clone_uploadpack",   gh("/torvalds/linux/git-upload-pack", "POST"), "allow")
# writes: push stays org-gated, even the info/refs advertisement; other non-reads denied
check("gh/push_advert_forbidden", gh("/LazyVim/LazyVim/info/refs?service=git-receive-pack"), "deny")
check("gh/push_advert_allowed",   gh("/votingworks/vxsuite/info/refs?service=git-receive-pack"), "allow")
check("gh/push_recvpack_forbidden", gh("/LazyVim/LazyVim/git-receive-pack", "POST"), "deny")
check("gh/push_recvpack_allowed",   gh("/votingworks/vxsuite/git-receive-pack", "POST"), "allow")
check("gh/release_post_denied",     gh("/moonrepo/moon/releases/latest/download/moon-linux", "POST"), "deny")
check("gh/web_post_denied",         gh("/votingworks/vxsuite/anything", "POST"), "deny")

# ---- stacked PRs (REST): POST create/add/unstack, org-gated off the URL path ----
API = "api.github.com"
# the two read shapes ride the existing GET/HEAD rule
check("stack/list_get",        gh("/repos/votingworks/vxsuite/stacks", "GET", host=API), "allow")
check("stack/get_by_number",   gh("/repos/votingworks/vxsuite/stacks/12", "GET", host=API), "allow")
# writes in an allowed org
check("stack/create",          gh("/repos/votingworks/vxsuite/stacks", "POST", host=API), "allow")
check("stack/create_other_org",gh("/repos/eventualbuddha/dotfiles/stacks", "POST", host=API), "allow")
check("stack/add",             gh("/repos/votingworks/vxsuite/stacks/12/add", "POST", host=API), "allow")
check("stack/unstack",         gh("/repos/votingworks/vxsuite/stacks/12/unstack", "POST", host=API), "allow")
check("stack/create_qs",       gh("/repos/votingworks/vxsuite/stacks?foo=1", "POST", host=API), "allow")
check("stack/org_case_insens", gh("/repos/VotingWorks/vxsuite/stacks", "POST", host=API), "allow")
# writes outside WRITE_ORGS stay denied
check("stack/forbidden_org",   gh("/repos/torvalds/linux/stacks", "POST", host=API), "deny")
check("stack/forbidden_add",   gh("/repos/torvalds/linux/stacks/1/add", "POST", host=API), "deny")
# the branch must not become a general REST write hole
check("stack/delete_denied",   gh("/repos/votingworks/vxsuite/stacks/12", "DELETE", host=API), "deny")
check("stack/patch_denied",    gh("/repos/votingworks/vxsuite/stacks/12", "PATCH", host=API), "deny")
check("stack/unknown_subpath", gh("/repos/votingworks/vxsuite/stacks/12/nuke", "POST", host=API), "deny")
check("stack/not_a_stack_path",gh("/repos/votingworks/vxsuite/pulls", "POST", host=API), "deny")
check("stack/prefix_only",     gh("/repos/votingworks/vxsuite/stacksomething", "POST", host=API), "deny")
check("stack/nonnumeric_id",   gh("/repos/votingworks/vxsuite/stacks/abc/add", "POST", host=API), "deny")
# encoded-traversal bypass: raw path carries %2f, so the strict regex must reject it
# (decoding it would yield owner=votingworks with repo='vxsuite/../../torvalds/linux')
check("stack/encoded_traversal",
      gh("/repos/votingworks/vxsuite%2f..%2f..%2ftorvalds%2flinux/stacks", "POST", host=API), "deny")
check("stack/plain_traversal",
      gh("/repos/votingworks/vxsuite/../../torvalds/linux/stacks", "POST", host=API), "deny")

# ---- reviewer requests (REST): POST requested_reviewers, org-gated off the URL path ----
# the shape actually seen in the deny log
check("rev/create",            gh("/repos/votingworks/vxsuite/pulls/9045/requested_reviewers", "POST", host=API), "allow")
check("rev/other_org",         gh("/repos/eventualbuddha/dotfiles/pulls/7/requested_reviewers", "POST", host=API), "allow")
check("rev/org_case_insens",   gh("/repos/VotingWorks/vxsuite/pulls/9045/requested_reviewers", "POST", host=API), "allow")
check("rev/list_get",          gh("/repos/votingworks/vxsuite/pulls/9045/requested_reviewers", "GET", host=API), "allow")
# outside WRITE_ORGS
check("rev/forbidden_org",     gh("/repos/torvalds/linux/pulls/1/requested_reviewers", "POST", host=API), "deny")
# must not become a general PR-write hole
check("rev/delete_denied",     gh("/repos/votingworks/vxsuite/pulls/9045/requested_reviewers", "DELETE", host=API), "deny")
check("rev/patch_denied",      gh("/repos/votingworks/vxsuite/pulls/9045/requested_reviewers", "PATCH", host=API), "deny")
# (PATCH /pulls/{n} itself is allowed — see the PR-update section below. It used to be denied;
#  that changed deliberately in NOTES 29, so this case moved rather than disappearing.)
check("rev/reviews_denied",    gh("/repos/votingworks/vxsuite/pulls/9045/reviews", "POST", host=API), "deny")
check("rev/nonnumeric_pr",     gh("/repos/votingworks/vxsuite/pulls/abc/requested_reviewers", "POST", host=API), "deny")
check("rev/prefix_only",       gh("/repos/votingworks/vxsuite/pulls/9045/requested_reviewers_x", "POST", host=API), "deny")
check("rev/subpath_denied",    gh("/repos/votingworks/vxsuite/pulls/9045/requested_reviewers/1", "POST", host=API), "deny")
# encoded traversal: raw path carries %2f, so the strict charset must reject it outright
check("rev/encoded_traversal",
      gh("/repos/votingworks/vxsuite%2f..%2f..%2ftorvalds%2flinux/pulls/1/requested_reviewers", "POST", host=API), "deny")
check("rev/plain_traversal",
      gh("/repos/votingworks/vxsuite/../../torvalds/linux/pulls/1/requested_reviewers", "POST", host=API), "deny")

# ---- PR update (REST): PATCH /pulls/{n}, org-gated — restacking retargets the base branch ----
# the exact shapes seen in the deny log (PRs 9065 / 9070 / 9054)
check("prupd/patch",           gh("/repos/votingworks/vxsuite/pulls/9065", "PATCH", host=API), "allow")
check("prupd/other_org",       gh("/repos/eventualbuddha/dotfiles/pulls/7", "PATCH", host=API), "allow")
check("prupd/org_case_insens", gh("/repos/VotingWorks/vxsuite/pulls/9070", "PATCH", host=API), "allow")
check("prupd/query_string",    gh("/repos/votingworks/vxsuite/pulls/9054?foo=1", "PATCH", host=API), "allow")
check("prupd/get_still_read",  gh("/repos/votingworks/vxsuite/pulls/9054", "GET", host=API), "allow")
# outside WRITE_ORGS
check("prupd/forbidden_org",   gh("/repos/torvalds/linux/pulls/1", "PATCH", host=API), "deny")
# anchored at the PR number: no subpath rides along on PATCH
check("prupd/merge_subpath",   gh("/repos/votingworks/vxsuite/pulls/9054/merge", "PATCH", host=API), "deny")
check("prupd/reviews_subpath", gh("/repos/votingworks/vxsuite/pulls/9054/reviews", "PATCH", host=API), "deny")
check("prupd/nonnumeric",      gh("/repos/votingworks/vxsuite/pulls/abc", "PATCH", host=API), "deny")
check("prupd/pulls_root",      gh("/repos/votingworks/vxsuite/pulls", "PATCH", host=API), "deny")
# other methods on the same path stay shut — only PATCH was opened (PUT .../merge is a
# different path, opened separately below)
check("prupd/put_denied",      gh("/repos/votingworks/vxsuite/pulls/9054", "PUT", host=API), "deny")
check("prupd/post_denied",     gh("/repos/votingworks/vxsuite/pulls/9054", "POST", host=API), "deny")
check("prupd/delete_denied",   gh("/repos/votingworks/vxsuite/pulls/9054", "DELETE", host=API), "deny")
# PATCH must not become a general REST write hole
check("prupd/repo_patch_denied",   gh("/repos/votingworks/vxsuite", "PATCH", host=API), "deny")
check("prupd/issue_patch_denied",  gh("/repos/votingworks/vxsuite/issues/12", "PATCH", host=API), "deny")
check("prupd/branch_prot_denied",  gh("/repos/votingworks/vxsuite/branches/main/protection", "PATCH", host=API), "deny")
# traversal: raw path carries %2f, strict charset rejects it outright
check("prupd/encoded_traversal",
      gh("/repos/votingworks/vxsuite%2f..%2f..%2ftorvalds%2flinux/pulls/1", "PATCH", host=API), "deny")
check("prupd/plain_traversal",
      gh("/repos/votingworks/vxsuite/../../torvalds/linux/pulls/1", "PATCH", host=API), "deny")

# ---- PR merge (REST): PUT /pulls/{n}/merge and /merge-async, org-gated ----
# the exact shapes seen in the deny log (PR 9099, 2026-08-10)
check("merge/put",             gh("/repos/votingworks/vxsuite/pulls/9099/merge", "PUT", host=API), "allow")
check("merge/put_async",       gh("/repos/votingworks/vxsuite/pulls/9099/merge-async", "PUT", host=API), "allow")
check("merge/other_org",       gh("/repos/eventualbuddha/dotfiles/pulls/7/merge", "PUT", host=API), "allow")
check("merge/org_case_insens", gh("/repos/VotingWorks/vxsuite/pulls/9099/merge", "PUT", host=API), "allow")
check("merge/query_string",    gh("/repos/votingworks/vxsuite/pulls/9099/merge?foo=1", "PUT", host=API), "allow")
check("merge/get_still_read",  gh("/repos/votingworks/vxsuite/pulls/9099/merge", "GET", host=API), "allow")
# outside WRITE_ORGS
check("merge/forbidden_org",   gh("/repos/torvalds/linux/pulls/1/merge", "PUT", host=API), "deny")
check("merge/forbidden_async", gh("/repos/torvalds/linux/pulls/1/merge-async", "PUT", host=API), "deny")
# PUT must not become a general REST write hole — only these two paths were opened
check("merge/put_pr_root",     gh("/repos/votingworks/vxsuite/pulls/9099", "PUT", host=API), "deny")
check("merge/put_reviewers",   gh("/repos/votingworks/vxsuite/pulls/9099/requested_reviewers", "PUT", host=API), "deny")
check("merge/put_branch_prot", gh("/repos/votingworks/vxsuite/branches/main/protection", "PUT", host=API), "deny")
check("merge/put_collaborator",gh("/repos/votingworks/vxsuite/collaborators/mallory", "PUT", host=API), "deny")
# exact suffixes, not prefixes; and no subpath rides along
check("merge/prefix_only",     gh("/repos/votingworks/vxsuite/pulls/9099/merge-x", "PUT", host=API), "deny")
check("merge/subpath",         gh("/repos/votingworks/vxsuite/pulls/9099/merge/now", "PUT", host=API), "deny")
check("merge/nonnumeric",      gh("/repos/votingworks/vxsuite/pulls/abc/merge", "PUT", host=API), "deny")
# other methods on the merge path stay shut
check("merge/post_denied",     gh("/repos/votingworks/vxsuite/pulls/9099/merge", "POST", host=API), "deny")
check("merge/delete_denied",   gh("/repos/votingworks/vxsuite/pulls/9099/merge", "DELETE", host=API), "deny")
# traversal: raw path carries %2f, strict charset rejects it outright
check("merge/encoded_traversal",
      gh("/repos/votingworks/vxsuite%2f..%2f..%2ftorvalds%2flinux/pulls/1/merge", "PUT", host=API), "deny")
check("merge/plain_traversal",
      gh("/repos/votingworks/vxsuite/../../torvalds/linux/pulls/1/merge", "PUT", host=API), "deny")

# ---- branch cleanup: DELETE heads/ refs in WRITE_ORGS only ----
# the shape actually seen in the deny log (gh percent-encodes the slash in the branch name)
check("delref/encoded_slash",
      gh("/repos/votingworks/vxsuite/git/refs/heads/brian%2Fesm-migration-spec", "DELETE", host=API), "allow")
check("delref/plain",       gh("/repos/votingworks/vxsuite/git/refs/heads/main", "DELETE", host=API), "allow")
check("delref/literal_slash", gh("/repos/votingworks/vxsuite/git/refs/heads/brian/foo", "DELETE", host=API), "allow")
check("delref/dotted",      gh("/repos/votingworks/vxsuite/git/refs/heads/release-1.2.3", "DELETE", host=API), "allow")
check("delref/other_org_ok",gh("/repos/eventualbuddha/dotfiles/git/refs/heads/wip", "DELETE", host=API), "allow")
check("delref/org_case",    gh("/repos/VotingWorks/vxsuite/git/refs/heads/wip", "DELETE", host=API), "allow")
# outside WRITE_ORGS
check("delref/forbidden_org", gh("/repos/torvalds/linux/git/refs/heads/master", "DELETE", host=API), "deny")
# tags and other ref namespaces stay untouchable — heads/ only
check("delref/tag_denied",  gh("/repos/votingworks/vxsuite/git/refs/tags/v1.0.0", "DELETE", host=API), "deny")
check("delref/bare_refs_denied", gh("/repos/votingworks/vxsuite/git/refs", "DELETE", host=API), "deny")
check("delref/notes_denied",gh("/repos/votingworks/vxsuite/git/refs/notes/commits", "DELETE", host=API), "deny")
# must not become a general REST DELETE hole
check("delref/repo_denied", gh("/repos/votingworks/vxsuite", "DELETE", host=API), "deny")
check("delref/release_denied", gh("/repos/votingworks/vxsuite/releases/42", "DELETE", host=API), "deny")
# traversal in the ref tail: both encoded and literal must fail closed, since GitHub may
# normalize '..' before routing and retarget a repo outside WRITE_ORGS
check("delref/encoded_traversal",
      gh("/repos/votingworks/vxsuite/git/refs/heads/..%2F..%2F..%2F..%2Ftorvalds%2Flinux%2Fgit%2Frefs%2Fheads%2Fmaster",
         "DELETE", host=API), "deny")
check("delref/literal_traversal",
      gh("/repos/votingworks/vxsuite/git/refs/heads/../../../../torvalds/linux/git/refs/heads/master",
         "DELETE", host=API), "deny")
check("delref/dot_segment", gh("/repos/votingworks/vxsuite/git/refs/heads/a/./b", "DELETE", host=API), "deny")
check("delref/empty_segment", gh("/repos/votingworks/vxsuite/git/refs/heads/a//b", "DELETE", host=API), "deny")
# no escape other than %2F is admitted (e.g. %2e%2e, or an encoded owner/repo)
check("delref/other_escape", gh("/repos/votingworks/vxsuite/git/refs/heads/%2e%2e%2Fx", "DELETE", host=API), "deny")
check("delref/encoded_repo",
      gh("/repos/votingworks/vxsuite%2f..%2f..%2ftorvalds%2flinux/git/refs/heads/main", "DELETE", host=API), "deny")
# helper-level checks on the segment validator
check("refplain/simple",    gf._ref_is_plain("main"), True)
check("refplain/encoded",   gf._ref_is_plain("brian%2Fesm-migration-spec"), True)
check("refplain/dotdot",    gf._ref_is_plain("..%2Fx"), False)
check("refplain/lower_enc", gf._ref_is_plain("..%2fx"), False)
check("refplain/trailing",  gf._ref_is_plain("x%2F"), False)

# ---- read-only third-party hosts: GET/HEAD through, everything else denied ----
check("ro/google_go_tarball", gh("/go/go1.24.0.linux-amd64.tar.gz", "GET",  host="dl.google.com"), "allow")
check("ro/google_head",       gh("/go/go1.24.0.linux-amd64.tar.gz", "HEAD", host="dl.google.com"), "allow")
check("ro/google_post_denied",gh("/upload", "POST", host="dl.google.com"), "deny")
check("ro/google_put_denied", gh("/go/x", "PUT",   host="dl.google.com"), "deny")
# Go modules: the proxy serves zips, the sumdb serves signed checksums — both GET-only
check("ro/goproxy_mod",       gh("/github.com/spf13/cobra/@v/v1.8.0.zip", "GET", host="proxy.golang.org"), "allow")
check("ro/goproxy_list",      gh("/github.com/spf13/cobra/@v/list", "GET", host="proxy.golang.org"), "allow")
check("ro/gosumdb_lookup",    gh("/lookup/github.com/spf13/cobra@v1.8.0", "GET", host="sum.golang.org"), "allow")
check("ro/goproxy_post_denied", gh("/upload", "POST", host="proxy.golang.org"), "deny")
check("ro/gosumdb_post_denied", gh("/lookup/x", "POST", host="sum.golang.org"), "deny")
# meat.dev: requested for an install — reads through, writes shut
check("ro/meat_get",          gh("/install.sh", "GET",  host="meat.dev"), "allow")
check("ro/meat_head",         gh("/install.sh", "HEAD", host="meat.dev"), "allow")
check("ro/meat_post_denied",  gh("/telemetry", "POST", host="meat.dev"), "deny")
# the entries are exact hosts, not suffixes — no subdomain rides along
check("ro/meat_subdomain",    gh("/install.sh", "GET", host="cdn.meat.dev"), "deny")
check("ro/golang_org_bare",   gh("/dl/", "GET", host="golang.org"), "deny")

# ---- fully-open host: every method through, but still no credential and still logged ----
OPEN = "cloudcode-pa.googleapis.com"
check("open/get",    gh("/",             "GET",    host=OPEN), "allow")
check("open/post",   gh("/collect",      "POST",   host=OPEN), "allow")
check("open/put",    gh("/x",            "PUT",    host=OPEN), "allow")
check("open/delete", gh("/x",            "DELETE", host=OPEN), "allow")
check("open/patch",  gh("/x",            "PATCH",  host=OPEN), "allow")
check("open/deep_path_qs", gh("/a/b/c?d=1", "POST", host=OPEN), "allow")
# the host entry is exact — a neighbour is NOT covered
check("open/neighbour_denied", gh("/", "POST", host="other-cloudcode-pa.googleapis.com"), "deny")
# 100.54.242.68 was fully open from 2026-08-04 until it was removed on request (NOTES 33)
check("open/retired_ip",       gh("/", "POST", host="100.54.242.68"), "deny")
check("open/retired_ip_get",   gh("/", "GET",  host="100.54.242.68"), "deny")

# THE credential guarantee: the GitHub PAT must never be sent to a non-GitHub destination.
def hdrs(path, method, host):
    flow = types.SimpleNamespace(request=types.SimpleNamespace(
        pretty_host=host, method=method, path=path,
        path_components=[c for c in path.split("?")[0].split("/") if c], query={}, headers={}))
    flow.response = None
    gf.EgressFilter().request(flow)
    return flow.request.headers
check("open/no_creds_get",  hdrs("/", "GET",  OPEN), {})
check("open/no_creds_post", hdrs("/exfil", "POST", OPEN), {})
# contrast: GitHub destinations DO get the PAT, so the check above is meaningful
check("open/github_does_get_creds", "authorization" in hdrs("/votingworks/vxsuite", "GET", "github.com"), True)

# ---- launchpad: only moon's version-check POST is allowed on launch.moonrepo.app ----
LP = "launch.moonrepo.app"
check("lp/version_check_post", gh("/moon/check_version", "POST", host=LP), "allow")
check("lp/install_tool_post",  gh("/proto/install_tool", "POST", host=LP), "allow")
check("lp/version_check_get",  gh("/moon/check_version", "GET",  host=LP), "deny")   # not the version POST
check("lp/install_tool_get",   gh("/proto/install_tool", "GET",  host=LP), "deny")
check("lp/other_path_post",    gh("/moon/telemetry", "POST", host=LP), "deny")       # any other endpoint stays shut
check("lp/proto_other_post",   gh("/proto/telemetry", "POST", host=LP), "deny")      # the /proto prefix is not open
check("lp/install_tool_prefix",gh("/proto/install_tool_x", "POST", host=LP), "deny") # exact paths, not prefixes

# ---- circleci: uncredentialed reads + the ONE credentialed write, the rerun (NOTES 43) ----
CIRCLE = "circleci.com"
WF     = "b1a2c3d4-1111-2222-3333-444455556666"        # a workflow uuid
JOB    = "d724c8e4-0f46-4fc4-8f92-551af6a64223"        # a job uuid (from a real artifact URL)
RERUN  = f"/api/v2/workflow/{WF}/rerun"

def _circle_flow(path, method, body, project, status, token):
    """One circleci.com request with the workflow->project resolver mocked out (the real one
    calls CircleCI over the network). Returns the flow after the addon has decided it."""
    gf._circle_workflow = lambda wf: (project, status)
    saved, gf.CIRCLE_TOKEN = gf.CIRCLE_TOKEN, token
    try:
        flow = types.SimpleNamespace(request=types.SimpleNamespace(
            pretty_host=CIRCLE, method=method, path=path,
            path_components=[c for c in path.split("?")[0].split("/") if c],
            query={}, headers={}, get_text=lambda: body))
        flow.response = None
        gf.EgressFilter().request(flow)
        return flow
    finally:
        gf.CIRCLE_TOKEN = saved

def circle(path, method="GET", body=None, project="gh/votingworks/vxsuite", status="failed",
           token="dummy-circle-token"):
    f = _circle_flow(path, method, body, project, status, token)
    return "deny" if f.response is not None else "allow"

def circle_hdrs(path, method="POST", body=None, project="gh/votingworks/vxsuite"):
    return _circle_flow(path, method, body, project, "failed", "dummy-circle-token").request.headers

# reads: unchanged from when this host sat in READ_ONLY_HOSTS — through, and NO credential
check("ci/read_pipelines",  circle("/api/v2/project/gh/votingworks/vxsuite/pipeline?branch=brian/x"), "allow")
check("ci/read_workflow",   circle(f"/api/v2/workflow/{WF}"), "allow")
check("ci/read_jobs",       circle(f"/api/v2/workflow/{WF}/job"), "allow")
check("ci/read_head",       circle("/api/v2/me", "HEAD"), "allow")
check("ci/read_web_page",   circle("/docs/api/v2/"), "allow")
check("ci/read_no_creds",   circle_hdrs("/api/v2/workflow/" + WF, "GET"), {})

# the one write: the rerun, with the token injected host-side
check("ci/rerun_bare",       circle(RERUN, "POST"), "allow")
check("ci/rerun_empty_body", circle(RERUN, "POST", ""), "allow")
check("ci/rerun_from_failed",circle(RERUN, "POST", '{"from_failed": true}'), "allow")
check("ci/rerun_jobs",       circle(RERUN, "POST", json.dumps({"jobs": [JOB]})), "allow")
check("ci/rerun_jobs_sparse",circle(RERUN, "POST", json.dumps({"jobs": [JOB], "sparse_tree": True})), "allow")
check("ci/rerun_uuid_case",  circle(f"/api/v2/workflow/{WF.upper()}/rerun", "POST"), "allow")
check("ci/rerun_other_org",  circle(RERUN, "POST", project="gh/eventualbuddha/dotfiles"), "allow")
check("ci/rerun_org_case",   circle(RERUN, "POST", project="gh/VotingWorks/vxsuite"), "allow")
# a green workflow may be rerun too — the status is logged, not gated (NOTES 43)
check("ci/rerun_success",    circle(RERUN, "POST", '{"from_failed": true}', status="success"), "allow")
check("ci/rerun_gets_token", circle_hdrs(RERUN).get("circle-token"), "dummy-circle-token")

# org gate: the project comes from CircleCI (host-side), never from the guest
check("ci/rerun_forbidden_org", circle(RERUN, "POST", project="gh/torvalds/linux"), "deny")
check("ci/rerun_bb_forbidden",  circle(RERUN, "POST", project="bb/torvalds/linux"), "deny")
# an org we DO allow, reached through the other vcs prefix, is still the same org
check("ci/rerun_github_prefix", circle(RERUN, "POST", project="github/votingworks/vxsuite"), "allow")
# resolver failure / unknown workflow / junk slug -> fail closed
check("ci/rerun_unresolved",    circle(RERUN, "POST", project=None), "deny")
check("ci/rerun_short_slug",    circle(RERUN, "POST", project="votingworks/vxsuite"), "deny")
check("ci/rerun_long_slug",     circle(RERUN, "POST", project="gh/votingworks/vxsuite/extra"), "deny")
check("ci/rerun_empty_seg",     circle(RERUN, "POST", project="gh//vxsuite"), "deny")
# the uuid-slug project form parses but cannot be placed in an org by name -> denied
check("ci/rerun_uuid_slug",     circle(RERUN, "POST", project=f"circleci/{WF}/{JOB}"), "deny")
# no token configured host-side -> the rerun is denied, but reads keep working
check("ci/rerun_no_token",      circle(RERUN, "POST", token=None), "deny")
check("ci/read_no_token_ok",    circle(f"/api/v2/workflow/{WF}", token=None), "allow")

# body validation: only the documented rerun fields, correctly typed
check("ci/body_enable_ssh",  circle(RERUN, "POST", '{"jobs": ["%s"], "enable_ssh": true}' % JOB), "deny")
check("ci/body_ssh_alone",   circle(RERUN, "POST", '{"enable_ssh": true}'), "deny")
check("ci/body_unknown_key", circle(RERUN, "POST", '{"from_failed": true, "x": 1}'), "deny")
check("ci/body_not_json",    circle(RERUN, "POST", "from_failed=true"), "deny")
check("ci/body_array",       circle(RERUN, "POST", '[{"from_failed": true}]'), "deny")
check("ci/body_str_bool",    circle(RERUN, "POST", '{"from_failed": "true"}'), "deny")
check("ci/body_sparse_str",  circle(RERUN, "POST", '{"sparse_tree": "yes"}'), "deny")
check("ci/body_jobs_str",    circle(RERUN, "POST", '{"jobs": "%s"}' % JOB), "deny")
check("ci/body_jobs_junk",   circle(RERUN, "POST", '{"jobs": ["../../etc/passwd"]}'), "deny")
check("ci/body_jobs_empty",  circle(RERUN, "POST", '{"jobs": []}'), "deny")
# no free-form bytes ride out on this body: a smuggled blob is not a job uuid
check("ci/body_no_smuggling",circle(RERUN, "POST", json.dumps({"jobs": [JOB, "ssh-rsa AAAAB3Nz..."]})), "deny")

# path: the rerun endpoint and nothing else on the whole API
check("ci/cancel_denied",    circle(f"/api/v2/workflow/{WF}/cancel", "POST"), "deny")
check("ci/approve_denied",   circle(f"/api/v2/workflow/{WF}/approve/{JOB}", "POST"), "deny")
check("ci/trigger_denied",   circle("/api/v2/project/gh/votingworks/vxsuite/pipeline", "POST"), "deny")
check("ci/envvar_denied",    circle("/api/v2/project/gh/votingworks/vxsuite/envvar", "POST"), "deny")
check("ci/context_denied",   circle("/api/v2/context", "POST"), "deny")
check("ci/checkout_key_del", circle("/api/v2/project/gh/votingworks/vxsuite/checkout-key/abc", "DELETE"), "deny")
check("ci/v11_retry_denied", circle("/api/v1.1/project/gh/votingworks/vxsuite/1234/retry", "POST"), "deny")
check("ci/graphql_denied",   circle("/graphql-unstable", "POST"), "deny")
# exact shape: no prefix, no subpath, no non-uuid id
check("ci/rerun_prefix",     circle(RERUN + "-now", "POST"), "deny")
check("ci/rerun_subpath",    circle(RERUN + "/now", "POST"), "deny")
check("ci/rerun_nonuuid",    circle("/api/v2/workflow/latest/rerun", "POST"), "deny")
check("ci/rerun_shortuuid",  circle("/api/v2/workflow/b1a2c3d4-1111-2222-3333-4444/rerun", "POST"), "deny")
check("ci/rerun_v1",         circle(f"/api/v1/workflow/{WF}/rerun", "POST"), "deny")
# encoded traversal: the strict hex/dash charset admits no '%' at all
check("ci/rerun_encoded",    circle(f"/api/v2/workflow/{WF}%2f..%2fx/rerun", "POST"), "deny")
check("ci/rerun_traversal",  circle(f"/api/v2/workflow/{WF}/../../x/rerun", "POST"), "deny")
# other methods on the rerun path stay shut — only POST was opened
check("ci/rerun_put",        circle(RERUN, "PUT"), "deny")
check("ci/rerun_delete",     circle(RERUN, "DELETE"), "deny")
check("ci/rerun_patch",      circle(RERUN, "PATCH"), "deny")
# neighbours ride nothing: the artifact host keeps its own read-only entry, app. is not listed
check("ci/app_subdomain",    gh("/pipelines/github/votingworks/vxsuite/1/workflows/x", "GET", host="app.circleci.com"), "deny")
check("ci/tasks_s3_denied",  gh("/storage/artifacts/x/y/0/z.png", "GET", host="circleci-tasks-prod.s3.us-east-1.amazonaws.com"), "deny")

# the credential guarantee, both directions: the CircleCI token is a CircleCI-only secret, and
# the GitHub PAT must never appear on circleci.com either
check("ci/no_pat_on_circle", "authorization" in circle_hdrs(RERUN), False)
check("ci/token_not_on_github", "circle-token" in hdrs("/votingworks/vxsuite", "GET", "github.com"), False)
check("ci/token_not_on_api",    "circle-token" in hdrs("/repos/votingworks/vxsuite/pulls/1", "GET", "api.github.com"), False)
check("ci/token_not_on_open",   "circle-token" in hdrs("/x", "POST", "cloudcode-pa.googleapis.com"), False)

# ---- the three read-only hosts added 2026-08-05 ----
check("ro/circle_artifact",    gh("/output/job/abc/artifacts/0/moon-task-logs/test/stderr.log", "GET", host="output.circle-artifacts.com"), "allow")
check("ro/circle_art_post",    gh("/output/job/abc", "POST", host="output.circle-artifacts.com"), "deny")
check("ro/rustup_manifest",    gh("/rustup/release-stable.toml", "GET", host="static.rust-lang.org"), "allow")
check("ro/rustup_post",        gh("/dist/x", "POST", host="static.rust-lang.org"), "deny")
check("ro/vxdesign_presigned", gh("/nh-qa/uuid/election-package.zip?X-Amz-Signature=abc", "GET", host="vxdesign-staging.s3.us-west-1.amazonaws.com"), "allow")
check("ro/vxdesign_put",       gh("/nh-qa/uuid/x.zip", "PUT", host="vxdesign-staging.s3.us-west-1.amazonaws.com"), "deny")
# exact hosts: the bare S3 endpoint and other buckets are NOT covered by the one bucket entry
check("ro/s3_bare_denied",     gh("/", "GET", host="s3.amazonaws.com"), "deny")
check("ro/other_bucket_denied",gh("/x", "GET", host="vxdesign-prod.s3.us-west-1.amazonaws.com"), "deny")

# ---- the read-only hosts added 2026-08-10 (NOTES 31) ----
# playwright browser bundles: cdn.playwright.dev 302s the payload to the prss host
check("ro/pw_cdn",          gh("/dbazure/download/playwright/builds/chromium/1193/chromium-linux.zip", "GET", host="cdn.playwright.dev"), "allow")
check("ro/pw_download",     gh("/dbazure/download/playwright/builds/chromium/1193/chromium-linux.zip", "GET", host="playwright.download.prss.microsoft.com"), "allow")
check("ro/pw_headless",     gh("/dbazure/download/playwright/builds/chromium/1193/chromium-headless-shell-linux.zip", "GET", host="playwright.download.prss.microsoft.com"), "allow")
check("ro/pw_post_denied",  gh("/upload", "POST", host="playwright.download.prss.microsoft.com"), "deny")
# exact host: the parent download domain is not covered
check("ro/pw_parent_denied",gh("/x", "GET", host="download.prss.microsoft.com"), "deny")
# the driver bundle comes from the azureedge trio instead (NOTES 34), tried in fallback order
check("ro/pw_driver",       gh("/builds/driver/playwright-1.57.0-linux.zip", "GET", host="playwright.azureedge.net"), "allow")
check("ro/pw_driver_akamai",gh("/builds/driver/playwright-1.57.0-linux.zip", "GET", host="playwright-akamai.azureedge.net"), "allow")
check("ro/pw_driver_vzn",   gh("/builds/driver/playwright-1.57.0-linux.zip", "GET", host="playwright-verizon.azureedge.net"), "allow")
check("ro/pw_driver_post",  gh("/builds/driver/x.zip", "POST", host="playwright.azureedge.net"), "deny")
# exact hosts again: the shared CDN domain is not a suffix match
check("ro/azureedge_bare",  gh("/x", "GET", host="azureedge.net"), "deny")
check("ro/azureedge_other", gh("/x", "GET", host="someoneelse.azureedge.net"), "deny")
# debian snapshot archive: date-pinned pool + the /mr metadata API
check("ro/snapshot_pool",   gh("/archive/debian/20260301T000000Z/pool/main/c/chromium/chromium_147.0.7727.137-1%7Edeb12u1_amd64.deb", "GET", host="snapshot.debian.org"), "allow")
check("ro/snapshot_mr",     gh("/mr/binary/chromium/147.0.7727.137-1~deb12u1/binfiles?fileinfo=1", "GET", host="snapshot.debian.org"), "allow")
check("ro/snapshot_post",   gh("/mr/binary/x", "POST", host="snapshot.debian.org"), "deny")
check("ro/jsr_head",        gh("/", "HEAD", host="npm.jsr.io"), "allow")
check("ro/jsr_post_denied", gh("/@scope/pkg", "POST", host="npm.jsr.io"), "deny")
# doc sites: reads only, like every other entry in the tier
check("ro/docs_github",     gh("/rest/pulls/pulls", "GET", host="docs.github.com"), "allow")
check("ro/debian_bug",      gh("/cgi-bin/bugreport.cgi?bug=1141488", "GET", host="bugs.debian.org"), "allow")
check("ro/tanstack",        gh("/query/latest/docs/framework/react/guides/polling", "GET", host="tanstack.com"), "allow")
check("ro/lefthook",        gh("/configuration/stage_fixed.html", "GET", host="lefthook.dev"), "allow")
check("ro/typicode",        gh("/husky/get-started.html", "GET", host="typicode.github.io"), "allow")
check("ro/rustlang_gh_io",  gh("/rustfmt/", "GET", host="rust-lang.github.io"), "allow")
check("ro/precommit",       gh("/", "GET", host="pre-commit.com"), "allow")
check("ro/docs_post_denied",gh("/rest", "POST", host="docs.github.com"), "deny")
# still exact hosts — a sibling github.io project site does not ride along on rust-lang.github.io
check("ro/other_gh_io",     gh("/", "GET", host="torvalds.github.io"), "deny")

# ---- exact-path POST exceptions on read-only hosts (dependency audits) ----
check("rop/npm_audit",       gh("/-/npm/v1/security/advisories/bulk", "POST", host="registry.npmjs.org"), "allow")
check("rop/osv_querybatch",  gh("/v1/querybatch", "POST", host="api.osv.dev"), "allow")
check("rop/npm_audit_qs",    gh("/-/npm/v1/security/advisories/bulk?x=1", "POST", host="registry.npmjs.org"), "allow")
# reads on those hosts are unaffected
check("rop/npm_get",         gh("/react", "GET", host="registry.npmjs.org"), "allow")
check("rop/osv_get",         gh("/v1/vulns/GHSA-x", "GET", host="api.osv.dev"), "allow")
# exact paths, not prefixes, and only POST
check("rop/npm_other_post",  gh("/-/npm/v1/user", "POST", host="registry.npmjs.org"), "deny")
check("rop/npm_publish_put", gh("/some-package", "PUT", host="registry.npmjs.org"), "deny")
check("rop/npm_prefix",      gh("/-/npm/v1/security/advisories/bulk/x", "POST", host="registry.npmjs.org"), "deny")
check("rop/osv_other_post",  gh("/v1/query", "POST", host="api.osv.dev"), "deny")
check("rop/osv_put",         gh("/v1/querybatch", "PUT", host="api.osv.dev"), "deny")
# the exception is per-host: one host's allowed path is not allowed on another
check("rop/cross_host",      gh("/v1/querybatch", "POST", host="registry.npmjs.org"), "deny")
check("rop/cross_host2",     gh("/-/npm/v1/security/advisories/bulk", "POST", host="api.osv.dev"), "deny")
# and it injects no credential, like every other read-only host
check("rop/npm_no_creds",    hdrs("/-/npm/v1/security/advisories/bulk", "POST", "registry.npmjs.org"), {})

# ---- Google Antigravity (NOTES 32): reads on five hosts, two exact POST paths ----
check("ag/install_sh",       gh("/cli/install.sh", "GET", host="antigravity.google"), "allow")
check("ag/update_manifest",  gh("/manifests/linux_amd64.json", "GET", host="antigravity-cli-auto-updater-974169037036.us-central1.run.app"), "allow")
check("ag/cli_tarball",      gh("/antigravity-public/antigravity-cli/1.1.12-5877618327814144/linux-x64/cli_linux_x64.tar.gz", "GET", host="storage.googleapis.com"), "allow")
check("ag/unleash_features", gh("/api/client/features", "GET", host="antigravity-unleash.goog"), "allow")
# the two POSTs that sign-in and the flag client actually need
check("ag/oauth_token",      gh("/token", "POST", host="oauth2.googleapis.com"), "allow")
check("ag/unleash_register", gh("/api/client/register", "POST", host="antigravity-unleash.goog"), "allow")
# telemetry stays denied: unleash metrics, and clearcut on a host that was never added at all
check("ag/unleash_metrics",  gh("/api/client/metrics", "POST", host="antigravity-unleash.goog"), "deny")
check("ag/play_log",         gh("/log", "POST", host="play.googleapis.com"), "deny")
# exact paths and POST only — nothing else on the two opened hosts rides along
check("ag/oauth_revoke",     gh("/revoke", "POST", host="oauth2.googleapis.com"), "deny")
check("ag/oauth_token_put",  gh("/token", "PUT", host="oauth2.googleapis.com"), "deny")
check("ag/unleash_prefix",   gh("/api/client/register/x", "POST", host="antigravity-unleash.goog"), "deny")
check("ag/storage_put",      gh("/antigravity-public/x", "PUT", host="storage.googleapis.com"), "deny")
# exact hosts: neighbouring Google hosts are not covered by these entries
check("ag/other_google",     gh("/x", "GET", host="clients2.google.com"), "deny")
check("ag/antigravity_sub",  gh("/x", "GET", host="cdn.antigravity.google"), "deny")
# no credential is injected here either
check("ag/oauth_no_creds",   hdrs("/token", "POST", "oauth2.googleapis.com"), {})

# ---- Antigravity session bootstrap (NOTES 33) ----
check("ag/userinfo",         gh("/oauth2/v2/userinfo", "GET", host="www.googleapis.com"), "allow")
check("ag/userinfo_post",    gh("/oauth2/v2/userinfo", "POST", host="www.googleapis.com"), "deny")
# the code-assist backend is in OPEN_HOSTS: every method and path, on both channels
for _h in ("cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com"):
    _tag = "daily" if _h.startswith("daily") else "prod"
    check(f"ag/{_tag}_load",     gh("/v1internal:loadCodeAssist", "POST", host=_h), "allow")
    check(f"ag/{_tag}_settings", gh("/v1internal:setUserSettings", "POST", host=_h), "allow")
    check(f"ag/{_tag}_exp",      gh("/v1internal:listExperiments", "POST", host=_h), "allow")
    # model traffic, and anything else the client reaches for later, no longer 403s
    check(f"ag/{_tag}_generate", gh("/v1internal:generateContent", "POST", host=_h), "allow")
    check(f"ag/{_tag}_stream",   gh("/v1internal:streamGenerateContent?alt=sse", "POST", host=_h), "allow")
    check(f"ag/{_tag}_unknown",  gh("/v2whatever:somethingNew", "PUT", host=_h), "allow")
    check(f"ag/{_tag}_get",      gh("/v1internal:loadCodeAssist", "GET", host=_h), "allow")
    # open does NOT mean credentialed: the PAT still never leaves GitHub
    check(f"ag/{_tag}_no_creds", hdrs("/v1internal:loadCodeAssist", "POST", _h), {})
# still exact hosts — a third code-assist channel is not covered by the two entries
check("ag/cloudcode_other",  gh("/v1internal:loadCodeAssist", "POST", host="staging-cloudcode-pa.googleapis.com"), "deny")
# and opening these two did not open googleapis.com generally
check("ag/play_still_denied",gh("/log", "POST", host="play.googleapis.com"), "deny")
# the signed-in user's avatar (NOTES 34) — a GET, like the rest of the tier
check("ag/avatar",           gh("/a/ACg8ocILUZHsgW_ROYMoinX9aQzUfFQEN7kMQB1nM7JltaH80DF2bg8=s96-c", "GET", host="lh3.googleusercontent.com"), "allow")
check("ag/avatar_post",      gh("/upload", "POST", host="lh3.googleusercontent.com"), "deny")
# exact host: sibling googleusercontent CDNs are not covered by the lh3 entry
check("ag/avatar_sibling",   gh("/x", "GET", host="lh4.googleusercontent.com"), "deny")

# ---- GitButler CLI install (NOTES 35): the five GETs of the install chain, in order ----
check("gb/install_sh",       gh("/install.sh", "GET", host="gitbutler.com"), "allow")
check("gb/installer_info",   gh("/installers/info/linux/x86_64", "GET", host="app.gitbutler.com"), "allow")
check("gb/installer_bin",    gh("/installers/latest/linux/x86_64/but-installer", "GET", host="releases.gitbutler.com"), "allow")
check("gb/releases",         gh("/releases", "GET", host="app.gitbutler.com"), "allow")
check("gb/but_bin",          gh("/releases/release/0.22.0-3180/linux/x86_64/but", "GET", host="releases.gitbutler.com"), "allow")
# the update-check shapes the installed CLI uses later are the same tier, same methods
check("gb/releases_version", gh("/releases/version/0.22.0", "GET", host="app.gitbutler.com"), "allow")
check("gb/releases_nightly", gh("/releases/nightly", "GET", host="app.gitbutler.com"), "allow")
check("gb/head",             gh("/install.sh", "HEAD", host="gitbutler.com"), "allow")
# read-only tier: no POST anywhere on the three, and no creds injected on the reads
check("gb/post_denied",      gh("/install.sh", "POST", host="gitbutler.com"), "deny")
check("gb/app_post_denied",  gh("/releases", "POST", host="app.gitbutler.com"), "deny")
check("gb/rel_put_denied",   gh("/releases/release/0.22.0-3180/linux/x86_64/but", "PUT", host="releases.gitbutler.com"), "deny")
check("gb/no_creds",         hdrs("/install.sh", "GET", "gitbutler.com"), {})
# docs + blog joined the item 31 doc tier once the agent actually read them (NOTES 36)
check("gb/docs",             gh("/cli-overview", "GET", host="docs.gitbutler.com"), "allow")
check("gb/blog",             gh("/git-worktrees", "GET", host="blog.gitbutler.com"), "allow")
check("gb/docs_post",        gh("/cli-overview", "POST", host="docs.gitbutler.com"), "deny")
check("gb/blog_post",        gh("/git-worktrees", "POST", host="blog.gitbutler.com"), "deny")
# exact hosts: opening five subdomains did not open the org's others
check("gb/api_denied",       gh("/x", "GET", host="api.gitbutler.com"), "deny")
check("gb/bare_denied",      gh("/x", "GET", host="gitbutler.io"), "deny")

# REST review-thread replies are NOT open (NOTES 41): no POST rule matches this path, so the
# GraphQL mutation is the only route. Pinned so the answer is recorded, not re-derived.
check("api/rest_reply_denied", gh("/repos/votingworks/vxsuite/pulls/42/comments/12345/replies", "POST", host="api.github.com"), "deny")
# ...and it stays denied even for an allowed org, i.e. it is the PATH that isn't open, not the org
check("api/rest_reply_denied_org", gh("/repos/eventualbuddha/x/pulls/1/comments/2/replies", "POST", host="api.github.com"), "deny")

# ---- turborepo.dev (NOTES 40): the older domain a turbo.json "$schema" still points at ----
check("ro/turborepo_schema", gh("/schema.json", "GET", host="turborepo.dev"), "allow")
check("ro/turborepo_post",   gh("/schema.json", "POST", host="turborepo.dev"), "deny")
# the current domain was already open; the telemetry endpoint is neither and stays denied
check("ro/turbo_build",      gh("/schema.json", "GET", host="turbo.build"), "allow")
check("ro/turbo_telemetry",  gh("/api/turborepo/v1/events", "POST", host="telemetry.vercel.com"), "deny")

# ---- PyPI + uv (NOTES 37): index host and payload host both needed ----
check("py/simple_index",     gh("/simple/python-barcode/", "GET", host="pypi.org"), "allow")
check("py/json_api",         gh("/pypi/pillow/json", "GET", host="pypi.org"), "allow")
# the wheel itself is served from a different host, which is why both are listed
check("py/wheel",            gh("/packages/a1/b2/pillow-11.0.0-cp312-cp312-manylinux_2_28_x86_64.whl", "GET", host="files.pythonhosted.org"), "allow")
check("py/sdist",            gh("/packages/c3/d4/python_barcode-0.15.1.tar.gz", "GET", host="files.pythonhosted.org"), "allow")
# read-only tier: no uploads (twine's POST / would be exactly that), no creds
check("py/upload_denied",    gh("/legacy/", "POST", host="upload.pypi.org"), "deny")
check("py/simple_post",      gh("/simple/x/", "POST", host="pypi.org"), "deny")
check("py/files_post",       gh("/packages/x.whl", "POST", host="files.pythonhosted.org"), "deny")
check("py/no_creds",         hdrs("/simple/pillow/", "GET", "pypi.org"), {})
# exact hosts: test.pypi.org and the bare pythonhosted domain are not covered
check("py/testpypi_denied",  gh("/simple/pillow/", "GET", host="test.pypi.org"), "deny")
check("py/pythonhosted_bare",gh("/packages/x.whl", "GET", host="pythonhosted.org"), "deny")
# uv: the vanity installer host 302s to releases.astral.sh, so both are open
check("uv/install_sh",       gh("/uv/install.sh", "GET", host="astral.sh"), "allow")
check("uv/redirect_target",  gh("/installers/uv/latest/uv-installer.sh", "GET", host="releases.astral.sh"), "allow")
check("uv/binary_mirror",    gh("/github/uv/releases/download/0.12.3/uv-x86_64-unknown-linux-gnu.tar.gz", "GET", host="releases.astral.sh"), "allow")
# the second mirror the installer walks is github.com, already covered by the read rule
check("uv/github_mirror",    gh("/astral-sh/uv/releases/download/0.12.3/uv-x86_64-unknown-linux-gnu.tar.gz"), "allow")
check("uv/post_denied",      gh("/uv/install.sh", "POST", host="astral.sh"), "deny")
check("uv/docs_denied",      gh("/x", "GET", host="docs.astral.sh"), "deny")
# the CLI's telemetry/AI backends are NOT part of this and stay denied
check("gb/posthog_denied",   gh("/batch", "POST", host="eu.i.posthog.com"), "deny")
check("gb/openrouter_denied",gh("/api/v1/chat/completions", "POST", host="openrouter.ai"), "deny")

# ---- moshi-hook install (NOTES 42): the four GETs of the install chain, and nothing else ----
check("mo/install_sh",       gh("/install.sh", "GET", host="getmoshi.app"), "allow")
check("mo/version_txt",      gh("/hook/latest/version.txt", "GET", host="cdn.getmoshi.app"), "allow")
check("mo/tarball",          gh("/hook/v0.2.85/moshi-hook_Linux_x86_64.tar.gz", "GET", host="cdn.getmoshi.app"), "allow")
check("mo/checksums",        gh("/hook/v0.2.85/checksums.txt", "GET", host="cdn.getmoshi.app"), "allow")
check("mo/head",             gh("/install.sh", "HEAD", host="getmoshi.app"), "allow")
check("mo/no_creds",         hdrs("/install.sh", "GET", "getmoshi.app"), {})
check("mo/post_denied",      gh("/install.sh", "POST", host="getmoshi.app"), "deny")
check("mo/cdn_post_denied",  gh("/hook/latest/version.txt", "POST", host="cdn.getmoshi.app"), "deny")
# The DAEMON backend is in OPEN_HOSTS, not this tier (NOTES 42) — any method, since no
# method-based rule could gate its WebSocket anyway (the upgrade is a GET, and the addon sees
# nothing after the 101). The WS handshake is the shape that matters here.
check("mo/api_ws",           gh("/api/v1/hosts/host_abc/connect", "GET", host="api.getmoshi.app"), "allow")
check("mo/api_events_post",  gh("/api/v1/hosts/host_abc/events", "POST", host="api.getmoshi.app"), "allow")
check("mo/api_usage_post",   gh("/api/v1/hosts/host_abc/usage", "POST", host="api.getmoshi.app"), "allow")
check("mo/api_register",     gh("/api/v1/hosts/register", "POST", host="api.getmoshi.app"), "allow")
check("mo/api_status_get",   gh("/api/v1/hosts/host_abc/status", "GET", host="api.getmoshi.app"), "allow")
# open, but never credentialed — the PAT stays a GitHub-only secret (paired with the
# github_does_get_creds assertion above so this can't quietly become vacuous)
check("mo/api_no_creds",     hdrs("/api/v1/hosts/host_abc/events", "POST", "api.getmoshi.app"), {})
# exact hosts, as always: the open entry is the api subdomain ONLY. The install hosts stay
# read-only (their POST denies above), and neighbours ride nothing.
check("mo/bare_denied",      gh("/x", "GET", host="moshi.app"), "deny")
check("mo/api_neighbour",    gh("/x", "POST", host="ws.getmoshi.app"), "deny")

# ---- two more Debian read-only mirrors (NOTES 44): ISO images + the US apt redirector ----
# cdimage: the image, and the signed checksum files a verified download also fetches
check("dm/cdimage_iso",      gh("/debian-cd/current/amd64/iso-dvd/debian-13.1.0-amd64-DVD-1.iso", "GET", host="cdimage.debian.org"), "allow")
check("dm/cdimage_live",     gh("/images/unofficial/non-free/images-including-firmware/current/amd64/iso-cd/firmware-13.1.0-amd64-netinst.iso", "GET", host="cdimage.debian.org"), "allow")
check("dm/cdimage_sums",     gh("/debian-cd/current/amd64/iso-dvd/SHA512SUMS", "GET", host="cdimage.debian.org"), "allow")
check("dm/cdimage_sig",      gh("/debian-cd/current/amd64/iso-dvd/SHA512SUMS.sign", "GET", host="cdimage.debian.org"), "allow")
check("dm/cdimage_head",     gh("/debian-cd/current/amd64/iso-dvd/debian-13.1.0-amd64-DVD-1.iso", "HEAD", host="cdimage.debian.org"), "allow")
# http.us: the apt shapes — dists metadata and a pool .deb. Plain HTTP rides the same host
# rule, since no rule in the addon matches on port or scheme.
check("dm/httpus_release",   gh("/debian/dists/stable/InRelease", "GET", host="http.us.debian.org"), "allow")
check("dm/httpus_packages",  gh("/debian/dists/stable/main/binary-amd64/Packages.xz", "GET", host="http.us.debian.org"), "allow")
check("dm/httpus_pool",      gh("/debian/pool/main/c/curl/curl_8.14.1-2_amd64.deb", "GET", host="http.us.debian.org"), "allow")
# read-only like every other entry in the tier
check("dm/cdimage_post",     gh("/debian-cd/x", "POST", host="cdimage.debian.org"), "deny")
check("dm/cdimage_put",      gh("/debian-cd/x.iso", "PUT", host="cdimage.debian.org"), "deny")
check("dm/httpus_post",      gh("/debian/x", "POST", host="http.us.debian.org"), "deny")
# and credential-free, like every non-GitHub host
check("dm/cdimage_no_creds", hdrs("/debian-cd/current/amd64/iso-dvd/SHA512SUMS", "GET", "cdimage.debian.org"), {})
check("dm/httpus_no_creds",  hdrs("/debian/dists/stable/InRelease", "GET", "http.us.debian.org"), {})
# exact hosts, as always: neither the parent domain nor a sibling mirror rides along
check("dm/bare_debian",      gh("/", "GET", host="debian.org"), "deny")
check("dm/ftp_us_denied",    gh("/debian/dists/stable/InRelease", "GET", host="ftp.us.debian.org"), "deny")
check("dm/http_de_denied",   gh("/debian/dists/stable/InRelease", "GET", host="http.de.debian.org"), "deny")
check("dm/cdimage_net",      gh("/debian-cd/x.iso", "GET", host="cdimage.debian.net"), "deny")

# ---- the cdimage ISO redirect chain (NOTES 45) ----
# Second front door: get.debian.org, the other CNAME for the same site, on an /images/ path.
check("cd/get_debian",       gh("/images/archive/12.2.0/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso", "GET", host="get.debian.org"), "allow")
check("cd/get_debian_post",  gh("/images/x", "POST", host="get.debian.org"), "deny")
# The ACC Umea backends an ISO 302s onto. laotzu/gemmei/chuangtzu answer 200 directly...
check("cd/laotzu",           gh("/cdimage/archive/12.2.0/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso", "GET", host="laotzu.ftp.acc.umu.se"), "allow")
check("cd/gemmei",           gh("/cdimage/archive/12.2.0/amd64/iso-dvd/debian-12.2.0-amd64-DVD-1.iso", "GET", host="gemmei.ftp.acc.umu.se"), "allow")
check("cd/chuangtzu",        gh("/debian-cd/current/amd64/iso-dvd/debian-13.6.0-amd64-DVD-1.iso", "GET", host="chuangtzu.ftp.acc.umu.se"), "allow")
# ...and these four 302 again into the pool, so a download can pass through them too.
check("cd/ftp_acc",          gh("/debian-cd/12.2.0/amd64/iso-cd/SHA256SUMS", "GET", host="ftp.acc.umu.se"), "allow")
check("cd/saimei",           gh("/cdimage/archive/12.2.0/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso", "GET", host="saimei.ftp.acc.umu.se"), "allow")
check("cd/hammurabi",        gh("/cdimage/archive/12.2.0/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso", "GET", host="hammurabi.ftp.acc.umu.se"), "allow")
check("cd/napoleon",         gh("/cdimage/archive/12.2.0/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso", "GET", host="napoleon.ftp.acc.umu.se"), "allow")
check("cd/tutankhamon",      gh("/cdimage/archive/12.2.0/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso", "GET", host="tutankhamon.ftp.acc.umu.se"), "allow")
# the /mirror/-prefixed path shape seen in the deny log rides the same host rule
check("cd/laotzu_mirror",    gh("/mirror/cdimage/archive/12.2.0/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso", "GET", host="laotzu.ftp.acc.umu.se"), "allow")
check("cd/laotzu_head",      gh("/cdimage/archive/12.2.0/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso", "HEAD", host="laotzu.ftp.acc.umu.se"), "allow")
# read-only and credential-free, like every other entry in the tier
check("cd/laotzu_post",      gh("/cdimage/x", "POST", host="laotzu.ftp.acc.umu.se"), "deny")
check("cd/gemmei_put",       gh("/cdimage/x.iso", "PUT", host="gemmei.ftp.acc.umu.se"), "deny")
check("cd/laotzu_no_creds",  hdrs("/cdimage/archive/12.2.0/amd64/iso-cd/debian-12.2.0-amd64-netinst.iso", "GET", "laotzu.ftp.acc.umu.se"), {})
# The mirror-LIST hosts stay denied: they were tried by hand after cdimage 403'd, and are not
# part of the redirect chain (NOTES 45). Opening them would open arbitrary third-party mirrors.
check("cd/kernel_org_denied",   gh("/debian-cd/12.2.0/amd64/iso-cd/SHA256SUMS", "GET", host="mirrors.kernel.org"), "deny")
check("cd/leaseweb_denied",     gh("/debian-cd/12.2.0/amd64/iso-cd/SHA256SUMS", "GET", host="mirror.us.leaseweb.net"), "deny")
# cloud.debian.org is on the SAME TLS cert as the hosts above and is also in the deny log, but
# it serves qcow2 cloud images — a different artifact and a separate ask. Pinned as denied so
# "it was on the cert" never becomes a reason it quietly rode along.
check("cd/cloud_debian_denied", gh("/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2", "GET", host="cloud.debian.org"), "deny")
# still exact hosts: the ACC parent domains and an unlisted sibling are not suffix-matched
check("cd/acc_parent",       gh("/x", "GET", host="acc.umu.se"), "deny")
check("cd/accum_se",         gh("/x", "GET", host="mirror.accum.se"), "deny")
check("cd/ac2_alias",        gh("/x", "GET", host="laotzu.ftp.ac2.se"), "deny")
check("cd/unlisted_backend", gh("/x", "GET", host="caesar.ftp.acc.umu.se"), "deny")

# ---- nix (NOTES 46) ----
# Install: nixos.org is the entry point and 302s to releases.nixos.org, which serves both the
# script the redirect lands on and the binary tarball that script fetches.
check("nix/install_entry",   gh("/nix/install", "GET", host="nixos.org"), "allow")
check("nix/install_script",  gh("/nix/nix-2.35.2/install", "GET", host="releases.nixos.org"), "allow")
check("nix/install_tarball", gh("/nix/nix-2.35.2/nix-2.35.2-x86_64-linux.tar.xz", "GET", host="releases.nixos.org"), "allow")
# Channels: the installer's last step, and what every later `nix-channel --update` walks.
check("nix/channel_redir",   gh("/nixpkgs-unstable", "GET", host="channels.nixos.org"), "allow")
check("nix/channel_expr",    gh("/nixpkgs/nixpkgs-26.11pre1062790.c27cdad491a9/nixexprs.tar.xz", "GET", host="releases.nixos.org"), "allow")
check("nix/flake_registry",  gh("/flake-registry.json", "GET", host="channels.nixos.org"), "allow")
# The binary cache — the three request shapes nix makes, and the HEAD it uses to probe existence.
check("nix/cache_info",      gh("/nix-cache-info", "GET", host="cache.nixos.org"), "allow")
check("nix/cache_narinfo",   gh("/31dr55fb8a67a91hvhhv259k5wwmvm1b.narinfo", "GET", host="cache.nixos.org"), "allow")
check("nix/cache_nar",       gh("/nar/0yd3lg4nyfnkcs84ij0kz0falh26lw908b0pakxfbzcy46rjns45.nar.zst", "GET", host="cache.nixos.org"), "allow")
check("nix/cache_head",      gh("/31dr55fb8a67a91hvhhv259k5wwmvm1b.narinfo", "HEAD", host="cache.nixos.org"), "allow")
# Read-only and credential-free, like every other entry in the tier. The PUT is the one that
# matters: that is the shape `nix copy --to` uses to push store paths OUT, so pin it denied.
check("nix/cache_put",       gh("/31dr55fb8a67a91hvhhv259k5wwmvm1b.narinfo", "PUT", host="cache.nixos.org"), "deny")
check("nix/cache_post",      gh("/nar/x.nar.zst", "POST", host="cache.nixos.org"), "deny")
check("nix/releases_post",   gh("/nix/x", "POST", host="releases.nixos.org"), "deny")
check("nix/channels_post",   gh("/nixpkgs-unstable", "POST", host="channels.nixos.org"), "deny")
check("nix/cache_no_creds",  hdrs("/nix-cache-info", "GET", "cache.nixos.org"), {})
check("nix/nixos_no_creds",  hdrs("/nix/install", "GET", "nixos.org"), {})
# Still exact hosts: the neighbouring nixos.org names are not suffix-matched, and the docs sites
# follow the item 31 rule (added on a real 403, not ahead of one).
check("nix/search_denied",   gh("/", "GET", host="search.nixos.org"), "deny")
check("nix/wiki_denied",     gh("/wiki/Main_Page", "GET", host="nixos.wiki"), "deny")
check("nix/nixdev_denied",   gh("/manual/nix/stable/", "GET", host="nix.dev"), "deny")
# A third-party cache and a different installer: each its own decision, neither part of the ask.
check("nix/cachix_denied",   gh("/x.narinfo", "GET", host="nix-community.cachix.org"), "deny")
check("nix/detsys_denied",   gh("/nix", "GET", host="install.determinate.systems"), "deny")

try:
    os.remove(os.environ["VMGUARD_DENYLOG"])
except OSError:
    pass

print(f"\n{'ALL PASS' if _fails == 0 else str(_fails) + ' FAILED'}")
sys.exit(1 if _fails else 0)
