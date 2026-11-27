#!/usr/bin/env bash
# PreToolUse(Bash) gate for the Software Factory. Fails closed: exit 2 blocks the command.
# Runs on `git push` (full checks, before anything leaves the machine) and `gh pr create` (base/branch/commit checks).
set -Eeuo pipefail
# Claude Code treats any exit code other than 2 as non-blocking, so every unexpected error must become exit 2.
trap 'echo "BLOCKED: factory hook error at line $LINENO (failing closed)" >&2; exit 2' ERR

block() { echo "BLOCKED: $*" >&2; exit 2; }

INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT")
HOOK_CWD=$(jq -r '.cwd // empty' <<<"$INPUT")

# shortcut: string matching is a tripwire against mistakes, not a sandbox; scripts and encodings can evade it.
# The adversarial guarantees come from GitHub branch protection and the Claude Code sandbox.

# Merging is a human-only action, however it is spelled.
if [[ "$COMMAND" =~ gh[[:space:]]+pr[[:space:]]+merge ]] || [[ "$COMMAND" =~ pulls/[0-9]+/merge ]] || [[ "$COMMAND" =~ mergePullRequest ]] || [[ "$COMMAND" =~ markPullRequestReadyForReview ]] || [[ "$COMMAND" =~ enablePullRequestAutoMerge ]]; then
  block "Merging pull requests is reserved for humans."
fi

# Credentials: agents never read tokens, keys or keychains.
if [[ "$COMMAND" =~ (\.ssh/|\.aws/|\.config/gh|\.netrc|\.git-credentials|gh[[:space:]]+auth[[:space:]]+token|--show-token|git[[:space:]]+credential|security[[:space:]]+find-(generic|internet)-password|GH_TOKEN|GITHUB_TOKEN|printenv) ]]; then
  block "access to credentials is not allowed in factory sessions."
fi

# gh: only the read/PR-create subcommands the factory needs (gh api can merge, delete or push refs).
while read -r GH_SUB; do
  [ -z "$GH_SUB" ] && continue
  [[ "$GH_SUB" =~ ^gh[[:space:]]+(pr[[:space:]]+(create|view|list|checks|diff|status)|auth[[:space:]]+status|repo[[:space:]]+view)$ ]] \
    || block "'$GH_SUB' is not allowed in factory sessions (allowed: gh pr create/view/list/checks/diff/status, gh auth status, gh repo view)."
done < <(grep -oE '(^|[;&|(`[:space:]])gh[[:space:]]+[a-z-]+([[:space:]]+[a-z-]+)?' <<<"$COMMAND" | sed -E 's/^[;&|(`[:space:]]+//' || true)

# git aliases and low-level push commands would hide a push from the checks below.
ALIAS_RE='git[^;&|]*alias\.'
LOWLEVEL_RE='git[^;&|]*[[:space:]](send-pack|subtree[[:space:]]+push|http-push)'
if [[ "$COMMAND" =~ $ALIAS_RE ]] || [[ "$COMMAND" =~ $LOWLEVEL_RE ]]; then
  block "git aliases and low-level push commands are not allowed; use plain git push."
fi

GIT_OPTS='([[:space:]]+(-[Cc][[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)|--?[[:alnum:]][^[:space:]]*))*'
IS_PUSH=false; IS_PR=false
[[ "$COMMAND" =~ git${GIT_OPTS}[[:space:]]+push([[:space:]]|$) ]] && IS_PUSH=true
[[ "$COMMAND" =~ gh[[:space:]]+pr[[:space:]]+create ]] && IS_PR=true
$IS_PUSH || $IS_PR || exit 0

