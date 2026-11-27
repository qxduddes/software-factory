# Software Factory — Installation

Day-to-day usage in Claude Code (terminal) and Claude Desktop is in [USER_MANUAL.md](USER_MANUAL.md).

## 1. Scaffold the factory

Run the script in the factory directory (`software-factory`). It skips files that already exist; pass `--force` to overwrite them:

    chmod +x setup-factory.sh && ./setup-factory.sh

The factory and the product repo sit side by side under one parent folder. Only the factory is a git repo; `src/` is kept out of it:

    qx-factory/
    ├── software-factory/   ← this factory (the Claude session runs here)
    └── src/                ← product clones and their worktrees (outside the factory repo)

## 2. Install and verify dependencies

    brew install jq gitleaks
    which jq gh gitleaks && gitleaks version && gh auth status

The push hook blocks every push if gitleaks or jq is missing.

## 3. Configure GitHub and the target repo

Pushes and PRs run as **your own GitHub account** (through `gh`). The factory never merges: the hook blocks merge commands, marking PRs ready and auto-merge, and every PR is opened as a draft.

1. Log in and make git use gh for github.com credentials (once per machine):

       gh auth login --hostname github.com --git-protocol https
       gh auth setup-git

2. From the factory folder, clone the target repo into `../src/` (beside the factory, not inside it), from your own terminal, using its `https://github.com/...` URL (the hook checks this):

       git clone https://github.com/OWNER/REPO.git ../src/REPO

   `git clone` creates `src/` if it is missing. Because `src/` is outside the factory repo, the product code can never be committed to it. Ticket worktrees are created next to the clone, in `../src/.worktrees/<TICKET-KEY>`.
3. Create `.claude/settings.local.json` in the factory directory. This is **the one place that says which repo the factory builds**: per machine, not committed, and agents cannot edit it. See §11 to switch repos.

   ```json
   {
     "enabledMcpjsonServers": ["atlassian"],
     "env": {
       "GITHUB_URL": "https://github.com/OWNER/REPO",
       "GITHUB_WORKING_BRANCH": "develop",
       "PROJECT_URL": "/Users/<you>/Work/projects/qx-factory/src/REPO"
     }
   }
   ```

   - `GITHUB_URL`: the GitHub repo. The push hook refuses any push or PR whose `origin` (fetch or push URL) is a different repo.
   - `GITHUB_WORKING_BRANCH`: the branch worktrees start from and PRs target. It must exist on `origin`. The push hook blocks PRs with any other `--base`, and pushes to this branch, `main` or `master`.
   - `PROJECT_URL`: the **local path** of your clone (not a URL). `/factory` checks its `origin` matches `GITHUB_URL` and refuses the factory folder itself.
   - `src/` is outside the factory folder, so it must be added as a directory the session may use. Add it to the same file. This one entry gives both the file tools and the Bash sandbox write access, so `git worktree add`, installs and tests under `src/` work:

   ```json
   {
     "permissions": { "additionalDirectories": ["/Users/<you>/Work/projects/qx-factory/src"] }
   }
   ```

If pushes fail with a credential error inside the sandbox (the macOS keychain may be unreachable from it), tell Claude; don't disable the sandbox.

## 4. Protect the branches on GitHub (recommended)

The hook blocks merges and direct pushes, but your token itself can merge. GitHub branch protection closes that from the server side. Run once per repo, in your own terminal (not in a factory session: the hook blocks `gh api` there), as a repo admin:

```bash
for B in develop main; do   # use your GITHUB_WORKING_BRANCH instead of develop
gh api -X PUT "repos/OWNER/REPO/branches/$B/protection" --input - <<'EOF'
{"required_status_checks": null, "enforce_admins": false,
 "required_pull_request_reviews": {"required_approving_review_count": 1},
 "restrictions": null, "allow_force_pushes": false, "allow_deletions": false}
EOF
done
```

This requires a PR with one approval and blocks force pushes and deletions. The PRs come from your own account, so you can't approve them yourself: a teammate approves, or, with `enforce_admins: false`, a repo admin can merge past the rule in the GitHub UI.

## 5. Sandbox

`.claude/settings.json` turns on the Claude Code sandbox for every Bash command (including subagents): writes are limited to the factory folder plus `../src` (added as an additional directory in step 3), credential files are unreadable, and network access is limited to GitHub and the npm/PyPI/Go registries. Commands cannot opt out of it.

- If tests or installs need another host, add it to `sandbox.network.allowedDomains`.
- The push hook itself runs outside the sandbox; it runs the tests with outbound network denied (`sandbox-exec`).
- If `git worktree add` fails inside the sandbox, run the command `/factory` shows you in your own terminal.

## 6. Prepare Jira

- The workflow must have the statuses `To Do`, `In Progress`, `Code Review`, `Done`.
- The factory never searches Jira: it builds only the ticket whose URL you pass to `/factory`, and only if that ticket is in `To Do`. Before touching Jira or git, it shows the ticket's Jira project next to `GITHUB_URL` and the working branch, and waits for you to confirm.
- The factory adds the label `factory-blocked` to tickets it cannot finish or you reject.

