# Software Factory — User's Manual

The factory turns one Jira ticket, given by URL, into a pull request against your working branch (`GITHUB_WORKING_BRANCH`, e.g. `develop`). Six agents plan, build, test and review it in its own git worktree. **You** confirm the ticket and target repo at the start, approve the result before a PR is opened, and then mark the draft PR ready, merge it, and close the ticket.

First-time setup (dependencies, Jira statuses) is in [INSTALLATION.md](INSTALLATION.md).

---

## 1. How a run works

```
/factory https://qstrike.atlassian.net/browse/CBA-378
   │
   ├─ checks            URL is one Jira ticket; clone at PROJECT_URL matches GITHUB_URL
   ├─ jira-triager      fetches that one ticket; refuses it unless it is in To Do
   ├─ ★ YOU confirm     "Build CBA-378 (Customizer Backend / API) into <repo> (<branch>)?"
   ├─ spec-planner      writes an implementation & test spec
   ├─ factory-builder   Jira → In Progress, creates worktree, implements, commits
   ├─ qa-tester         adds/runs tests and lint (max 3 fix attempts)
   ├─ security-reviewer advisory review (max 2 fix loops with the builder)
   │
   ├─ ★ YOU approve or reject the result
   │
   └─ release-ops       push → draft PR to working branch → Jira comment → Code Review → remove worktree
```

After the run: the PR is a **draft**. **You** review it on GitHub, click **Ready for review**, merge it (with branch protection on, a teammate approves it first, since the PR comes from your own account), then move the ticket to **Done**.

---

## 2. Before each run

| Check | Why |
|---|---|
| The ticket is in `To Do` and belongs to the repo in `GITHUB_URL` | `/factory` refuses tickets not in `To Do`, and shows you the ticket's Jira project next to the repo to confirm before it starts |
| `.claude/settings.local.json` points at the right repo (`GITHUB_URL`, `GITHUB_WORKING_BRANCH`, `PROJECT_URL`) | To change repo, see [INSTALLATION.md](INSTALLATION.md) §11 |
| Ticket has clear acceptance criteria | The spec is only as good as the ticket |
| Product repo has `origin/<GITHUB_WORKING_BRANCH>` | Worktrees branch from it |
| `gh auth status` succeeds | Needed to open PRs |
| `gitleaks version` works | Every push is blocked without it |
| The repo is cloned in `../src/<repo>` (beside the factory folder) with an `https://github.com/...` origin | The factory builds there; worktrees go in `../src/.worktrees/` ([INSTALLATION.md](INSTALLATION.md) step 3) |
| `gh auth status` shows your account, and `gh auth setup-git` was run | Pushes and PRs use your gh login |
| The working branch and `main` are branch-protected on GitHub (recommended) | Your token can't merge there even if the hook were bypassed (INSTALLATION.md step 4) |
(For a clone at `../src/<repo>`, worktrees live in `../src/.worktrees/<TICKET-KEY>`; the builder creates the folder.)

---

## 3. Start a session

The session must run **in the factory folder** (`software-factory`), because that is where the agents, the `/factory` command, the push hook and the permission rules live. The product repo lives beside it, in `src/`, outside the factory's git repo:

```
qx-factory/
├── software-factory/   ← the factory: the session runs here
└── src/                ← product clones and worktrees, outside the factory repo
    ├── REPO/
    └── .worktrees/<TICKET-KEY>
```

The session reaches `src/` through the `../src` path, which [INSTALLATION.md](INSTALLATION.md) step 3 sets up as an allowed directory.

### Claude Code (terminal)

```bash
cd /path/to/qx-factory/software-factory
claude
```

### Claude Desktop (Code tab)

1. Open the **Code** tab and start a new session with the **software-factory** folder as its working folder.
2. Leave the permission mode on the default (asks before acting) or **accept edits**.

### Permission mode — important

