#!/usr/bin/env bash
# Scripts/release.sh — bump version, tag, push. CI does the rest.
#
# Usage:
#   Scripts/release.sh <version>
#
# Example:
#   Scripts/release.sh 0.1.0-beta.8
#
# Pipeline (this script):
#   1. Validate version + clean tree
#   2. Bump MARKETING_VERSION + CFBundleShortVersionString in project.yml
#   3. xcodegen generate (refreshes Sources/mq-dir/Info.plist)
#   4. Commit + tag + push main + tag
#
# CI takes over from the tag push (.github/workflows/release.yml):
#   5. Build, sign, notarize, staple
#   6. Package DMG with create-dmg + Applications symlink + background
#   7. EdDSA-sign DMG with Sparkle key (from SPARKLE_ED_PRIVATE_KEY secret)
#   8. Publish GitHub release with DMG + zip + SHA256SUMS
#   9. Splice docs/appcast.xml + bump Casks/mq-dir.rb, push to main
#
# Why this is so thin: when this script also did the build, the artifacts
# it produced were silently overwritten by the parallel CI workflow's
# bare-hdiutil DMG (no Applications symlink, mismatched EdDSA signature).
# Single source of truth = CI.

set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
APP_NAME="mq-dir"
GH_REPO="h5nam/mq-dir"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

PROJECT_YML="${REPO_ROOT}/project.yml"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Prereqs.
step "Checking prerequisites"
command -v xcodegen >/dev/null || err "Missing xcodegen (brew install xcodegen)"
command -v gh       >/dev/null || err "Missing gh (brew install gh)"

# Reject staged or unstaged changes to *tracked* files. Untracked scratch
# directories (e.g. .claude/) don't block a release because they don't end
# up in the version bump commit.
if ! git diff-index --quiet HEAD -- || ! git diff --cached --quiet; then
    err "Working tree has uncommitted changes to tracked files — commit or stash before releasing."
fi

# Validate the version shape up front so a typo (e.g. "0.1.0alpha9" missing
# a dash, or shell-injection-y characters) doesn't slip through into commit
# messages, tags, or the appcast.
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] \
    || err "Bad version '${VERSION}' — expected SemVer like 1.2.3 or 1.2.3-alpha.4"

# 2. Bump version. Both MARKETING_VERSION (Xcode setting) and
#    CFBundleShortVersionString (Info.plist) must move together so the
#    bundle's reported version matches the appcast/tag.
#    CFBundleVersion is the monotonic build number Sparkle compares
#    against — it climbs by 1 each release. The appcast generator
#    in `.github/workflows/release.yml` reads this value to emit
#    `<sparkle:version>N</sparkle:version>`.
step "Bumping project.yml to ${VERSION}"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" "${PROJECT_YML}"
sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"${VERSION}\"/" "${PROJECT_YML}"

CURRENT_BUILD="$(grep -E 'CFBundleVersion: "[0-9]+"' "${PROJECT_YML}" | sed -E 's/.*CFBundleVersion: "([0-9]+)".*/\1/')"
[[ -n "${CURRENT_BUILD}" ]] || err "Couldn't read CFBundleVersion from ${PROJECT_YML} — expected an integer in double quotes."
NEXT_BUILD=$(( CURRENT_BUILD + 1 ))
sed -i '' "s/CFBundleVersion: \"[0-9]*\"/CFBundleVersion: \"${NEXT_BUILD}\"/" "${PROJECT_YML}"

# sed silently no-ops when the pattern doesn't match. If project.yml ever
# gets reformatted (e.g. single-quoted values), the bump would vanish and
# we'd ship a binary whose CFBundleShortVersionString disagrees with the
# tag/appcast/DMG name. Verify all three keys actually moved before pushing.
grep -q "MARKETING_VERSION: \"${VERSION}\"" "${PROJECT_YML}" \
    || err "MARKETING_VERSION bump didn't take in ${PROJECT_YML} — check formatting"
grep -q "CFBundleShortVersionString: \"${VERSION}\"" "${PROJECT_YML}" \
    || err "CFBundleShortVersionString bump didn't take in ${PROJECT_YML} — check formatting"
grep -q "CFBundleVersion: \"${NEXT_BUILD}\"" "${PROJECT_YML}" \
    || err "CFBundleVersion bump didn't take in ${PROJECT_YML} — check formatting"
step "CFBundleVersion ${CURRENT_BUILD} → ${NEXT_BUILD}"

# 3. Refresh Info.plist via xcodegen so the tagged commit's bundle metadata
#    matches the new MARKETING_VERSION (the .xcodeproj is gitignored, but
#    Sources/mq-dir/Info.plist is committed and CI rereads it).
step "Regenerating Xcode project"
xcodegen generate >/dev/null

# 4. Commit + tag + push. CI takes over from here.
step "Committing release bump"
git add "${PROJECT_YML}" "${REPO_ROOT}/Sources/${APP_NAME}/Info.plist"
git commit -m "Release v${VERSION}"
git tag -a "v${VERSION}" -m "v${VERSION}"

step "Pushing main and tag v${VERSION}"
git push origin main
git push origin "v${VERSION}"

step "Tag pushed — GitHub Actions will build, sign, notarize, package,"
echo "    EdDSA-sign, publish v${VERSION}, then commit appcast/cask back to main."
echo
echo "Watch progress:"
echo "  gh run watch --repo ${GH_REPO}"
echo "or open:"
echo "  https://github.com/${GH_REPO}/actions"
