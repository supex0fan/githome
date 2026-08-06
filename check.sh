#!/usr/bin/env bash
# Phase 1: ciBroken()/ignore rules against fixtures, offline.
# Phase 2: E2E — load the real dashboard in headless chromium with a live token.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/index.html"
DIR=$(mktemp -d)
trap 'shred -u "$DIR"/* 2>/dev/null; rm -rf "$DIR"' EXIT

# ---------------------------------------------------------------- phase 1
# The page makes no requests without a token, so the real functions can be
# driven straight off fixture state.
python3 - "$SRC" "$DIR/unit.html" <<'UNIT'
import sys
open(sys.argv[2], "w").write(open(sys.argv[1]).read() + """
<script>
const out = [];
const ck = (name, got, want) =>
  out.push((got === want ? 'ok   ' : 'FAIL ') + name + (got === want ? '' : ` -- got ${got}, want ${want}`));
const ids = () => ciBroken().map((r) => r.id).sort().join(',');

S.me = { login: 'me' };
S.ignore = ['badorg'];
S.dismissed = [];
S.repos = [{ full_name: 'o/a', default_branch: 'main' },
           { full_name: 'o/b', default_branch: 'main' },
           { full_name: 'badorg/c', default_branch: 'main' }];
S.mine = [{ repo: 'o/b', headRef: 'feat/x', number: 1 }];   // my open PR on feat/x
S.assigned = [];
S.runs = [   // newest first, the order load() sorts them into
  { id: 1, repo: 'o/a', head_branch: 'main',    name: 'ci',   conclusion: 'success' },
  { id: 3, repo: 'o/a', head_branch: 'main',    name: 'lint', conclusion: 'failure' },
  { id: 4, repo: 'o/b', head_branch: 'feat/x',  name: 'ci',   conclusion: 'failure' },
  { id: 5, repo: 'o/b', head_branch: 'other/y', name: 'ci',   conclusion: 'failure' },
  { id: 6, repo: 'badorg/c', head_branch: 'main', name: 'ci', conclusion: 'failure' },
  { id: 2, repo: 'o/a', head_branch: 'main',    name: 'ci',   conclusion: 'failure' },
];
ck('superseded failure hidden; default-branch + my-PR failures kept', ids(), '3,4');
S.dismissed = [3];
ck('dismissed run drops out', ids(), '4');
S.dismissed = [];
ck('owner entry ignores the whole org', ignored('badorg/anything'), true);
ck('owner entry does not ignore a lookalike owner', ignored('badorgish/x'), false);
ck('unrelated owner kept', ignored('o/a'), false);
ck('repo with no CI at all yields no cards', (S.runs = [], ids()), '');

S.ignore = [];
toggleIgnore('o/a');
ck('toggling a clean repo ignores it', ignored('o/a'), true);
toggleIgnore('o/a');
ck('toggling it back includes it', ignored('o/a'), false);

S.ignore = [];
toggleIgnore('o');
ck('toggling an owner ignores the owner', ignored('o'), true);
ck('...and every repo under it', ignored('o/a') && ignored('o/b'), true);
toggleIgnore('o/a');
ck('a repo under an ignored owner can be ticked back on', ignored('o/a'), false);
ck('...without freeing its siblings', ignored('o/b'), true);
ck('...and the owner stays ignored', ignored('o'), true);
toggleIgnore('o/a');
ck('crossing it again re-inherits the owner rule', ignored('o/a'), true);
ck('no leftover rules after the round trip', S.ignore.join(), 'o');

const forkSuite = { oid: 'abc', checkSuites: { nodes: [{ databaseId: 7, conclusion: 'FAILURE',
  status: 'COMPLETED', createdAt: '2026-01-01T00:00:00Z', branch: null, commit: { oid: 'abc' },
  workflowRun: { url: 'u', event: 'pull_request', workflow: { name: 'ci' } } }] } };
ck('a fork PR suite with no branch inherits the PR head ref',
   suitesOf('o/c', forkSuite, 'feat/fork')[0].head_branch, 'feat/fork');
ck('GraphQL conclusions are lowercased so isFail matches',
   isFail(suitesOf('o/c', forkSuite, 'x')[0]), true);

S.ignore = []; S.q = ''; S.filter = 'all';
S.events = { 'o/b': '2026-03-01T00:00:00Z' };
const rs = [{ full_name: 'o/a', pushed_at: '2026-05-01T00:00:00Z' },
            { full_name: 'o/b', pushed_at: '2026-01-01T00:00:00Z' }];
const order = () => visibleRepos(rs).map((r) => r.full_name).join(',');
S.sort = 'anyone';
ck('sort by anyone uses pushed_at', order(), 'o/a,o/b');
S.sort = 'mine';
ck('sort by me uses my events, unknowns last', order(), 'o/b,o/a');
document.title = 'UNIT ' + out.join(' @@ ');
</script>""")
UNIT

