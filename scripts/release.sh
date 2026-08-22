#!/usr/bin/env bash
#
# Release automation for Swift packages hosted on GitHub.
#
# Validates the repository state, runs the test suite, pushes any unpushed commits on the
# default branch, creates the annotated release tag, pushes it, and publishes a GitHub
# release with auto-generated notes.
#
# Usage:
#   scripts/release.sh <version> [--dry-run] [--skip-tests]
#
# Examples:
#   scripts/release.sh 1.0.0              # full release
#   scripts/release.sh v1.1.0 --dry-run   # show what would happen, touch nothing
#   scripts/release.sh 1.2.0 --skip-tests # trust CI and skip the local test run
#
set -euo pipefail

die() { echo "✗ $*" >&2; exit 1; }
step() { echo "→ $*"; }
done_() { echo "✓ $*"; }

DRY_RUN=false
SKIP_TESTS=false
VERSION=""

for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=true ;;
        --skip-tests) SKIP_TESTS=true ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0
            ;;
        *)
            if [[ -n "$VERSION" ]]; then die "unexpected extra argument '$argument'"; fi
            VERSION="$argument"
            ;;
    esac
done

[[ -n "$VERSION" ]] || { sed -n '2,15p' "$0" >&2; die "missing <version> argument"; }

# Accept a leading 'v' for convenience but always tag the bare form, matching existing tags.
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] \
    || die "'$VERSION' is not semantic versioning (expected e.g. 1.2.3)"

if $DRY_RUN; then echo "── dry run: nothing will be pushed, tagged or published ──"; fi

# MARK: Preflight checks

command -v gh >/dev/null || die "gh CLI not found (brew install gh)"
gh auth status >/dev/null 2>&1 || die "not authenticated with GitHub (gh auth login)"
if ! git diff --quiet || ! git diff --cached --quiet; then
    die "unstaged/staged changes present; commit or stash first"
fi
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean (untracked files?); commit, stash or ignore them"

DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)" \
    || die "could not determine the default branch (not a GitHub repo?)"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]] \
    || die "must release from '$DEFAULT_BRANCH', currently on '$CURRENT_BRANCH'"

step "fetching origin"
git fetch origin --quiet

if git merge-base --is-ancestor HEAD "origin/$DEFAULT_BRANCH" \
    && ! git merge-base --is-ancestor "origin/$DEFAULT_BRANCH" HEAD; then
    die "local '$DEFAULT_BRANCH' is behind origin; pull first"
fi
if ! git merge-base --is-ancestor "origin/$DEFAULT_BRANCH" HEAD \
    && ! git merge-base --is-ancestor HEAD "origin/$DEFAULT_BRANCH"; then
    die "local '$DEFAULT_BRANCH' diverged from origin; resolve before releasing"
fi

if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    die "tag '$VERSION' already exists locally"
fi
if git ls-remote --tags origin "refs/tags/$VERSION" | grep -q .; then
    die "tag '$VERSION' already exists on origin"
fi
if gh release view "$VERSION" >/dev/null 2>&1; then
    die "GitHub release '$VERSION' already exists"
fi

UNPUSHED="$(git rev-list --count "origin/$DEFAULT_BRANCH"..HEAD)"
done_ "preflight ok ($UNPUSHED unpushed commit(s))"

# MARK: Test

if $SKIP_TESTS; then
    echo "→ skipping tests (--skip-tests)"
else
    step "running swift test"
    $DRY_RUN || swift test
    done_ "tests passed"
fi

# MARK: Publish

run() {
    # Executes a mutating command unless this is a dry run.
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

step "pushing commits to origin/$DEFAULT_BRANCH"
if [[ "$UNPUSHED" -eq 0 ]]; then
    echo "  nothing to push"
else
    run git push origin "$DEFAULT_BRANCH"
    done_ "commits pushed"
fi

step "creating annotated tag '$VERSION'"
run git tag -a "$VERSION" -m "Release $VERSION"
run git push origin "$VERSION"
done_ "tag '$VERSION' on $(git rev-parse --short HEAD)"

step "publishing GitHub release"
run gh release create "$VERSION" --verify-tag --title "$VERSION" --generate-notes
done_ "release published"

echo
echo "Released $VERSION 🎉"
$DRY_RUN && echo "(dry run — nothing was actually done)"
echo "Consumers depending with 'from:' will resolve this version on their next update."
