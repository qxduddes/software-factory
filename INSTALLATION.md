# Software Factory — Installation

## 1. Scaffold the factory

Run the script in a dedicated factory directory (not inside the product repo). It skips files that already exist; pass `--force` to overwrite them:

    chmod +x setup-factory.sh && ./setup-factory.sh

## 2. Install and verify dependencies

    brew install jq gitleaks
    which jq gh gitleaks && gitleaks version && gh auth status

The push hook blocks every push if gitleaks or jq is missing.

## 3. Prepare Jira

- The workflow must have the statuses `To Do`, `In Progress`, `Code Review`, `Done`.
- Tickets are picked up only when they are `To Do` and labelled `build-ready`.
- The factory adds the label `factory-blocked` to tickets it cannot finish or you reject.

## 4. Run the pipeline

Launch `claude` in the factory directory, run `/mcp` to authenticate Atlassian via OAuth for your Jira site, then pass the Jira URL and the product repo path:

    /factory https://your-project.atlassian.net/browse/PROJ-100 /path/to/product-repo

- The product repo must have an `origin/develop1` branch.
- At most 3 tickets run per invocation (by priority, then age); the rest wait for the next run.
- Worktrees are created next to the repo, in `/path/to/.worktrees/<TICKET-KEY>`.

## 5. What you approve

1. After all tickets finish, `/factory` asks you once to **approve or reject** each ticket (diffstat, QA result, security verdict, worktree path).
2. Claude Code then asks you again before each `git push` and `gh pr create` (permission rule in `.claude/settings.json`).
3. Approved tickets get a PR against `develop1` and move to `Code Review`. **You merge the PR and move the ticket to `Done`.**

Rejected or blocked tickets keep their worktree locally; nothing is pushed.

## 6. What the push hook enforces

`.claude/hooks/verify-before-pr.sh` runs before every `git push` and `gh pr create` in this directory and blocks on:

- a push or PR that does not name a ticket worktree path (`…/.worktrees/<KEY>`);
- branch names other than `<type>/<TICKET-KEY>-<slug>`;
- commit messages outside `<type>(<TICKET-KEY>): <summary>` (types from CLAUDE.md, ≤ 72 chars, no trailing period);
- pushes to `main`/`master`/`develop1`, force or delete pushes, and PRs not targeting `--base develop1`;
- diffs touching `.github/workflows/`, `.claude/`, `CLAUDE.md`, `.mcp.json`, `.env*` (human-only);
- secrets found by gitleaks;
- failing tests or lint; a missing test setup also blocks unless the diff only touches `*.md` / `docs/`;
- any PR merge, however it is spelled.

Because the hook covers the whole factory directory, any Claude session started here blocks pushes made outside a ticket worktree.

## 7. Changing the factory

After editing any factory file (agents, command, hook, settings, CLAUDE.md, PR template, `.mcp.json`), regenerate the setup script so it does not drift:

    ./make-setup-script.sh

It rebuilds `setup-factory.sh` and verifies that a fresh scaffold reproduces every live file byte for byte.
