#!/usr/bin/env bash
# Subscribe a GitHub repo to hyperformant/devagents.
# Usage: subscribe.sh <owner/repo> [--hooks] [--dry-run]
# Exit: 0 done or already subscribed, 2 a Claude token is needed, 1 error.
# Env: CLAUDE_CODE_OAUTH_TOKEN, DEVAGENTS_DRY_RUN=1
# Token file: $HOME/.config/devagents/claude-token
set -euo pipefail

SECRET=CLAUDE_CODE_OAUTH_TOKEN
BRANCH=devagents/subscribe
GIT_URL=https://github.com/hyperformant/devagents
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

repo="" hooks=0 dry="${DEVAGENTS_DRY_RUN:-0}"
[ "$dry" = 1 ] || dry=0
for a in "$@"; do
  case "$a" in
    --hooks) hooks=1 ;;
    --dry-run) dry=1 ;;
    -*) die "unknown option $a (usage: subscribe.sh <owner/repo> [--hooks] [--dry-run])" ;;
    *) [ -z "$repo" ] || die "unexpected argument $a"; repo="$a" ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "usage: subscribe.sh <owner/repo> [--hooks] [--dry-run]"

# 0. Tool preflight, before any network call.
need=(gh git jq)
[ "$hooks" = 0 ] || need+=(yq)
for t in "${need[@]}"; do
  command -v "$t" > /dev/null 2>&1 || {
    printf 'missing required tool: %s (install: mise use -g %s)\n' "$t" "$t" >&2
    exit 1
  }
done

# 1. Authentication.
gh auth status > /dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"

# Canonical owner/repo (GitHub is case-insensitive); everything below uses it.
canon="$(gh repo view "$repo" --json nameWithOwner -q .nameWithOwner 2> /dev/null)" \
  || die "could not resolve $repo on GitHub"