chromium --headless --disable-gpu --no-sandbox --virtual-time-budget=4000 \
  --dump-dom "$DIR/unit.html" 2>/dev/null \
  | grep -o '<title>UNIT[^<]*' | sed 's/<title>UNIT //' | tr '@' '\n' | grep -v '^$'
echo

# ---------------------------------------------------------------- phase 2
TOKEN=$(gh auth token)
# Inject the token in place of the localStorage read so the page self-loads.
python3 - "$SRC" "$DIR/t.html" "$TOKEN" <<'PY'
import sys
src, dst, tok = sys.argv[1], sys.argv[2], sys.argv[3]
html = open(src).read()
needle = "pat.value = localStorage.getItem(TOKEN_KEY) || '';"
assert needle in html, "injection point not found"
open(dst, "w").write(html.replace(needle, f"pat.value = {tok!r};"))
PY

chromium --headless --disable-gpu --no-sandbox --allow-file-access-from-files \
  --virtual-time-budget=45000 --dump-dom "$DIR/t.html" 2>/dev/null > "$DIR/dom.html"

python3 - "$DIR/dom.html" "$TOKEN" <<'PY'
import re, sys
dom = open(sys.argv[1]).read().replace(sys.argv[2], "<REDACTED>")
for sid in ["blocking","repos","work","runs","feed"]:
    m = re.search(rf'<section id="{sid}"[^>]*>(.*?)</section>', dom, re.S)
    if not m: print(f"{sid:8} SECTION MISSING"); continue
    b = m.group(1)
    count = re.search(r'class="count"[^>]*>([^<]*)<', b)
    err   = re.search(r'class="err">(.*?)</div>', b, re.S)
    rows  = len(re.findall(r'class="row[ "]', b))
    empty = 'class="empty">' in b and 'Loading' not in b
    load  = 'Loading' in b
    state = (f'ERROR: {re.sub("<[^>]+>","",err.group(1)).strip()[:90]}' if err
             else 'still loading' if load and not rows else f'{rows} rows' if rows
             else 'empty' if empty else 'blank')
    extra = ''
    if sid == 'repos':
        # a row with no CI icon and a "—" count means the per-repo fan-out never landed
        extra = (f'  ci_unknown={len(re.findall(r"class=.ci.></span", b))}/{rows}'
                 f'  counts_pending={len(re.findall(r"class=.counts.>—<", b))}/{rows}'
                 f'  avatars={len(re.findall(chr(34)+"oav", b))}/{rows}')
    if sid == 'blocking':
        extra = f'  filled={len(re.findall(r"class=.row bcard", b))}/4'
    # the blocking strip is a bare grid with no header, so it has no count span
    label = '' if sid == 'blocking' else (count.group(1) or '-') if count else 'COUNT SPAN GONE'
    print(f'{sid:8} count={label:22} {state}{extra}')

# header pills are derived from every other panel, so a stale one means a broken derive
head = dom.split('<section id="blocking"')[0]
pills = re.findall(r'class="pill">.*?</i>([^<]*)<', head, re.S)
print(f'pills    {pills if pills else "MISSING"}')
PY
