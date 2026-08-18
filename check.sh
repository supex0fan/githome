#!/usr/bin/env bash
# Phase 1: ciBroken()/ignore rules against fixtures, offline.
# Phase 2: E2E — load the real dashboard in headless chromium with a live token.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/index.html"
BROWSER=${BROWSER:-$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)}
[ -n "$BROWSER" ] || { echo "no chromium/chrome on PATH; set BROWSER=" >&2; exit 1; }
DIR=$(mktemp -d)
# only the .html copies hold the token; shred chokes on the browser profile dirs
trap 'shred -u "$DIR"/*.html 2>/dev/null || true; rm -rf "$DIR"' EXIT

# ---------------------------------------------------------------- harness
# drive <file> <js condition> <timeout ms> — load the page, wait until the
# condition holds, print the DOM. Node talks CDP directly; nothing to install.
cat > "$DIR/drive.js" <<'JS'
const { spawn } = require('node:child_process');
const fs = require('node:fs'), path = require('node:path');
const [browser, file, cond, timeout, profile] = process.argv.slice(2);

const send = (() => { let id = 0; return (ws, method, params) => new Promise((ok, no) => {
  const mine = ++id;
  ws.addEventListener('message', function on(e) {
    const m = JSON.parse(e.data);
    if (m.id !== mine) return;
    ws.removeEventListener('message', on);
    m.error ? no(new Error(m.error.message)) : ok(m.result);
  });
  ws.send(JSON.stringify({ id: mine, method, params }));
}); })();

const poll = async (fn, ms) => {
  for (const end = Date.now() + ms; Date.now() < end;) {
    const v = await fn().catch(() => null);
    if (v) return v;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`timed out after ${ms}ms waiting for the page to settle`);
};

const kid = spawn(browser, ['--headless', '--disable-gpu', '--no-sandbox',
  '--allow-file-access-from-files', '--remote-debugging-port=0',
  `--user-data-dir=${profile}`, `file://${path.resolve(file)}`], { stdio: 'ignore' });
process.on('exit', () => kid.kill());

(async () => {
  const port = await poll(async () =>
    fs.readFileSync(path.join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0], 15000);
  const page = await poll(async () =>
    (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'), 15000);
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r));
  const evaluate = async (expression) =>
    (await send(ws, 'Runtime.evaluate', { expression, returnByValue: true })).result.value;
  await poll(() => evaluate(cond), +timeout);
  process.stdout.write(await evaluate('document.documentElement.outerHTML'));
  kid.kill();
  process.exit(0);
})().catch((e) => { kid.kill(); console.error(e.message); process.exit(1); });
JS
# a fresh profile per call, so the previous run's DevToolsActivePort can't be read back
drive() { node "$DIR/drive.js" "$BROWSER" "$1" "$2" "$3" "$(mktemp -d "$DIR/profile.XXXX")"; }

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
S.events = {};
bump(S.events, 'o/b', '2026-03-01T00:00:00Z');
const rs = [{ full_name: 'o/a', pushed_at: '2026-05-01T00:00:00Z' },
            { full_name: 'o/b', pushed_at: '2026-01-01T00:00:00Z' }];
const order = () => visibleRepos(rs).map((r) => r.full_name).join(',');
S.sort = 'anyone';
ck('sort by anyone falls back to pushed_at until branch heads land', order(), 'o/a,o/b');
S.sort = 'mine';
ck('sort by me uses my events, unknowns last', order(), 'o/b,o/a');

// Both halves of the LAST column read the same branch heads, so a push to a ref
// nobody has a PR open on has to move them together.
S.anyWork = { 'o/b': '2026-09-01T00:00:00Z' };
S.sort = 'anyone';
ck('a branch head outranks pushed_at once it lands', order(), 'o/b,o/a');
ck('...and a repo with no branch head yet still reads pushed_at',
   anyWorkAt({ full_name: 'o/a', pushed_at: '2026-05-01T00:00:00Z' }), '2026-05-01T00:00:00Z');
S.anyWork = null;
ck('dependabot is not someone working on the repo', isBot('dependabot[bot]'), true);
ck('a bot suffix mid-login is not a bot', isBot('bot-wrangler'), false);
ck('an unattributed commit is not assumed to be a bot', isBot(null), false);

// The day bucket is the account's timezone, hours away from the local clock, so
// any exact sighting of my own work has to beat it - a branch head included.
S.evContrib = { 'o/a': { when: +new Date('2026-05-02T07:00:00Z'), exact: false, at: '2026-05-02T07:00:00Z' } };
S.evPR = null; S.evCommit = null;
S.evRefs = { 'o/a': { when: +new Date('2026-05-01T09:15:00Z'), exact: true, at: '2026-05-01T09:15:00Z' } };
ck('a branch head beats the day bucket even when the bucket looks newer',
   allEvents()['o/a'].at, '2026-05-01T09:15:00.000Z');
S.evRefs = null;
ck('...and with no branch head the bucket still fills the gap',
   allEvents()['o/a'].at, '2026-05-02T07:00:00.000Z');
S.evContrib = null; S.events = {};
const glyph = (i) => ICON[Object.keys(ICON).find((k) => typeIcon(i).includes(ICON[k]))];
ck('an open PR gets the pull-request octicon', glyph({ isPR: true }), ICON.pr);
ck('a draft PR gets the draft octicon', glyph({ isPR: true, draft: true }), ICON.prdraft);
ck('an issue gets the issue octicon', glyph({ isPR: false, labels: [] }), ICON.issue);