## 7. Run the pipeline

Launch `claude` in the factory directory, run `/mcp` to authenticate Atlassian via OAuth for your Jira site, then pass one ticket URL:

    /factory https://qstrike.atlassian.net/browse/CBA-378

- One ticket per run. The repo comes from `.claude/settings.local.json`, not from the command.
- The clone must have the branch `origin/<GITHUB_WORKING_BRANCH>`.

## 8. What you approve

1. At the start, you confirm the ticket's Jira project against the target repo and branch.
2. When the ticket has passed QA and review, `/factory` asks you to **approve or reject** it (diffstat, QA result, security verdict, worktree path).
3. Claude Code then asks you again before each `git push` and `gh pr create` (permission rule in `.claude/settings.json`).
4. An approved ticket gets a **draft** PR against the working branch and moves to `Code Review`. GitHub can't merge a draft, and the factory is blocked from marking it ready. **You review it, click "Ready for review", merge it on GitHub, and move the ticket to `Done`.**

A rejected or blocked ticket keeps its worktree locally; nothing is pushed.

## 9. What the push hook enforces

`.claude/hooks/verify-before-pr.sh` runs before every `git push` and `gh pr create` in this directory and blocks on:

- a push or PR to any repo other than `GITHUB_URL`, or not over an https remote with gh as the git credential helper;
- a push or PR that does not name a ticket worktree path (`…/.worktrees/<KEY>`);
- branch names other than `<type>/<TICKET-KEY>-<slug>`;
- commit messages outside `<type>(<TICKET-KEY>): <summary>` (types from CLAUDE.md, ≤ 72 chars, no trailing period);
- pushes to `main`/`master`/the working branch, force or delete pushes, and PRs not targeting `--base <GITHUB_WORKING_BRANCH>`;
- any PR not opened as a draft; any merge, marking a PR ready for review, or enabling auto-merge, however it is spelled;
- diffs touching protected paths (human-only): all of `.github/`, other CI configs, `.husky/`, `.gitmodules`, `CODEOWNERS`, `.claude/`, `CLAUDE.md`, `.mcp.json`, `.env*`, and package-registry configs (`.npmrc`, `.yarnrc`, `.pypirc`, `pip.conf`);
- symlinks in the diff, and changes to the `package.json` test/lint scripts;
- secrets found by gitleaks;
- failing tests or lint; a missing test setup also blocks unless the diff only touches `*.md` / `docs/`;
- credential access (`~/.ssh`, `~/.aws`, gh tokens, `GH_TOKEN`, keychain), `gh` subcommands outside a small allowlist, git aliases and low-level push commands;
- its own errors and timeouts (it fails closed).

A second hook, `.claude/hooks/atlassian-scope.sh`, runs before every Atlassian tool call: reads pass; the only writes allowed are status changes (builder), status changes and comments (release-ops), and status changes, comments and the blocked label (the `/factory` session).

Because the hook covers the whole factory directory, any Claude session started here blocks pushes made outside a ticket worktree.

## 10. Changing the factory

The factory's own files (`.claude/`, `CLAUDE.md`, `.mcp.json`, `setup-factory.sh`, `make-setup-script.sh`) are denied to Claude's edit tools in `.claude/settings.json`, so no agent can weaken them. To change the factory, edit the files in your editor, or temporarily remove the `Edit(...)` deny rules for a maintenance session and put them back afterwards.

Then regenerate the setup script so it does not drift, and **commit** the factory files so a `git restore` can't silently roll them back:

    ./make-setup-script.sh

It rebuilds `setup-factory.sh` and verifies that a fresh scaffold reproduces every live file byte for byte.

## 11. Switch to another repo

The factory builds one repo at a time. To point it at another:

1. Clone it into `../src/` (step 3.2), with its `https://github.com/...` URL.
2. In your editor, change `env.GITHUB_URL`, `env.GITHUB_WORKING_BRANCH` and `env.PROJECT_URL` in `.claude/settings.local.json`.
3. Make sure your account has write access to the repo, and apply branch protection (step 4).
4. Check the repo's Jira project workflow has `To Do`, `In Progress`, `Code Review`, `Done`.
5. Start a **new** Claude session in the factory folder.

Finish or remove any open worktrees of the old repo first.

## 12. Atlassian endpoint (before 2027-03-01)

`.mcp.json` uses `https://mcp.atlassian.com/v1/mcp`, which Atlassian removes on **2027-03-01**. Change only the URL to `https://mcp.atlassian.com/v2/mcp`, then `/mcp` → **atlassian** → Authenticate. **Keep the server name `atlassian`**: the Atlassian hook and the agents' tool lists depend on it. Keep the claude.ai Atlassian connector out of factory sessions, since the hook doesn't cover it.