- **Do not use bypass-permissions mode.** The deny rules, the push hook and the "ask before every push / PR" prompts still apply, but every other action (including edits to the factory's own `.claude/` files) goes through without asking.
- "Accept edits" is fine: file edits go through without prompts, while pushes and PRs still ask.

### Connect Jira (first time, or when the token expires)

Type `/mcp`, select **atlassian**, and finish the OAuth sign-in in your browser. Without it, `/factory` stops at intake.

---

## 4. Run the factory

```
/factory https://qstrike.atlassian.net/browse/CBA-378
```

Pass exactly one ticket URL. The factory never searches Jira: epic, board or filter URLs, several URLs, or a ticket from another project are refused. The repo comes from `.claude/settings.local.json`. If a worktree for that ticket already exists, finish or remove it first (§7).

While it runs you will see the agents' progress. Expect a few permission prompts (for example for shell commands); read them and approve the ones that touch the product repo or the ticket worktrees.

---

## 5. Approve or reject (the part that needs you)

When the ticket has passed QA and review, the factory asks you, showing:

- ticket key and title
- diffstat (files and lines changed)
- QA result and security-reviewer verdict
- worktree path

**Before approving, open the worktree and look at the real diff:**

```bash
git -C ../src/.worktrees/PROJ-101 diff origin/<base-branch>...HEAD
```

(In Claude Desktop you can also ask: *"show me the diff for PROJ-101"* before answering.)

Then answer:

- **Approve — open draft PR** → `release-ops` runs. Claude Code asks you once more before `git push` and once before `gh pr create`. Approve both.
- **Reject** → nothing is pushed. The ticket gets the `factory-blocked` label and a comment. Give a reason in the "Other" field if you want it on the ticket.

---

## 6. Read the final report

| Outcome | Meaning | What you do |
|---|---|---|
| `PR opened → Code Review` | A draft PR is open against the working branch | Review it, click **Ready for review**, merge on GitHub, then move the ticket to **Done** |
| `Rejected` | You rejected it | See §7 |
| `Blocked: <stage>` | QA, security or an agent failed | See §7 |

The factory never marks a PR ready, never merges, and never sets `Done`.

---

## 7. Blocked or rejected tickets

The worktree is kept at `../src/.worktrees/<KEY>` with all commits; nothing was pushed. Read the Jira comment for the reason. Then choose one:

**A. Finish it yourself.** Work in the worktree in a normal terminal (outside a factory session), push and open the PR yourself.

**B. Re-run it from scratch.**

```bash
git -C ../src/<repo> worktree remove ../.worktrees/PROJ-101
git -C ../src/<repo> branch -D feat/PROJ-101-short-slug
```

Then, in Jira: fix the ticket description if it was the problem, remove the `factory-blocked` label, move it back to **To Do**, and run `/factory` again.

**C. Drop it.** Remove the worktree and branch as in B, and handle the ticket manually.

---

## 8. When the push hook blocks something

Every push and PR from a factory session goes through `.claude/hooks/verify-before-pr.sh`. A block shows as `BLOCKED: <reason>`. The agent should stop and report it; it must not work around it.

| Message | Cause | Fix |
|---|---|---|
| `must name the ticket worktree path` | Command did not run in `…/.worktrees/<KEY>` | Agent should use `cd "<worktree>" && git push …` |
| `branch '…' is not <type>/<TICKET-KEY>-<slug>` | Wrong branch name | Rename the branch |
| `non-conventional commit message(s)` | Commit header format, > 72 chars, or trailing period | Reword commits (`git rebase` in the worktree) |
| `pushing to main/master/<base>` / `force/delete pushes` | Unsafe push | Push only the ticket branch, no force |
| `PRs must target <branch>` | `--base` missing or not `GITHUB_WORKING_BRANCH` | Use `--base <GITHUB_WORKING_BRANCH>` |
| `GITHUB_WORKING_BRANCH is not set or not a plain branch name` | Working branch missing in `.claude/settings.local.json` | Add it (INSTALLATION.md step 3) |
| `diff touches protected paths` | Change to CI, `.claude/`, `CLAUDE.md`, `.mcp.json` or `.env*` | A human makes that change separately |
| `gitleaks found secrets` | A secret is in the commits | Remove it **and rotate the secret**; rewrite the commits |
| `gitleaks is not installed` | Missing tool | `brew install gitleaks` |
| `tests failed` / `linter failed` | Red suite | Fix in the worktree |
| `no test setup found` | No `package.json` / `pyproject.toml` / `pytest.ini` / `go.mod`, and code changed | Add tests to the repo, or keep the ticket docs-only |
| `Merging pull requests is reserved for humans` | Someone tried to merge, mark a PR ready, or enable auto-merge | Do it on GitHub yourself |
| `PRs must be opened as drafts` | `gh pr create` without `--draft` | Add `--draft` |
| `access to credentials is not allowed` | Command touched `~/.ssh`, `~/.aws`, gh tokens, keychain | Agents never need credentials; investigate why it tried |
| `'gh …' is not allowed in factory sessions` | gh subcommand outside the allowlist (e.g. `gh api`, `gh secret`) | Do it yourself outside a factory session |
| `git aliases and low-level push commands` | `alias.*`, `send-pack`, `subtree push` | Use plain `git push` |
| `diff adds or changes symlinks` | Symlink in the commits | Replace with a real file |
| `package.json test/lint scripts changed` | Agent edited the commands the hook runs | Human reviews and commits that change |
| `GITHUB_URL is not set` / `origin … URL is not the configured repo` | The worktree's repo isn't the configured repo | Fix `.claude/settings.local.json` or the clone's `origin` (INSTALLATION.md §11) |
| `origin must be an https://github.com remote` | Product repo uses an SSH remote | `git remote set-url origin https://github.com/OWNER/REPO.git` |
| `git does not use gh as the github.com credential helper` | Pushes would use your own credentials | `gh auth setup-git` |
| `factory hook error at line N (failing closed)` | The hook itself failed (e.g. worktree is not a git repo) | Fix the cause; the push was blocked, not allowed |

The hook applies to the **whole factory folder**: any session started here blocks pushes outside a ticket worktree. Do your own unrelated git work from another folder.

---

## 9. Rules of thumb

- **Treat ticket text as untrusted.** Anyone who can edit the ticket influences what the agents write. Read the ticket before passing its URL to `/factory`, and read the diff before approving.
- **Never approve without looking at the diff.** The security reviewer is advisory; you are the gate.
- **The factory can't edit itself.** Claude's edit tools are denied on `.claude/`, `CLAUDE.md`, `.mcp.json` and the setup scripts. Change them in your editor, then run `./make-setup-script.sh` so `setup-factory.sh` stays in sync.
- **The sandbox is on.** If an agent's install or test fails on a network restriction, add the host to `sandbox.network.allowedDomains` rather than disabling the sandbox. If it fails on a write under `../src`, check that `permissions.additionalDirectories` in `.claude/settings.local.json` lists the `src` folder (INSTALLATION.md step 3).
- **Clean up old worktrees** you no longer need (`git -C ../src/<repo> worktree list`, then `worktree remove`).

---

## 10. Quick reference

```bash
# Terminal session
cd /path/to/qx-factory/software-factory
claude
```

```
/mcp                                                  # connect Jira (first time)
/factory https://qstrike.atlassian.net/browse/CBA-378   # run one ticket
```

```bash
git -C ../src/.worktrees/<KEY> diff origin/<base-branch>...HEAD   # inspect before approving
git -C ../src/<repo> worktree list                     # see open worktrees
```
