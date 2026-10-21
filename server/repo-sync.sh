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
#
# Every snapshot put live, and every one refused, is emailed to ALERT with the
# packages it adds or removes - so a publish nobody made is seen at once.
# The address is not on GitHub: an account taken over there cannot silence it.
set -euo pipefail
FPR=0461071EBB7D77696E8864C7E8B11A3BA30F6EC4
REL="https://github.com/wpexpertinbd/bhpanel-php/releases/download/repo"
ACCT=bhpmain
SITE=/home/bhpmain/repo.bhpanel.net
STATE=/root/bhpanel-repo
ALERT=info@biswashost.com
install -d -m 700 "$STATE"
exec 9>"$STATE/lock"; flock -n 9 || exit 0

notify() { # subject, body (stdin)
  { printf 'To: %s\nFrom: root@%s\nSubject: [repo.bhpanel.net] %s\nContent-Type: text/plain; charset=UTF-8\n\n' \
      "$ALERT" "$(hostname -f)" "$1"; cat; } | /usr/sbin/sendmail -t -oi || echo "the alert could not be sent"
}
# A refusal is mailed once per snapshot, not every 10 minutes.
refuse() {
  echo "REFUSED: $1"
  if [ "$(cat "$STATE/refused.txt" 2>/dev/null)" != "${latest:-?}" ]; then
    printf 'A snapshot was REFUSED and NOT put live. The site keeps serving the previous one.\n\nReason: %s\nSnapshot: %s\nServer: %s\nTime: %s\n\nIf you did not publish this, treat the GitHub account wpexpertinbd as compromised.\n' \
      "$1" "${latest:-unknown}" "$(hostname -f)" "$(date -u '+%F %T UTC')" | notify "REFUSED snapshot"
    echo "${latest:-?}" > "$STATE/refused.txt"
  fi
  exit 1
}

latest=$(curl -fsSL -m 60 "$REL/latest.txt") || { echo "latest.txt unreachable"; exit 0; }
name=${latest%% *}; sum=${latest##* }
case "$name" in repo-[0-9]*.tar.zst) ;; *) refuse "unexpected snapshot name: $name";; esac
[[ "$sum" =~ ^[0-9a-f]{64}$ ]] || refuse "unexpected checksum: $sum"
[ "$(cat "$STATE/current.txt" 2>/dev/null)" = "$latest" ] && exit 0

W=$(mktemp -d "$STATE/work.XXXXXX")
trap 'rm -rf "$W"' EXIT
curl -fsSL -m 900 -o "$W/$name" "$REL/$name" || { echo "download failed, tried again later"; exit 0; }
echo "$sum  $W/$name" | sha256sum -c --quiet || refuse "the snapshot does not match its checksum"

mkdir "$W/x"
tar --zstd -xf "$W/$name" -C "$W/x" --no-same-owner --no-same-permissions || refuse "the snapshot could not be unpacked"
# Nothing but the repository layout: the key, elN/ARCH/{Packages,repodata}.
bad=$(cd "$W/x" && find . -mindepth 1 ! -path './RPM-GPG-KEY-bhpanel' ! -regex '\./el[0-9]+\(/[a-z0-9_]+\(/\(Packages\|repodata\)\(/[A-Za-z0-9._+~-]+\)?\)?\)?' | head -3)
[ -z "$bad" ] || refuse "unexpected paths in the snapshot: $bad"
find "$W/x" -type l | grep -q . && refuse "links in the snapshot"

export GNUPGHOME="$W/g"; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$W/x/RPM-GPG-KEY-bhpanel" 2>/dev/null || refuse "the snapshot's key could not be read"
got=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10}' | tr '\n' ' ')
[ "$got" = "$FPR " ] || refuse "the snapshot's key is not the pinned one ($got)"
n=0
for m in "$W"/x/el*/*/repodata/repomd.xml; do
  [ -f "$m" ] || continue
  gpg --batch --quiet --verify "$m.asc" "$m" 2>/dev/null || refuse "bad index signature: ${m#"$W"/x/}"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || refuse "no repository index in the snapshot"
gpgconf --kill gpg-agent >/dev/null 2>&1 || true

# What changes, for the alert: package files added and removed.
list() { (cd "$1" 2>/dev/null && find . -path '*/Packages/*.rpm' | sed 's#^\./##' | sort) || true; }
added=$(comm -13 <(list "$SITE") <(list "$W/x"))
removed=$(comm -23 <(list "$SITE") <(list "$W/x"))

chown -R "$ACCT:$ACCT" "$W/x"
find "$W/x" -type d -exec chmod 0755 {} +
find "$W/x" -type f -exec chmod 0644 {} +
# Packages first, the indexes after them (--delay-updates puts everything in
# place at the end), so a client never reads an index naming a missing file.
rsync -a --delete --delay-updates --exclude=.htaccess --exclude=index.html "$W/x/" "$SITE/"
echo "$latest" > "$STATE/current.txt"
echo "live: $name ($n indexes)"

{
  printf 'A new signed snapshot is LIVE on repo.bhpanel.net. Servers pick it up within 6 hours.\n\n'
  printf 'Snapshot: %s\nServer: %s\nTime: %s\n\n' "$name" "$(hostname -f)" "$(date -u '+%F %T UTC')"
  printf 'Added (%s):\n%s\n\n' "$(grep -c . <<<"$added" || true)" "${added:-  (none)}"
  printf 'Removed (%s):\n%s\n\n' "$(grep -c . <<<"$removed" || true)" "${removed:-  (none)}"
  printf 'If you did not approve a publish at github.com/wpexpertinbd/bhpanel-php/actions,\ntreat the GitHub account as compromised and tell Claude at once.\n'
} | notify "new snapshot live: $name"
