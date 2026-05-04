#!/usr/bin/env bash
# Creates a stable, self-signed Code Signing identity in the user's login
# keychain and trusts it for code signing. After running this once, the
# Makefile's `app` target picks it up automatically and uses
# `codesign --sign "PhotoViewer Local Signing"` instead of `--sign -` (ad-hoc).
#
# Why bother?
#   • Ad-hoc signatures change on every rebuild (code-directory hash differs),
#     so any "remember this app" consent macOS records gets invalidated.
#   • A stable identity makes Gatekeeper's per-file consent dialogs sticky
#     and lets `spctl --add` actually persist across rebuilds.
#   • This is *not* a substitute for Apple notarization; the app is still
#     unknown to Gatekeeper. But for local-only use on your own Mac it
#     gives a notarize-equivalent experience once paired with Full Disk
#     Access (System Settings → Privacy & Security → Full Disk Access).
#
# Idempotent: re-running is a no-op if the identity already exists.

set -euo pipefail

IDENTITY="PhotoViewer Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# ------------------------------------------------------------------ guard ----

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
        | grep -F "$IDENTITY" >/dev/null; then
    echo "Identity '$IDENTITY' is already installed."
    echo "Build with: make app"
    exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl not found in PATH; can't generate the certificate." >&2
    exit 1
fi

# ------------------------------------------------------------ generate cert --

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/codesign.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_codesign

[dn]
CN = PhotoViewer Local Signing
O  = PhotoViewer
OU = Local Use

[v3_codesign]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -new -nodes -newkey rsa:2048 -sha256 -days 3650 \
    -keyout "$TMP/identity.key" \
    -out    "$TMP/identity.crt" \
    -config "$TMP/codesign.cnf" \
    >/dev/null 2>&1

# Bundle key + cert into a PKCS#12 container so the keychain accepts
# both in one import. Two macOS-compatibility quirks at play:
#
#   1. macOS's `security` tool only understands the legacy PKCS#12
#      profile (SHA-1 MAC, 3DES encryption). OpenSSL 3.x defaults to
#      SHA-256 + AES, which `security` can read but can't MAC-verify.
#      We pin the older algorithms explicitly.
#
#   2. With an *empty* PKCS#12 password, OpenSSL and `security` derive
#      different MAC keys (empty-string vs NULL handling), producing a
#      "MAC verification failed (wrong password?)" error even when the
#      passwords technically match. Using a real, non-empty password
#      makes both sides agree. The password is throwaway: it only
#      protects the file for the second between creation and import,
#      after which the key is re-protected by the login keychain.
TRANSIT_PASS="photoviewer-transit"

openssl pkcs12 -export \
    -keypbe  PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg  SHA1 \
    -inkey "$TMP/identity.key" \
    -in    "$TMP/identity.crt" \
    -name  "$IDENTITY" \
    -out   "$TMP/identity.p12" \
    -passout "pass:$TRANSIT_PASS" \
    >/dev/null 2>&1

# ------------------------------------------------------------- import + trust -

echo "==> Importing identity into login keychain"
# -T pre-authorises tools so they can use the private key without a
# per-invocation password prompt (codesign + security itself).
security import "$TMP/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$TRANSIT_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

echo "==> Marking certificate as trusted for code signing (best effort)"
# `-r trustAsRoot -p codeSign` scopes the trust to *only* code signing
# performed against this exact cert; we don't trust it for SSL, S/MIME,
# or anything else.
#
# Modifying user-domain trust requires a GUI authorisation prompt
# (SecurityAgent), which most non-interactive shell sessions can't
# satisfy — it errors with errSecAuthFailed. That's fine: codesign only
# needs the cert + private key to be present in the keychain to *sign*.
# Trust is just a polish step that makes `spctl --assess` happy and
# avoids the "this cert isn't trusted" warning during signing.
TRUST_OK=1
security add-trusted-cert \
    -r trustAsRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$TMP/identity.crt" 2>/dev/null \
    || TRUST_OK=0

echo
echo "Done.  Identity '$IDENTITY' is installed."
if [ "$TRUST_OK" -eq 0 ]; then
    echo
    echo "Note: the cert isn't user-trusted yet (the keychain wouldn't grant"
    echo "      trust modifications without a GUI prompt). Codesign will"
    echo "      still happily use it — trust only matters for verification."
    echo "      To trust it interactively (one-time), run:"
    echo
    echo "        security add-trusted-cert -r trustAsRoot -p codeSign \\"
    echo "          -k \"$KEYCHAIN\" \\"
    echo "          ~/Library/Keychains/login.keychain-db"
    echo
    echo "      Or open Keychain Access, find 'PhotoViewer Local Signing',"
    echo "      double-click it, expand 'Trust', and set 'Code Signing'"
    echo "      to 'Always Trust'."
fi
echo
echo "Verify:        security find-identity -p codesigning | grep PhotoViewer"
echo "Build app:     make app"
echo "Install:       make install"
echo
echo "On the very first build, macOS will pop up a 'codesign wants to use"
echo "key in your keychain' dialog. Click 'Always Allow' — you'll never"
echo "see it again."
