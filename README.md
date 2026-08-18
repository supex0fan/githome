# githome

A GitHub dashboard that is one HTML file.
No build step, no dependencies, no server.
You open it from disk and it works.

It exists to answer one question on load: what is actually blocking me right now.

## Quick start

```bash
git clone https://github.com/supex0fan/githome
cd githome
xdg-open index.html    # or open on macOS, or just double-click it
```

Paste the output of `gh auth token` into the field in the header and press Load.
The token goes into `localStorage`, so the next open skips straight to the dashboard.

After that it keeps itself current while you are looking at it, without blanking the panels.
The four things that move minute to minute refresh every 20 seconds, the slower repo list every 60.
Look away and it stops entirely; look back and it brings itself up to date before you have finished reading the first row.
If a refresh fails, the rows already on screen stay put rather than being replaced by an error.

Any classic PAT with the `repo` scope works.
That scope is what lets the page see private repositories and the ones owned by your organisations.
Without it you get your public data and not much else.

### Read this before you host it

The page keeps a token with full repository access in `localStorage`.
That is a reasonable trade for a local file that only you open.

It stops being reasonable the moment this lives on a domain, because any script that gets injected into the page can read that token and act as you on every repo you can touch.
If you deploy this, put a proxy in front of the GitHub API and stop handing the token to the browser at all.

## What it shows

The strip across the top is the point of the whole thing.
It holds at most four cards, ranked: broken CI first, then reviews someone is waiting on you for, then P1 issues assigned to you.
Each CI card can be dismissed, and dismissals persist.

Below that, three columns, each scrolling independently:

| Column | Contents |
| --- | --- |
| Repositories | Your 25 most recently active repos with language, a 52 week commit sparkline, CI state, and open PR and issue counts |
| PRs & issues | Split into what you own and what is waiting on you |
| Actions and Activity | Recent workflow runs, and your notification feed |

### What counts as broken CI

A red run only reaches the top strip if nothing has superseded it.
The rule is: take the newest run per repo, branch and workflow, then keep the failures that are either on the repo's default branch or on the head branch of a PR you authored or were assigned.

That last part matters more than it sounds.
Most red runs on a busy account have already been fixed by a later push, and a dashboard that keeps showing them trains you to ignore the whole panel.

`action_required` is deliberately not a failure.
It means a fork PR is waiting on a maintainer to approve its workflows, which is not something you broke.

### Sorting

Repositories sort by last work by anyone, or last work by you.
The `LAST` column follows whichever you picked, so the dates always explain the order.

Repos you have not touched show `-` under the second sort and sink to the bottom.

Both readings come off the same thing: the head commit of every branch, the newest for anyone and the newest of yours for you.
That is the only way the two agree.
`pushed_at` was the obvious source for the first one and it is not the same measurement - it moves on a push to any ref, so a dependabot bump read as someone working on the repo, and it moves when the push lands rather than when the work was written.
Branch heads authored by a `[bot]` account are not counted as anyone working.

## Settings

The gear opens a list of every owner and repository the account can reach, each with a tick or a cross.
Crossing an owner ignores everything under it.
Individual repos can still be ticked back on, which is what the `!owner/repo` rule in the saved settings is for.

Ignored repos are dropped from every panel and every count, and skipped when fetching.
Saving refetches.

## How it works

A full load is three HTTP requests, and the header shows how much of your hourly quota is left.

| Request | Carries | Costs | Clock |
| --- | --- | --- | --- |
| GraphQL work query | All four issue searches, CI on your own PRs | ~2s | 20s |
| `GET /notifications` | The activity feed | ~0.5s | 20s |
| GraphQL repo query | Repos, CI rollup, open PR and issue counts, your contributions | ~4s | 60s |
| GraphQL runs query | Branch heads and default-branch check suites for the repos on screen | ~4s | 60s |

Three queries rather than one, split twice, for two different reasons.

The runs query is separate because one query does not work.
Folding it into the repo query sends 50 repos of nested commit history to the server, and GitHub answers 502 after about eleven seconds, reliably.
It is fired from the repo list already on screen rather than the one currently in flight, so the two run side by side instead of end to end.
Only a cold start has to wait to learn which repos to ask about.

The work query is separate because of what it costs.
The repo list is the slow half by a wide margin: across 50 repos, the open PR and issue counts cost about a second and a half, and the CI rollup another second and a half.
It is also the half that barely changes.
The four searches come back in about two seconds and hold everything that actually moves while you are watching, so they got their own faster clock rather than queueing behind six seconds of work that would have returned the same answer.

Together that took a refresh from about nine seconds to under two for the panels that matter.

Notifications stay on REST because GraphQL has no equivalent.
They are sent as conditional requests, so GitHub answers 304 with no rate-limit charge whenever nothing has changed, which is what makes polling them at this rate free.

The rest is a single store and six views over it.
The panels are not independent: the header pills, the blocking strip and the repo CI glyphs are all derived from what the other panels fetched, which is why they agree with each other.

### Why GraphQL

The REST version of this took about 75 requests per load, because there is no cross-repo endpoint for workflow runs or open PR counts, so you fan out over every repo.

GraphQL costs 1 rate-limit point per query and fixes two things REST could not:

- Open PR and issue counts arrive separately. REST only gives you `open_issues_count`, which includes PRs, so the old version subtracted one from the other and hoped.
- `contributionsCollection` reaches back a year for your own activity. The events feed it replaced caps at 300 entries, which covered 9 of 25 repos instead of 23.

## Checks

```bash
./check.sh
```

Two phases.
The first drives the real functions against fixtures with no network, covering the CI rules, the ignore and toggle logic, the sort orders and the timestamp handling.
The second loads the actual page in headless chromium against a live token and reports what each panel resolved to.

You need `chromium` on PATH and a working `gh auth`.

## Known limits

The repo list is the 25 most recently pushed that survive your ignore list, not everything you own.
The settings list pages up to 500.

Last work by you is exact whenever a branch head or a recent default-branch commit is yours, and falls back to `contributionsCollection` otherwise, which reports a whole day stamped in your account's timezone rather than your own.
So a repo where your last commit has been buried under other people's, and where you have no branch left standing, can still read a day out.

Branch heads are read 100 per repo and attributed by the tip commit's author.
Work you pushed under an email GitHub cannot match to your account is not counted as yours, and a branch whose tip someone else wrote is theirs even if you pushed it.

The Actions feed walks default-branch history plus your own PR heads.
Runs on other people's branches in your repos do not appear.
