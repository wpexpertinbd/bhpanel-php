#!/bin/bash
# repo.bhpanel.net: pull the newest signed repository snapshot published by
# github.com/wpexpertinbd/bhpanel-php (release "repo") and put it live.
# Runs as root from a systemd timer on the web server; writes the site's files
# as its account. Nothing is pushed to this server: it only downloads.
#
# Before anything goes live: the snapshot's sha256 must match latest.txt, its
# RPM-GPG-KEY-bhpanel must be the key with the PINNED fingerprint below, and
# every repomd.xml must carry a valid signature by that key. Anything else is
# refused and the site keeps serving what it had.
set -euo pipefail
FPR=0461071EBB7D77696E8864C7E8B11A3BA30F6EC4
REL="https://github.com/wpexpertinbd/bhpanel-php/releases/download/repo"
ACCT=bhpmain
SITE=/home/bhpmain/repo.bhpanel.net
STATE=/root/bhpanel-repo
install -d -m 700 "$STATE"
exec 9>"$STATE/lock"; flock -n 9 || exit 0

latest=$(curl -fsSL -m 60 "$REL/latest.txt") || { echo "latest.txt unreachable"; exit 0; }
name=${latest%% *}; sum=${latest##* }
case "$name" in repo-[0-9]*.tar.zst) ;; *) echo "unexpected snapshot name: $name"; exit 1;; esac
[[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "unexpected checksum: $sum"; exit 1; }
[ "$(cat "$STATE/current.txt" 2>/dev/null)" = "$latest" ] && exit 0

W=$(mktemp -d "$STATE/work.XXXXXX")
trap 'rm -rf "$W"' EXIT
curl -fsSL -m 900 -o "$W/$name" "$REL/$name"
echo "$sum  $W/$name" | sha256sum -c --quiet

mkdir "$W/x"
tar --zstd -xf "$W/$name" -C "$W/x" --no-same-owner --no-same-permissions
# Nothing but the repository layout: the key, elN/ARCH/{Packages,repodata}.
bad=$(cd "$W/x" && find . -mindepth 1 ! -path './RPM-GPG-KEY-bhpanel' ! -regex '\./el[0-9]+\(/[a-z0-9_]+\(/\(Packages\|repodata\)\(/[A-Za-z0-9._+~-]+\)?\)?\)?' | head -3)
[ -z "$bad" ] || { echo "unexpected paths in the snapshot: $bad"; exit 1; }
find "$W/x" -type l | grep -q . && { echo "links in the snapshot - refused"; exit 1; }

export GNUPGHOME="$W/g"; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$W/x/RPM-GPG-KEY-bhpanel"
got=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10}' | tr '\n' ' ')
[ "$got" = "$FPR " ] || { echo "the snapshot's key is not the pinned one ($got)"; exit 1; }
n=0
for m in "$W"/x/el*/*/repodata/repomd.xml; do
  gpg --batch --quiet --verify "$m.asc" "$m" 2>/dev/null || { echo "bad index signature: ${m#"$W"/x/}"; exit 1; }
  n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "no repository index in the snapshot"; exit 1; }
gpgconf --kill gpg-agent >/dev/null 2>&1 || true

chown -R "$ACCT:$ACCT" "$W/x"
find "$W/x" -type d -exec chmod 0755 {} +
find "$W/x" -type f -exec chmod 0644 {} +
# Packages first, the indexes after them (--delay-updates puts everything in
# place at the end), so a client never reads an index naming a missing file.
rsync -a --delete --delay-updates --exclude=.htaccess --exclude=index.html "$W/x/" "$SITE/"
echo "$latest" > "$STATE/current.txt"
echo "live: $name ($n indexes)"
