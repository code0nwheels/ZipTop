#!/usr/bin/env bash
# Makes the self-signed certificate that CI signs every macOS build with.
#
# Run it once, keep what it writes, and store it as two repository secrets.
# Every build signed with the same certificate has the same designated
# requirement, so the login keychain recognises an updated ZipTop as the app
# it already allowed and does not ask again for its pairing token. An ad-hoc
# signature (what you get without this) is tied to the build itself, so each
# update would ask again.
#
# The certificate is not trusted by macOS and does not get past Gatekeeper;
# it only keeps the app's identity stable. A new certificate (if this one is
# lost) means everyone is asked one more time, so keep the .p12 and its
# password backed up somewhere safe. Never commit them.
#
# Usage: tool/make_macos_signing_cert.sh [output folder]
# The folder defaults to ~/ziptop-signing. Needs openssl (Git Bash, macOS
# and Linux all have one).
set -euo pipefail

out="${1:-$HOME/ziptop-signing}"
p12="$out/ziptop-signing.p12"
if [[ -e "$p12" ]]; then
  echo "$p12 already exists. Reuse it, or move it away to make a new one." >&2
  exit 1
fi
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ZipTop Self-Signed
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# 20 years: a build signed after the certificate expires would be refused.
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" \
  2> "$work/req.log" || { cat "$work/req.log" >&2; exit 1; }

password="$(openssl rand -hex 24)"
# SHA-1/3DES encryption and MAC: what macOS's `security import` reads,
# whichever openssl made the file.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -name "ZipTop Self-Signed" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout "pass:$password" -out "$p12"
# No trailing newline: the file is piped into the secret as it is.
printf '%s' "$password" > "$out/ziptop-signing.password"
cp "$work/cert.pem" "$out/ziptop-signing.cert.pem"
chmod 600 "$p12" "$out/ziptop-signing.password" 2>/dev/null || true

fingerprint="$(openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
cat <<EOF

Made $p12
  password in $out/ziptop-signing.password
  SHA-1 $fingerprint

Back up that folder, then store both as repository secrets (from the repo):

  base64 < "$p12" | tr -d '\n' | gh secret set MACOS_SIGNING_CERT_P12
  gh secret set MACOS_SIGNING_CERT_PASSWORD < "$out/ziptop-signing.password"

The macOS build then signs with it; its log shows
  designated => identifier "com.zipstreams.ziptop" and certificate root = H"$fingerprint"
EOF
