#!/usr/bin/env bash
# Scripts/release.sh — end-to-end mq-dir release pipeline.
#
# Usage:
#   Scripts/release.sh <version>
#
# Example:
#   Scripts/release.sh 0.1.0-alpha.9
#
# Pipeline:
#   1. Verify prereqs (xcodegen, xcodebuild, create-dmg, gh, sign_update)
#   2. Bump CFBundleShortVersionString / MARKETING_VERSION in project.yml
#   3. Build Release configuration (signed by automatic team)
#   4. Notarize via stored 'mq-dir-notary' keychain profile, then staple
#   5. Package as a .dmg via create-dmg
#   6. EdDSA-sign the .dmg with the Sparkle private key
#   7. Append a fresh <item> to docs/appcast.xml
#   8. Bump Casks/mq-dir.rb to the new version + sha256
#   9. Commit, tag, push main + tag
#  10. gh release create with the .dmg attached
#
# Anything that goes wrong before step 9 leaves the repo's working state
# uncommitted so the maintainer can rerun without unwinding pushed state.

set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
APP_NAME="mq-dir"
GH_REPO="h5nam/mq-dir"
NOTARY_PROFILE="mq-dir-notary"
TEAM_ID="WKV6T7K33K"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

KEYS_DIR="${HOME}/.config/mq-dir-release/sparkle"
PRIV_KEY="${KEYS_DIR}/ed_priv"
SPARKLE_BIN_DIR="${REPO_ROOT}/.build-tools/sparkle/bin"
# Sparkle 2.6.x renamed sign_update → sign-update; check both.
if   [[ -x "${SPARKLE_BIN_DIR}/sign-update" ]]; then
    SIGN_BIN="${SPARKLE_BIN_DIR}/sign-update"
elif [[ -x "${SPARKLE_BIN_DIR}/sign_update" ]]; then
    SIGN_BIN="${SPARKLE_BIN_DIR}/sign_update"
else
    SIGN_BIN=""
fi

APPCAST="${REPO_ROOT}/docs/appcast.xml"
CASK="${REPO_ROOT}/Casks/${APP_NAME}.rb"
PROJECT_YML="${REPO_ROOT}/project.yml"

BUILD_DIR="${REPO_ROOT}/build/release"
DERIVED="${BUILD_DIR}/derived"
DIST="${BUILD_DIR}/dist"
APP_PATH="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
DMG_PATH="${DIST}/${DMG_NAME}"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Prereqs
step "Checking prerequisites"
command -v xcodegen   >/dev/null || err "Missing xcodegen (brew install xcodegen)"
command -v xcodebuild >/dev/null || err "Missing xcodebuild (install Xcode)"
command -v create-dmg >/dev/null || err "Missing create-dmg (brew install create-dmg)"
command -v gh         >/dev/null || err "Missing gh (brew install gh)"
[[ -n "${SIGN_BIN}" && -x "${SIGN_BIN}" ]] \
    || err "Missing Sparkle sign-update under ${SPARKLE_BIN_DIR} — run Scripts/sparkle-setup.sh"

# Reject staged or unstaged changes to *tracked* files. Untracked
# scratch directories (e.g. .claude/) don't block a release because
# they don't end up in the version bump commit.
if ! git diff-index --quiet HEAD -- || ! git diff --cached --quiet; then
    err "Working tree has uncommitted changes to tracked files — commit or stash before releasing."
fi

# 2. Bump version in project.yml. Both MARKETING_VERSION (Xcode setting)
#    and CFBundleShortVersionString (Info.plist) must move together so
#    the bundle's reported version matches the appcast/tag.
#
#    Validate the version shape up front so a typo (e.g. "0.1.0alpha9"
#    missing a dash, or shell-injection-y characters) doesn't slip
#    through into commit messages, tags, or the appcast.
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] \
    || err "Bad version '${VERSION}' — expected SemVer like 1.2.3 or 1.2.3-alpha.4"

step "Bumping project.yml to ${VERSION}"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" "${PROJECT_YML}"
sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"${VERSION}\"/" "${PROJECT_YML}"
# sed silently no-ops when the pattern doesn't match. If `project.yml`
# ever gets reformatted (e.g. single-quoted values), the bump would
# vanish and we'd ship a binary whose CFBundleShortVersionString
# disagrees with the tag/appcast/DMG name. Verify both keys actually
# moved before we burn build/notary cycles on the wrong version.
grep -q "MARKETING_VERSION: \"${VERSION}\"" "${PROJECT_YML}" \
    || err "MARKETING_VERSION bump didn't take in ${PROJECT_YML} — check formatting"
grep -q "CFBundleShortVersionString: \"${VERSION}\"" "${PROJECT_YML}" \
    || err "CFBundleShortVersionString bump didn't take in ${PROJECT_YML} — check formatting"