[[ "$canon" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "unexpected repository name from gh: $canon"
repo="$canon"
owner="${repo%%/*}"

# 2. Claude GitHub App (best effort; the API may be forbidden).
app_url=https://github.com/apps/claude
inst="$(gh api "orgs/$owner/installations" 2> /dev/null || gh api user/installations 2> /dev/null || true)"
if [ -z "$inst" ]; then
  echo "Could not check the Claude GitHub App; make sure it is installed: $app_url"
elif ! jq -e '.installations[]? | select(.app_slug == "claude")' <<< "$inst" > /dev/null 2>&1; then
  echo "The Claude GitHub App was not found for $owner; install it: $app_url"
fi

# 3. Secret presence (repo, or org secrets shared with the repo).
secret_present=0
if { gh api --paginate "repos/$repo/actions/secrets?per_page=100" 2> /dev/null || true; } \
  | jq -e -r --arg n "$SECRET" '.secrets[]? | select(.name == $n)' > /dev/null 2>&1; then
  secret_present=1
elif { gh api --paginate "repos/$repo/actions/organization-secrets?per_page=100" 2> /dev/null || true; } \
  | jq -e -r --arg n "$SECRET" '.secrets[]? | select(.name == $n)' > /dev/null 2>&1; then
  secret_present=1
fi

token=""
if [ "$secret_present" = 0 ]; then
  token_file="$HOME/.config/devagents/claude-token"
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    token="$CLAUDE_CODE_OAUTH_TOKEN"
  elif [ -r "$token_file" ]; then
    token="$(< "$token_file")"
  fi
  if [ -z "$token" ]; then
    echo "$SECRET is not set on $repo and no token is available." >&2
    echo "In your own terminal (not through Claude), run:"
    echo "  claude setup-token"
    # shellcheck disable=SC2016 # literal text for the user to run
    echo '  mkdir -p ~/.config/devagents && read -rs T && printf %s "$T" > ~/.config/devagents/claude-token && chmod 600 ~/.config/devagents/claude-token'
    echo "Then re-run the subscribe command."
    exit 2
  fi
fi

# 4. Shallow clone and compute the changes.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
clone="$tmp/clone"

if [ "$secret_present" = 0 ] && [ "$dry" = 0 ]; then
  printf '%s' "$token" | gh secret set "$SECRET" --repo "$repo" > /dev/null \
    || die "could not set $SECRET on $repo"
  echo "Set $SECRET on $repo"
fi

gh repo clone "$repo" "$clone" -- --depth 1 > /dev/null 2>&1 || die "could not clone $repo"
cd "$clone"
default_branch="$(git rev-parse --abbrev-ref HEAD)"

template="$SCRIPT_DIR/../templates/subscriber-workflow.yml"
[ -f "$template" ] || die "stub template missing: $template"

h="$(printf '%s' "$repo:cron" | cksum | cut -d' ' -f1)"
mkdir -p .github/workflows
sed -e "s/__CRON_MINUTE__/$((h % 60))/" -e "s/__CRON_HOUR__/$(((h / 60) % 24))/" "$template" \
  > .github/workflows/devagents.yml

notes=()
hooks_wired=0
if [ "$hooks" = 1 ]; then
  manager=""
  prepare=""
  pkg_manager=""
  if [ -f package.json ]; then
    prepare="$(jq -r '.scripts.prepare // ""' package.json)"
    if jq -e 'has("simple-git-hooks")' package.json > /dev/null; then
      pkg_manager="simple-git-hooks (package.json key)"
    elif jq -e 'has("husky")' package.json > /dev/null; then
      pkg_manager="husky (package.json key)"
    fi
  fi
  # Main config names lefthook 2.2.2 reads (docs/configuration.md, "Config file name").
  yaml_cfgs=(lefthook.yml lefthook.yaml .lefthook.yml .lefthook.yaml .config/lefthook.yml .config/lefthook.yaml)
  other_cfg=""
  for ext in toml json jsonc; do
    for pre in "" . .config/; do
      c="${pre}lefthook.$ext"
      [ -f "$c" ] && { other_cfg="$c"; break 2; }
    done
  done
  if [[ "$prepare" == *core.hooksPath* ]]; then
    manager="core.hooksPath (package.json scripts.prepare)"
  elif [[ "$prepare" == *simple-git-hooks* ]]; then
    manager="simple-git-hooks (package.json scripts.prepare)"
  elif [ -n "$pkg_manager" ]; then
    manager="$pkg_manager"
  elif [[ "$prepare" == *husky* ]]; then
    manager="husky (package.json scripts.prepare)"
  elif [ -d .husky ]; then
    manager="husky (.husky/)"
  elif [ -f .pre-commit-config.yaml ]; then
    manager="pre-commit (.pre-commit-config.yaml)"
  fi

  if [ -n "$manager" ]; then
    notes+=("This repo already manages git hooks with $manager; its hook files were not changed.")
    notes+=("To move to lefthook: add the remotes entry to a lefthook.yml, run: lefthook install --reset-hooks-path, then port the existing hooks as lefthook jobs.")
  elif [ -n "$other_cfg" ]; then
    manager="lefthook ($other_cfg, not YAML)"
    notes+=("This repo already uses lefthook with $other_cfg, which is not YAML; its hook files were not changed.")
    notes+=("To get the shared hooks, add this to $other_cfg by hand: a remotes entry with git_url $GIT_URL, ref v1, refetch_frequency 24h, configs [lefthook/devagents.yml].")
  else
    cfg=""
    for c in "${yaml_cfgs[@]}"; do
      [ -f "$c" ] && { cfg="$c"; break; }
    done
    if [ -z "$cfg" ]; then
      cfg=lefthook.yml
      cat > "$cfg" << 'YML'
remotes:
  - git_url: https://github.com/hyperformant/devagents
    ref: v1
    refetch_frequency: 24h
    configs:
      - lefthook/devagents.yml
YML
    else
      have="$(GIT_URL="$GIT_URL" yq '[.remotes[]? | select(.git_url == strenv(GIT_URL))] | length' "$cfg")"
      if [ "$have" = 0 ]; then
        GIT_URL="$GIT_URL" yq -i '.remotes += [{"git_url": strenv(GIT_URL), "ref": "v1", "refetch_frequency": "24h", "configs": ["lefthook/devagents.yml"]}]' "$cfg"
      fi
    fi
    hooks_wired=1
    if [ -f package.json ]; then
      if [[ "$prepare" != *"lefthook install"* ]]; then
        if [ -z "$prepare" ]; then
          new_prepare="lefthook install || true"
        else
          new_prepare="$prepare && (lefthook install || true)"
        fi
        jq --indent 2 --arg p "$new_prepare" '.scripts = ((.scripts // {}) + {prepare: $p})' package.json > "$tmp/package.json"
        cat "$tmp/package.json" > package.json
      fi
    else
      notes+=("No package.json: after merging, run: lefthook install")
    fi
  fi
fi

for n in ${notes[@]+"${notes[@]}"}; do echo "NOTE: $n"; done

git add -A
if git diff --cached --quiet; then
  echo "already subscribed"
  exit 0
fi

if [ "$dry" = 1 ]; then
  echo "Dry run: planned changes for $repo (nothing written)"
  git diff --cached
  exit 0
fi

# 5. Branch, commit, push; open the PR unless one is already open.
existing="$(gh pr list --repo "$repo" --head "$BRANCH" --state open --json number 2> /dev/null | jq -r '.[0].number // empty' || true)"
git config user.name > /dev/null 2>&1 || git config user.name devagents
git config user.email > /dev/null 2>&1 || git config user.email devagents@users.noreply.github.com
git checkout -q -B "$BRANCH"
git commit -q -m "chore: subscribe to hyperformant/devagents"
git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2> /dev/null || true
git push -q --force-with-lease="$BRANCH" origin "$BRANCH" || die "could not push $BRANCH"

if [ -n "$existing" ]; then
  echo "Updated PR #$existing on $BRANCH"
else
  body="Subscribes this repo to hyperformant/devagents: adds .github/workflows/devagents.yml (schedule offset derived from the repo name)."
  if [ "$hooks_wired" = 1 ]; then
    body="$body
Also wires the shared quick-check git hooks through lefthook."
  elif [ "$hooks" = 1 ]; then
    body="$body
Git hooks were not changed; migration notes were printed instead (below)."
  fi
  for n in ${notes[@]+"${notes[@]}"}; do body="$body

$n"; done
  gh pr create --repo "$repo" --head "$BRANCH" --base "$default_branch" \
    --title "Subscribe to hyperformant/devagents" --body "$body"
fi

# 6. Arm hooks in the local clone, when the cwd is one.
if [ "$hooks_wired" = 1 ]; then
  cd "$OLDPWD"
  here="$(gh repo view --json nameWithOwner -q .nameWithOwner 2> /dev/null || true)"
  if [ -n "$here" ] && [ "$(printf '%s' "$here" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ]; then
    # Without a config, `lefthook install` would create a stray lefthook.yml here.
    if ! command -v lefthook > /dev/null 2>&1; then
      echo "NOTE: install lefthook, then run: lefthook install"
    elif [ -f lefthook.yml ] || [ -f .lefthook.yml ] || [ -f lefthook.yaml ] || [ -f .lefthook.yaml ] \
      || [ -f .config/lefthook.yml ] || [ -f .config/lefthook.yaml ]; then
      lefthook install
    else
      echo "NOTE: after merging the PR and pulling, run: lefthook install"
    fi
  fi
fi