const ev = {};
bump(ev, 'o/a', '2026-03-01T00:00:00Z');
bump(ev, 'o/a', '2026-01-01T00:00:00Z');
ck('an older sighting never walks my last work backwards', ev['o/a'].at, '2026-03-01T00:00:00.000Z');
bump(ev, 'o/a', '2026-05-01T00:00:00Z');
ck('a newer one does', ev['o/a'].at, '2026-05-01T00:00:00.000Z');
bump(ev, 'o/b', undefined);
ck('a source with nothing to say adds no entry', 'o/b' in ev, false);

// the day bucket GitHub stamps for today can land in the future; unguarded it beat
// the exact commit time and rendered as "now"
const soon = new Date(Date.now() + 36e5).toISOString();
const ev2 = {};
bump(ev2, 'o/a', soon, false);
ck('a contribution stamped in the future is pulled back to now', ev2['o/a'].when <= Date.now(), true);
bump(ev2, 'o/a', '2026-01-01T00:00:00Z');
ck('an exact commit time outranks the day bucket even when older',
   ev2['o/a'].at, '2026-01-01T00:00:00.000Z');
bump(ev2, 'o/a', soon, false);
ck('...and the day bucket cannot take it back', ev2['o/a'].at, '2026-01-01T00:00:00.000Z');
ck('which matters because ago() renders anything future as now', ago(soon), 'now');

S.err = { repos: 'boom' };
const rowHtml = () => '<div class="row"></div>';
ck('a failed refresh keeps the rows the panel already had',
   panel([1], 'repos', rowHtml).includes('class="row"'), true);
ck('...and says so above them', panel([1], 'repos', rowHtml).includes('last good data'), true);
ck('an error with nothing behind it still owns the panel',
   panel(null, 'repos', rowHtml).includes('class="row"'), false);
S.err = {};

S.rate = { pts: null, rest: null };
ck('quota is unknown until something answers', quotaLeft(), null);
spend('pts', 4000, 5000);
spend('rest', 2500, 5000);
ck('quota reports the budget closest to running out', quotaLeft(), 0.5);
spend('rest', 4900, 5000);
ck('a late high reading cannot walk a budget back up', S.rate.rest.left, 2500);
spend('pts', 10, 0);
ck('a missing limit is ignored rather than dividing by zero', quotaLeft(), 0.5);

const points = (weeks) => sparkline(weeks).match(/points="([^"]+)"/)[1];
ck('sparkline puts the peak on top and the trough on the baseline',
   points([0, 5, 0]), '0.0,17.0 36.0,1.0 72.0,17.0');
ck('a repo with no commits flat-lines instead of dividing by zero',
   points([0, 0, 0]), '0.0,17.0 36.0,17.0 72.0,17.0');

document.title = 'UNIT ' + out.join(' @@ ');
</script>""")
UNIT

drive "$DIR/unit.html" "document.title.startsWith('UNIT')" 10000 \
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
# Once the first load settles, run a second one the way the five-minute timer
# does and watch for a panel going empty. The DOM below is the one left after
# that quiet sync, so the row counts also have to survive it. reload() is the
# only path allowed to blank; sync() must always refresh underneath you.
probe = """
<script>
const PANELS = ['repos', 'runs', 'mine', 'assigned', 'reviews', 'mentions', 'notifs'];
const settled = () => S.spark && PANELS.every((k) => S[k] !== null || S.err[k]);
(async () => {
  while (!settled()) await new Promise((r) => setTimeout(r, 100));
  const before = (S.repos || []).length;
  // only panels holding data can lose it; one that errored out is already empty
  const had = PANELS.filter((k) => S[k] !== null);
  let blanked = '';
  const watch = setInterval(() => {
    const gone = had.filter((k) => S[k] === null);
    if (gone.length) blanked = gone.join('+');
  }, 20);
  await sync();
  while (!settled()) await new Promise((r) => setTimeout(r, 100));
  clearInterval(watch);
  document.title = 'QUIET ' + (blanked ? 'FAIL ' + blanked + ' blanked'
    : (S.repos || []).length >= before ? 'ok' : 'FAIL lost rows');
})();
</script>"""
open(dst, "w").write(html.replace(needle, f"pat.value = {tok!r};") + probe)
PY

# Wait for every panel to settle rather than for a wall-clock budget: --dump-dom
# on its own snapshots the page mid-flight and reports the pending fetches as
# errors, which made the whole phase a race against GitHub's latency.
drive "$DIR/t.html" "document.title.startsWith('QUIET')" 120000 > "$DIR/dom.html"
grep -o '<title>QUIET[^<]*' "$DIR/dom.html" | sed 's/<title>QUIET /quiet sync: /'

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
                 f'  avatars={len(re.findall(chr(34)+"oav", b))}/{rows}'
                 f'  langs={len(re.findall(r"class=.lang.><i", b))}/{rows}'
                 f'  sparks={len(re.findall(r"class=.spark.", b))}/{rows}')
    if sid == 'blocking':
        extra = f'  filled={len(re.findall(r"class=.row bcard", b))}/4'
    # the blocking strip is a bare grid with no header, so it has no count span
    label = '' if sid == 'blocking' else (count.group(1) or '-') if count else 'COUNT SPAN GONE'
    print(f'{sid:8} count={label:22} {state}{extra}')

# header pills are derived from every other panel, so a stale one means a broken derive
head = dom.split('<section id="blocking"')[0]
pills = re.findall(r'class="pill">.*?</i>([^<]*)<', head, re.S)
print(f'pills    {pills if pills else "MISSING"}')
sync = re.search(r'id="synced"[^>]*>([^<]*)<', head)
print(f'header   {sync.group(1).strip() if sync else "SYNCED SPAN GONE"}')
PY
