#!/usr/bin/env bash
# Creates (once) a self-signed code-signing identity in its own keychain and
# prints the keychain path. Signing every build with the same certificate keeps
# the app's designated requirement stable, so macOS keeps the Accessibility,
# Microphone and Keychain grants across rebuilds (ad-hoc signatures change on
# every build and make macOS ask again).
# The keychain holds nothing but this throwaway key, so its password is fixed.
set -euo pipefail

NAME="Flickwise Local Signing"
KC_DIR="$HOME/Library/Application Support/Flickwise/signing"
KC="$KC_DIR/flickwise-signing.keychain-db"
KC_PASS="flickwise-local-signing"

mkdir -p "$KC_DIR"
if [ ! -f "$KC" ]; then
    security create-keychain -p "$KC_PASS" "$KC" >/dev/null
    security set-keychain-settings "$KC"     # no auto-lock timeout
fi
security unlock-keychain -p "$KC_PASS" "$KC"

if ! security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
    openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/id.p12" -passout pass:flickwise >/dev/null 2>&1 \
    || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/id.p12" -passout pass:flickwise >/dev/null 2>&1
    security import "$TMP/id.p12" -k "$KC" -P flickwise -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null 2>&1 || true
fi

# codesign looks identities up through the search list, so make sure ours is on it.
if ! security list-keychains -d user | grep -q "flickwise-signing"; then
    # shellcheck disable=SC2046
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
fi
echo "$KC"