step "Regenerating Xcode project"
xcodegen generate >/dev/null

# 3. Build Release. Uses the team configured in project.yml under
#    DEVELOPMENT_TEAM, signed by automatic provisioning.
step "Building Release configuration"
mkdir -p "${BUILD_DIR}" "${DIST}"
rm -rf "${DERIVED}"
# Force Developer ID signing for release. project.yml leaves the base
# CODE_SIGN_STYLE on Automatic so contributors don't need a paid team
# for dev builds; the override here is the *only* place we ask for the
# notarize-eligible identity.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED}" \
    -destination 'platform=macOS' \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    build
[[ -d "${APP_PATH}" ]] || err "Release build did not produce ${APP_PATH}"

# 3b. Inside-out re-sign with hardened runtime + secure timestamp +
#     explicit entitlements file (empty <dict/>, no get-task-allow).
#     xcodebuild's auto-signing inherits the Debug-style ad-hoc options
#     for SwiftPM frameworks like Sparkle, which Apple's notary then
#     rejects on three counts: nested binaries not Developer ID-signed,
#     no secure timestamp, get-task-allow injected. Signing every
#     nested .app / .framework / .xpc / .dylib bottom-up with the right
#     flags makes notarization pass cleanly.
step "Re-signing nested code with Developer ID + hardened runtime + timestamp"
SIGN_IDENTITY="Developer ID Application: Honam Kang (${TEAM_ID})"
ENTITLEMENTS="${REPO_ROOT}/Resources/Entitlements/mq-dir.entitlements"

# Pass 1: every Mach-O binary in the bundle (Sparkle ships standalone
# helper executables like `Autoupdate` with no extension that the
# bundle-pattern pass below can't see). Skip the main app's executable —
# the final bundle sign will cover it.
while IFS= read -r exec; do
    if [[ "$exec" == "${APP_PATH}/Contents/MacOS/"* ]]; then continue; fi
    if file --brief --mime-type "$exec" 2>/dev/null | grep -q application/x-mach-binary; then
        codesign --force --options runtime --timestamp \
            --sign "${SIGN_IDENTITY}" "${exec}" >/dev/null
    fi
done < <(find "${APP_PATH}" -type f)

# Pass 2: every nested bundle (framework/app/xpc/dylib), bottom-up so
# containers get signed after their contents.
while IFS= read -r item; do
    codesign --force --options runtime --timestamp \
        --sign "${SIGN_IDENTITY}" "${item}" >/dev/null
done < <(find "${APP_PATH}" -depth \( \
    -name "*.framework" -o -name "*.dylib" -o -name "*.app" -o -name "*.xpc" \
    \) ! -path "${APP_PATH}")

# Pass 3: re-sign the main app bundle with the empty entitlements file
# (no get-task-allow) and the secure timestamp.
codesign --force --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_PATH}" >/dev/null

# 4. Notarize via stored keychain profile, then staple so the bundle
#    works offline (Gatekeeper checks the stapled ticket without phoning
#    Apple).
step "Notarizing ${APP_PATH}"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.zip"
rm -f "${ZIP_PATH}"
ditto -ck --keepParent "${APP_PATH}" "${ZIP_PATH}"
xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${APP_PATH}"

# 5. DMG. Disk-image is what the cask URL points at and what Sparkle
#    downloads, so we build it after stapling so the embedded .app
#    inside the DMG has the notary ticket already attached.
step "Creating ${DMG_NAME}"
rm -f "${DMG_PATH}"
create-dmg \
    --volname "${APP_NAME}" \
    --window-size 540 380 \
    --background "${REPO_ROOT}/Resources/installer/dmg_background.png" \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 135 170 \
    --app-drop-link 385 170 \
    "${DMG_PATH}" \
    "${APP_PATH}"

# 6. Sign the DMG with our Sparkle private key. The output looks like
#    `sparkle:edSignature="…" length="…"` which we splice straight into
#    the appcast enclosure attributes.
step "Signing DMG with Sparkle EdDSA"
# Sparkle 2's sign-update reads from the macOS keychain by default;
# fall back to a file-based private key only when a backup exists.
# The output already carries `length="N"` alongside the EdDSA
# signature, so we don't add it ourselves below.
if [[ -f "${PRIV_KEY}" ]]; then
    SIG_LINE="$("${SIGN_BIN}" -f "${PRIV_KEY}" "${DMG_PATH}")"
else
    SIG_LINE="$("${SIGN_BIN}" "${DMG_PATH}")"
fi
DMG_URL="https://github.com/${GH_REPO}/releases/download/v${VERSION}/${DMG_NAME}"
PUBDATE="$(LC_TIME=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"