# Resolve the ticket worktree: an explicit .../.worktrees/<KEY> path in the command, else the hook's cwd.
WT=$(grep -oE "[^[:space:]\"'=]*\.worktrees/[A-Za-z0-9_-]+" <<<"$COMMAND" | head -n 1 || true)
if [ -z "$WT" ] && [[ "$HOOK_CWD" =~ \.worktrees/[A-Za-z0-9_-]+ ]]; then WT="$HOOK_CWD"; fi
[ -n "$WT" ] || block "push/PR must name the ticket worktree path (…/.worktrees/<TICKET-KEY>) explicitly, e.g. cd \"<abs-worktree>\" && git push …"
[[ "$WT" = /* ]] || WT="${HOOK_CWD:-$PWD}/$WT"
[ -d "$WT" ] || block "worktree $WT does not exist."
TARGET_DIR=$(cd "$WT" && pwd)

BRANCH=$(git -C "$TARGET_DIR" rev-parse --abbrev-ref HEAD)
TYPES='feat|fix|refactor|test|chore|docs|perf|build|ci'
KEY_RE='[A-Z][A-Z0-9_]*-[0-9]+'
[[ "$BRANCH" =~ ^($TYPES)/$KEY_RE- ]] || block "branch '$BRANCH' is not <type>/<TICKET-KEY>-<slug>."

# Pushes use your gh login over https (inside the sandbox, ssh keys are unreadable).
[[ "$(git -C "$TARGET_DIR" remote get-url --push origin)" == https://github.com/* ]] \
  || block "origin must be an https://github.com remote so pushes use your gh credentials."
git -C "$TARGET_DIR" config --get-all credential.https://github.com.helper | grep -q 'gh auth git-credential' \
  || block "git does not use gh as the github.com credential helper (run: gh auth setup-git)."

# Only the configured repo (GITHUB_URL in .claude/settings.local.json). Fetch and push URLs both,
# so neither a push nor gh pr create can be pointed at another repository.
norm_url() { local u; u=$(tr '[:upper:]' '[:lower:]' <<<"$1"); u="${u%/}"; echo "${u%.git}"; }
[ -n "${GITHUB_URL:-}" ] || block "GITHUB_URL is not set in .claude/settings.local.json (INSTALLATION.md, step 3)."
WANT=$(norm_url "$GITHUB_URL")
[ "$(norm_url "$(git -C "$TARGET_DIR" remote get-url origin)")" = "$WANT" ] \
  || block "origin fetch URL is not the configured repo $GITHUB_URL."
[ "$(norm_url "$(git -C "$TARGET_DIR" remote get-url --push origin)")" = "$WANT" ] \
  || block "origin push URL is not the configured repo $GITHUB_URL."

echo "Factory gate: verifying $TARGET_DIR ($BRANCH)" >&2
# Working branch the PRs target (GITHUB_WORKING_BRANCH in .claude/settings.local.json).
BASE="${GITHUB_WORKING_BRANCH:-}"
[[ "$BASE" =~ ^[A-Za-z0-9._/-]+$ ]] || block "GITHUB_WORKING_BRANCH is not set or not a plain branch name (INSTALLATION.md, step 3)."
git -C "$TARGET_DIR" fetch -q origin "$BASE" || block "could not fetch origin/$BASE."

# A. Conventional Commits (types from CLAUDE.md, header <= 72 chars)
BAD=$(git -C "$TARGET_DIR" log origin/$BASE..HEAD --pretty=format:%s \
  | awk -v re="^($TYPES)\\\\($KEY_RE\\\\): [a-z0-9].*[^.]$" '!($0 ~ re) || length($0) > 72' || true)
[ -z "$BAD" ] || block "non-conventional commit message(s):
$BAD
Expected: <type>(<TICKET-KEY>): <lowercase imperative summary>, <= 72 chars, no trailing period."
[ -n "$(git -C "$TARGET_DIR" log origin/$BASE..HEAD --oneline)" ] || block "no commits ahead of origin/$BASE."

if $IS_PR; then
  [[ "$COMMAND" =~ (--base|-B)[=[:space:]]+\"?"$BASE"\"?([[:space:]]|$) ]] || block "PRs must target $BASE (--base $BASE)."
  [[ "$COMMAND" =~ --head[=[:space:]]+\"?$BRANCH ]] || block "PR --head must be the worktree branch $BRANCH."
  # GitHub refuses to merge a draft; only a human marks it ready (gh pr ready and the API call are blocked above).
  [[ "$COMMAND" =~ [[:space:]](--draft|-d)([[:space:]]|$) ]] || block "PRs must be opened as drafts (--draft); you mark them ready for review on GitHub."
  echo "Factory gate passed (PR)." >&2
  exit 0
fi

# ---- git push: full checks ----
if [[ "$COMMAND" =~ (--force|--force-with-lease|[[:space:]]-f([[:space:]]|$)|--delete|[[:space:]]\+) ]]; then
  block "force/delete pushes are not allowed."
fi
if [[ "$COMMAND" =~ (^|[[:space:]:/])(main|master|"$BASE")([[:space:]\"\']|$) ]]; then
  block "pushing to main/master/$BASE is not allowed; push only the ticket branch."
fi

# B. Protected paths: CI, repo automation, agent config, package-registry config and env files are changed by humans only.
PROTECTED=$(git -C "$TARGET_DIR" diff --name-only origin/$BASE...HEAD \
  | grep -E '^\.github/|^\.gitlab-ci\.yml$|(^|/)Jenkinsfile$|^\.circleci/|^\.husky/|(^|/)\.gitmodules$|(^|/)CODEOWNERS$|^\.claude/|(^|/)CLAUDE\.md$|(^|/)\.mcp\.json$|(^|/)\.env|(^|/)\.npmrc$|(^|/)\.yarnrc(\.yml)?$|(^|/)\.pypirc$|(^|/)pip\.conf$' || true)
[ -z "$PROTECTED" ] || block "diff touches protected paths (human-only):
$PROTECTED"

# B2. No symlinks (could point a commit at files outside the repo).
SYMLINKS=$(git -C "$TARGET_DIR" diff --raw origin/$BASE...HEAD | awk '$2 == "120000" {print $NF}' || true)
[ -z "$SYMLINKS" ] || block "diff adds or changes symlinks:
$SYMLINKS"

# B3. The test/lint commands this hook runs must not be rewritten by the agents.
if [ -f "$TARGET_DIR/package.json" ]; then
  OLD_SCRIPTS=$(git -C "$TARGET_DIR" show origin/$BASE:package.json 2>/dev/null | jq -c '[.scripts.test, .scripts.lint, .scripts.pretest, .scripts.posttest]' 2>/dev/null || echo none)
  NEW_SCRIPTS=$(jq -c '[.scripts.test, .scripts.lint, .scripts.pretest, .scripts.posttest]' "$TARGET_DIR/package.json")
  [ "$OLD_SCRIPTS" = none ] || [ "$OLD_SCRIPTS" = "$NEW_SCRIPTS" ] || block "package.json test/lint scripts changed; a human must review that change."
fi

# C. Secret scan of the commits being pushed.
command -v gitleaks >/dev/null || block "gitleaks is not installed (brew install gitleaks)."
gitleaks git --no-banner --redact --log-opts="origin/$BASE..HEAD" "$TARGET_DIR" >&2 \
  || block "gitleaks found secrets in commits ahead of origin/$BASE."

# D. Tests & lint. No test setup fails closed unless the diff is docs-only (*.md / docs/).
# Hooks run outside the Claude Code sandbox, and the tests are agent-written code: run them with outbound network denied.
# shortcut: sandbox-exec is macOS-only and deprecated; elsewhere tests run unwrapped. Upgrade to a container if the factory moves off macOS.
NONET=()
command -v sandbox-exec >/dev/null && NONET=(sandbox-exec -p '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote unix-socket))(allow network-outbound (remote ip "localhost:*"))')
CODE_CHANGES=$(git -C "$TARGET_DIR" diff --name-only origin/$BASE...HEAD | grep -vE '(\.md$|^docs/)' || true)
if [ -f "$TARGET_DIR/package.json" ]; then
  CI=true ${NONET[@]+"${NONET[@]}"} npm --prefix "$TARGET_DIR" test >&2 || block "tests failed in $TARGET_DIR."
  if jq -e '.scripts.lint' "$TARGET_DIR/package.json" >/dev/null 2>&1; then
    ${NONET[@]+"${NONET[@]}"} npm --prefix "$TARGET_DIR" run lint >&2 || block "linter failed in $TARGET_DIR."
  fi
elif [ -f "$TARGET_DIR/pyproject.toml" ] || [ -f "$TARGET_DIR/pytest.ini" ]; then
  (cd "$TARGET_DIR" && ${NONET[@]+"${NONET[@]}"} pytest) >&2 || block "pytest failed in $TARGET_DIR."
elif [ -f "$TARGET_DIR/go.mod" ]; then
  (cd "$TARGET_DIR" && ${NONET[@]+"${NONET[@]}"} go test ./...) >&2 || block "go test failed in $TARGET_DIR."
elif [ -n "$CODE_CHANGES" ]; then
  block "no test setup found (package.json, pyproject.toml/pytest.ini, go.mod) and the diff is not docs-only."
fi

echo "Factory gate passed (push)." >&2
exit 0
