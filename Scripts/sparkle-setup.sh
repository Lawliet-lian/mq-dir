#!/usr/bin/env bash
# Scripts/sparkle-setup.sh — one-time release maintainer setup.
#
# Idempotent. Run once per machine that will cut releases. Produces:
#   1. ~/.config/mq-dir-release/sparkle/  with the EdDSA key pair
#   2. .build-tools/sparkle/bin/  with sign_update + generate_keys binaries
#   3. Public-key string printed to stdout for embedding in project.yml
#      under SUPublicEDKey.
#
# After this script runs, paste the printed public key into project.yml's
# `SUPublicEDKey:` field, regenerate the project, and commit the change.
# Then `Scripts/release.sh` can produce signed releases.

set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"
SPARKLE_TARBALL_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

KEYS_DIR="${HOME}/.config/mq-dir-release/sparkle"
PRIV_KEY="${KEYS_DIR}/ed_priv"
PUB_KEY="${KEYS_DIR}/ed_pub"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="${REPO_ROOT}/.build-tools/sparkle"
TOOLS_BIN="${TOOLS_DIR}/bin"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Download Sparkle release binaries (the SwiftPM checkout doesn't ship
#    sign_update / generate_keys — those come only with the binary release).
step "Ensuring Sparkle ${SPARKLE_VERSION} binaries at ${TOOLS_DIR}"
if [[ ! -x "${TOOLS_BIN}/sign_update" || ! -x "${TOOLS_BIN}/generate_keys" ]]; then
    rm -rf "${TOOLS_DIR}"
    mkdir -p "${TOOLS_DIR}"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    curl -fL "${SPARKLE_TARBALL_URL}" -o "${TMP}/sparkle.tar.xz"
    tar -C "${TMP}" -xJf "${TMP}/sparkle.tar.xz"
    cp -R "${TMP}/bin" "${TOOLS_DIR}/bin"
fi
# Sparkle 2.6.x renamed its CLI tools (generate-keys / sign-update) and
# moved the canonical private key into the macOS keychain. Older 2.x
# tarballs still shipped the underscore names, so resolve either form.
resolve_bin() {
    local hyphen="${TOOLS_BIN}/$1" underscore="${TOOLS_BIN}/$2"
    if   [[ -x "${hyphen}"     ]]; then printf '%s\n' "${hyphen}"
    elif [[ -x "${underscore}" ]]; then printf '%s\n' "${underscore}"
    else return 1
    fi
}
GEN_KEYS_BIN="$(resolve_bin generate-keys generate_keys)" \
    || err "generate-keys missing under ${TOOLS_BIN}"
SIGN_UPDATE_BIN="$(resolve_bin sign-update sign_update)" \
    || err "sign-update missing under ${TOOLS_BIN}"

# 2. Provision the EdDSA key pair. Sparkle 2 stores the canonical private
#    key in the macOS keychain — `generate-keys` with no flags creates it
#    if absent and is a no-op if it's already there. We then export a
#    file-based backup under ~/.config so a maintainer can move to a new
#    machine without re-publishing the public key.
step "Provisioning EdDSA key pair (keychain + file backup at ${KEYS_DIR})"
mkdir -p "${KEYS_DIR}"
chmod 700 "${KEYS_DIR}"

if "${GEN_KEYS_BIN}" -p >/dev/null 2>&1; then
    echo "Existing keychain key pair detected — leaving in place."
else
    echo "No existing key pair — generating one in the keychain..."
    "${GEN_KEYS_BIN}"
fi

# Export public key (always — cheap, lets the script print it on rerun)
"${GEN_KEYS_BIN}" -p > "${PUB_KEY}"
chmod 644 "${PUB_KEY}"

# Optional file-only backup of the private key. Skip if export refuses
# (some Sparkle builds gate -x behind extra prompts); keychain is the
# primary store regardless.
if [[ ! -f "${PRIV_KEY}" ]]; then
    if "${GEN_KEYS_BIN}" -x "${PRIV_KEY}" 2>/dev/null; then
        chmod 600 "${PRIV_KEY}"
        echo "Backed up private key to ${PRIV_KEY}"
    else
        echo "(Skipped private-key file backup — Sparkle keychain remains the source of truth.)"
    fi
fi

# 3. Surface the public key for the maintainer to paste into project.yml.
step "Public EdDSA key (paste into project.yml under SUPublicEDKey)"
cat "${PUB_KEY}"
echo

# 4. Notarytool credential reminder. Stored once via:
#    xcrun notarytool store-credentials mq-dir-notary \\
#        --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
step "Reminder: notarytool credentials"
if security find-generic-password -s "com.apple.gke.notary.tool" -a "mq-dir-notary" >/dev/null 2>&1; then
    echo "Found 'mq-dir-notary' notarytool keychain profile — release.sh will use it."
else
    cat <<EOF
No 'mq-dir-notary' notarytool keychain profile found. To enable
notarization in Scripts/release.sh, run once:

  xcrun notarytool store-credentials mq-dir-notary \\
      --apple-id <your-apple-id@example.com> \\
      --team-id WKV6T7K33K \\
      --password <app-specific-password>

App-specific passwords are generated at https://appleid.apple.com/.
EOF
fi

step "Setup complete"
