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
SIGN_BIN="${REPO_ROOT}/.build-tools/sparkle/bin/sign_update"

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
[[ -x "${SIGN_BIN}" ]] || err "Missing Sparkle sign_update at ${SIGN_BIN} — run Scripts/sparkle-setup.sh"
[[ -f "${PRIV_KEY}" ]] || err "Missing Sparkle private key at ${PRIV_KEY} — run Scripts/sparkle-setup.sh"

if [[ -n "$(git status --porcelain)" ]]; then
    err "Working tree is dirty — commit or stash before releasing."
fi

# 2. Bump version in project.yml. Both MARKETING_VERSION (Xcode setting)
#    and CFBundleShortVersionString (Info.plist) must move together so
#    the bundle's reported version matches the appcast/tag.
step "Bumping project.yml to ${VERSION}"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" "${PROJECT_YML}"
sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"${VERSION}\"/" "${PROJECT_YML}"

step "Regenerating Xcode project"
xcodegen generate >/dev/null

# 3. Build Release. Uses the team configured in project.yml under
#    DEVELOPMENT_TEAM, signed by automatic provisioning.
step "Building Release configuration"
mkdir -p "${BUILD_DIR}" "${DIST}"
rm -rf "${DERIVED}"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED}" \
    -destination 'platform=macOS' \
    build >/dev/null
[[ -d "${APP_PATH}" ]] || err "Release build did not produce ${APP_PATH}"

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
    --icon "${APP_NAME}.app" 140 200 \
    --app-drop-link 400 200 \
    "${DMG_PATH}" \
    "${APP_PATH}"

# 6. Sign the DMG with our Sparkle private key. The output looks like
#    `sparkle:edSignature="…" length="…"` which we splice straight into
#    the appcast enclosure attributes.
step "Signing DMG with Sparkle EdDSA"
SIG_LINE="$("${SIGN_BIN}" -f "${PRIV_KEY}" "${DMG_PATH}")"
DMG_LENGTH="$(stat -f%z "${DMG_PATH}")"
DMG_URL="https://github.com/${GH_REPO}/releases/download/v${VERSION}/${DMG_NAME}"
PUBDATE="$(LC_TIME=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"

# 7. Inject a new <item> right above the closing </channel>. Awk handles
#    the splice so we don't need an XML toolchain in the dependency list.
step "Updating ${APPCAST}"
TMP_APPCAST="$(mktemp)"
awk -v ver="${VERSION}" -v url="${DMG_URL}" -v len="${DMG_LENGTH}" \
    -v sig="${SIG_LINE}" -v pub="${PUBDATE}" '
/<\/channel>/ {
    print "    <item>"
    print "      <title>Version " ver "</title>"
    print "      <pubDate>" pub "</pubDate>"
    print "      <sparkle:version>" ver "</sparkle:version>"
    print "      <sparkle:shortVersionString>" ver "</sparkle:shortVersionString>"
    print "      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"
    print "      <enclosure url=\"" url "\" " sig " length=\"" len "\" type=\"application/octet-stream\" />"
    print "    </item>"
}
{ print }
' "${APPCAST}" > "${TMP_APPCAST}"
mv "${TMP_APPCAST}" "${APPCAST}"

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
step "Creating GitHub release"
gh release create "v${VERSION}" "${DMG_PATH}" \
    --repo "${GH_REPO}" \
    --title "v${VERSION}" \
    --notes "See CHANGELOG.md for changes."

step "Released v${VERSION} 🎉"
echo "  - DMG:      ${DMG_PATH}"
echo "  - Appcast:  ${APPCAST}"
echo "  - Tag:      v${VERSION}"
echo
echo "GitHub Pages must serve docs/ for the appcast URL to resolve."
echo "Repo Settings → Pages → Source: Deploy from branch / main / /docs."
