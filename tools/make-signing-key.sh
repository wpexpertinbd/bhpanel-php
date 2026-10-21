#!/bin/bash
# Makes BHPanel's package signing key ON THIS MAC, once.
#
#   - the key is generated in a throw-away GnuPG home that is deleted at the end
#   - the private key goes straight into GitHub: secret RPM_SIGNING_KEY of the
#     protected environment "sign" (needs the owner's approval to be used),
#     piped - never written to disk in the clear
#   - an ENCRYPTED backup is written to ~/BHPanel-keys/package-signing/, with a
#     passphrase you choose; it is test-decrypted before anything is deleted
#   - only the fingerprint and the PUBLIC key are printed
#
# Whoever holds this key can publish packages every BHPanel server installs
# as root. Keep the backup and its passphrase apart (e.g. backup file on a USB
# stick or Google Drive, passphrase in your password manager).
set -euo pipefail
REPO=wpexpertinbd/bhpanel-php
ENV=sign
OUT="$HOME/BHPanel-keys/package-signing"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v gpg >/dev/null || die "gpg is not installed (brew install gnupg)"
command -v gh  >/dev/null || die "gh is not installed (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
[ -e "$OUT/public.asc" ] && die "a key already exists in $OUT - this never makes a second one"
gh api "repos/$REPO/environments/$ENV" --jq '.protection_rules[].type' 2>/dev/null | grep -q required_reviewers \
  || die "the '$ENV' environment of $REPO has no approval rule - not putting a key there"

umask 077
mkdir -p "$OUT"
G=$(mktemp -d)
export GNUPGHOME="$G"
cleanup() { gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$G"; }
trap cleanup EXIT

echo "== 1. generating the key (RSA 4096) in a throw-away GnuPG home"
cat > "$G/params" <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: BHPanel Package Signing
Name-Email: packages@bhpanel.net
Expire-Date: 0
%commit
EOF
gpg --batch --quiet --gen-key "$G/params"
FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
[ ${#FPR} = 40 ] || die "could not read the new key's fingerprint"

echo "== 2. private key -> GitHub ($REPO, environment '$ENV')"
gpg --armor --export-secret-keys "$FPR" | gh secret set RPM_SIGNING_KEY --env "$ENV" --repo "$REPO"
gh secret set RPM_SIGNING_FPR --env "$ENV" --repo "$REPO" --body "$FPR"
gh secret list --env "$ENV" --repo "$REPO" | grep -q '^RPM_SIGNING_KEY' || die "the secret is not in GitHub"

echo "== 3. encrypted backup"
while :; do
  read -r -s -p "   Backup passphrase (min 12 characters): " P1; echo
  read -r -s -p "   Again: " P2; echo
  [ "$P1" = "$P2" ] && [ ${#P1} -ge 12 ] && break
  echo "   They differ or are too short - again."
done
gpg --armor --export-secret-keys "$FPR" \
  | gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 --armor \
        -o "$OUT/private-backup.asc.gpg" 3<<<"$P1"
# Prove the backup opens with that passphrase and holds this key.
T=$(mktemp -d)
gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --decrypt "$OUT/private-backup.asc.gpg" 3<<<"$P1" \
  | GNUPGHOME="$T" gpg --batch --quiet --import 2>/dev/null
GOT=$(GNUPGHOME="$T" gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
GNUPGHOME="$T" gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$T"
unset P1 P2
[ "$GOT" = "$FPR" ] || die "the backup did not decrypt to this key - nothing was deleted: $OUT"

echo "== 4. public key"
gpg --armor --export "$FPR" > "$OUT/public.asc"
echo "$FPR" > "$OUT/fingerprint.txt"
cat > "$OUT/README.txt" <<EOF
BHPanel package signing key - made $(date -u +%Y-%m-%dT%H:%MZ) on $(hostname -s)
fingerprint:  $FPR
public.asc:   the public key (goes into the BHPanel daemon; not secret)
private-backup.asc.gpg: the PRIVATE key, encrypted (AES256) with the passphrase you chose.
The live copy is the GitHub secret RPM_SIGNING_KEY of $REPO, environment '$ENV'
(used only after your approval). Keep this backup and its passphrase apart.
EOF
chmod 600 "$OUT"/*

echo
echo "Done. Fingerprint: $FPR"
echo "Files: $OUT (public.asc, fingerprint.txt, private-backup.asc.gpg, README.txt)"
echo
cat "$OUT/public.asc"