# 7. Inject a new <item> right above the closing </channel>. Awk handles
#    the splice so we don't need an XML toolchain in the dependency list.
#
#    EdDSA signatures are base64, but the surrounding `length="N"` and
#    attribute quoting that `sign-update` emits can contain backslashes
#    in pathological cases. `awk -v` interprets backslash escapes in
#    its argument (\n, \t, \\), so we pass everything through ENVIRON
#    instead — that path is byte-exact.
step "Updating ${APPCAST}"
TMP_APPCAST="$(mktemp)"
APPCAST_VER="${VERSION}" \
APPCAST_URL="${DMG_URL}" \
APPCAST_SIG="${SIG_LINE}" \
APPCAST_PUB="${PUBDATE}" \
awk '
BEGIN {
    ver = ENVIRON["APPCAST_VER"]
    url = ENVIRON["APPCAST_URL"]
    sig = ENVIRON["APPCAST_SIG"]
    pub = ENVIRON["APPCAST_PUB"]
}
/<\/channel>/ {
    print "    <item>"
    print "      <title>Version " ver "</title>"
    print "      <pubDate>" pub "</pubDate>"
    print "      <sparkle:version>" ver "</sparkle:version>"
    print "      <sparkle:shortVersionString>" ver "</sparkle:shortVersionString>"
    print "      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"
    print "      <enclosure url=\"" url "\" " sig " type=\"application/octet-stream\" />"
    print "    </item>"
}
{ print }
' "${APPCAST}" > "${TMP_APPCAST}"
mv "${TMP_APPCAST}" "${APPCAST}"

# Verify the splice actually landed. A regex miss on </channel>
# (whitespace/case/attribute drift) would silently leave the appcast
# unchanged and ship a release nobody can update to.
grep -q "<sparkle:version>${VERSION}</sparkle:version>" "${APPCAST}" \
    || err "Appcast splice did not produce a <sparkle:version>${VERSION}</sparkle:version> entry — inspect ${APPCAST}"
# If `xmllint` is on the path, also check the result still parses.
# Don't hard-require it — it's not in the prereq list.
if command -v xmllint >/dev/null; then
    xmllint --noout "${APPCAST}" || err "Updated ${APPCAST} fails XML parse"
fi

# 8. Bump cask version + sha256 so `brew upgrade mq-dir` picks the new DMG.
step "Updating ${CASK}"
DMG_SHA="$(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)"
sed -i '' "s/version \".*\"/version \"${VERSION}\"/" "${CASK}"
sed -i '' "s/sha256 \".*\"/sha256 \"${DMG_SHA}\"/" "${CASK}"

# 9. Commit, tag, push.
step "Committing release artifacts"
git add "${PROJECT_YML}" "${REPO_ROOT}/Sources/${APP_NAME}/Info.plist" "${APPCAST}" "${CASK}"
git commit -m "Release v${VERSION}"
git tag -a "v${VERSION}" -m "v${VERSION}"
git push origin main
git push origin "v${VERSION}"

# 10. GitHub release with the DMG attached.
#
# Notes are seeded from `git log <prev-tag>..<this-tag>` so the body lands
# with one bullet per landed commit plus a compare link, instead of the
# old "See CHANGELOG.md" placeholder. Polish on the GitHub UI if needed —
# this is a starting point, not the final story.
step "Creating GitHub release"
PREV_TAG="$(git describe --tags --abbrev=0 "v${VERSION}^" 2>/dev/null || true)"
NOTES_FILE="$(mktemp)"
trap 'rm -f "${NOTES_FILE}"' EXIT
if [[ -n "${PREV_TAG}" ]]; then
    {
        echo "## What's Changed"
        echo
        # Skip the script's own "Release vX.Y.Z" commit — it's noise to
        # readers and would otherwise sit at the top of every release.
        git log "${PREV_TAG}..v${VERSION}" --pretty=format:'- %s' \
            | grep -vE '^- Release v[0-9]'
        echo
        echo
        echo "**Full Changelog**: https://github.com/${GH_REPO}/compare/${PREV_TAG}...v${VERSION}"
    } > "${NOTES_FILE}"
else
    echo "Initial release." > "${NOTES_FILE}"
fi
gh release create "v${VERSION}" "${DMG_PATH}" \
    --repo "${GH_REPO}" \
    --title "v${VERSION}" \
    --notes-file "${NOTES_FILE}"

step "Released v${VERSION} 🎉"
echo "  - DMG:      ${DMG_PATH}"
echo "  - Appcast:  ${APPCAST}"
echo "  - Tag:      v${VERSION}"
echo
echo "GitHub Pages must serve docs/ for the appcast URL to resolve."
echo "Repo Settings → Pages → Source: Deploy from branch / main / /docs."
