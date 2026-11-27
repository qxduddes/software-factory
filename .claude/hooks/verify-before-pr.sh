#!/usr/bin/env bash
# PreToolUse(Bash) gate for the Software Factory. Fails closed: exit 2 blocks the command.
# Runs on `git push` (full checks, before anything leaves the machine) and `gh pr create` (base/branch/commit checks).
set -euo pipefail

block() { echo "BLOCKED: $*" >&2; exit 2; }

INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT")
HOOK_CWD=$(jq -r '.cwd // empty' <<<"$INPUT")

# Merging is a human-only action, however it is spelled.
if [[ "$COMMAND" =~ gh[[:space:]]+pr[[:space:]]+merge ]] || [[ "$COMMAND" =~ pulls/[0-9]+/merge ]]; then
  block "Merging pull requests is reserved for humans."
fi

IS_PUSH=false; IS_PR=false
[[ "$COMMAND" =~ git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push ]] && IS_PUSH=true
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

echo "Factory gate: verifying $TARGET_DIR ($BRANCH)" >&2
git -C "$TARGET_DIR" fetch -q origin develop1 || block "could not fetch origin/develop1."

# A. Conventional Commits (types from CLAUDE.md, header <= 72 chars)
BAD=$(git -C "$TARGET_DIR" log origin/develop1..HEAD --pretty=format:%s \
  | awk -v re="^($TYPES)\\\\($KEY_RE\\\\): [a-z0-9].*[^.]$" '!($0 ~ re) || length($0) > 72' || true)
[ -z "$BAD" ] || block "non-conventional commit message(s):
$BAD
Expected: <type>(<TICKET-KEY>): <lowercase imperative summary>, <= 72 chars, no trailing period."
[ -n "$(git -C "$TARGET_DIR" log origin/develop1..HEAD --oneline)" ] || block "no commits ahead of origin/develop1."

if $IS_PR; then
  [[ "$COMMAND" =~ (--base|-B)[=[:space:]]+develop1([[:space:]]|$) ]] || block "PRs must target develop1 (--base develop1)."
  [[ "$COMMAND" =~ --head[=[:space:]]+\"?$BRANCH ]] || block "PR --head must be the worktree branch $BRANCH."
  echo "Factory gate passed (PR)." >&2
  exit 0
fi

# ---- git push: full checks ----
if [[ "$COMMAND" =~ (--force|--force-with-lease|[[:space:]]-f([[:space:]]|$)|--delete|[[:space:]]\+) ]]; then
  block "force/delete pushes are not allowed."
fi
if [[ "$COMMAND" =~ (^|[[:space:]:])(main|master|develop1)([[:space:]]|$) ]]; then
  block "pushing to main/master/develop1 is not allowed; push only the ticket branch."
fi

# B. Protected paths: CI, agent config and env files are changed by humans only.
PROTECTED=$(git -C "$TARGET_DIR" diff --name-only origin/develop1...HEAD \
  | grep -E '^\.github/workflows/|^\.claude/|(^|/)CLAUDE\.md$|(^|/)\.mcp\.json$|(^|/)\.env' || true)
[ -z "$PROTECTED" ] || block "diff touches protected paths (human-only):
$PROTECTED"

# C. Secret scan of the commits being pushed.
command -v gitleaks >/dev/null || block "gitleaks is not installed (brew install gitleaks)."
gitleaks git --no-banner --redact --log-opts="origin/develop1..HEAD" "$TARGET_DIR" >&2 \
  || block "gitleaks found secrets in commits ahead of origin/develop1."

# D. Tests & lint. No test setup fails closed unless the diff is docs-only (*.md / docs/).
CODE_CHANGES=$(git -C "$TARGET_DIR" diff --name-only origin/develop1...HEAD | grep -vE '(\.md$|^docs/)' || true)
if [ -f "$TARGET_DIR/package.json" ]; then
  CI=true npm --prefix "$TARGET_DIR" test >&2 || block "tests failed in $TARGET_DIR."
  if jq -e '.scripts.lint' "$TARGET_DIR/package.json" >/dev/null 2>&1; then
    npm --prefix "$TARGET_DIR" run lint >&2 || block "linter failed in $TARGET_DIR."
  fi
elif [ -f "$TARGET_DIR/pyproject.toml" ] || [ -f "$TARGET_DIR/pytest.ini" ]; then
  (cd "$TARGET_DIR" && pytest) >&2 || block "pytest failed in $TARGET_DIR."
elif [ -f "$TARGET_DIR/go.mod" ]; then
  (cd "$TARGET_DIR" && go test ./...) >&2 || block "go test failed in $TARGET_DIR."
elif [ -n "$CODE_CHANGES" ]; then
  block "no test setup found (package.json, pyproject.toml/pytest.ini, go.mod) and the diff is not docs-only."
fi

echo "Factory gate passed (push)." >&2
exit 0
