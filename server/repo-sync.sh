#!/bin/bash
# repo.bhpanel.net: pull the newest signed repository snapshot published by
# github.com/wpexpertinbd/bhpanel-php (release "repo") and put it live.
# Runs as root from a systemd timer on the web server; writes the site's files
# as its account. Nothing is pushed to this server: it only downloads.
#
# Before anything goes live: the snapshot's sha256 must match latest.txt, its
# RPM-GPG-KEY-bhpanel must be the key with the PINNED fingerprint below, every
# repomd.xml must carry a valid signature by that key, every package its own,
# no file may be there that a signed index does not name, and the signed
# revision may never go back. Anything else is refused and the site keeps
# serving what it had.
#
# Every snapshot put live, and every one refused, is emailed to ALERT with the
# files it adds or removes - so a publish nobody made is seen at once.
# The address is not on GitHub: an account taken over there cannot silence it.
set -euo pipefail
FPR=0461071EBB7D77696E8864C7E8B11A3BA30F6EC4
REL="https://github.com/wpexpertinbd/bhpanel-php/releases/download/repo"
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
# No links, devices or FIFOs: plain files and folders only.
odd=$(cd "$W/x" && find . -mindepth 1 ! -type f ! -type d | head -3)
[ -z "$odd" ] || refuse "something that is not a plain file in the snapshot: $odd"
bad=$(cd "$W/x" && find . -mindepth 1 -type d | { grep -Ev '^\./el[0-9]+(/(x86_64|aarch64)(/(Packages|repodata))?)?$' || true; } | head -3)
[ -z "$bad" ] || refuse "unexpected folders in the snapshot: $bad"

export GNUPGHOME="$W/g"; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$W/x/RPM-GPG-KEY-bhpanel" 2>/dev/null || refuse "the snapshot's key could not be read"
got=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10}' | tr '\n' ' ')
[ "$got" = "$FPR " ] || refuse "the snapshot's key is not the pinned one ($got)"

# Every index signed by the key; together they name the only repodata files
# that may be there.
allowed="$W/allowed"; echo ./RPM-GPG-KEY-bhpanel > "$allowed"
n=0
for m in "$W"/x/el*/*/repodata/repomd.xml; do
  [ -f "$m" ] || continue
  gpg --batch --quiet --verify "$m.asc" "$m" 2>/dev/null || refuse "bad index signature: ${m#"$W"/x/}"
  d=".${m#"$W"/x}"; d=${d%/repodata/repomd.xml}
  printf '%s\n' "$d/repodata/repomd.xml" "$d/repodata/repomd.xml.asc" >> "$allowed"
  while IFS= read -r h; do
    [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] || refuse "an index names an unexpected file: $h"
    echo "$d/repodata/$h" >> "$allowed"
  done < <(grep -oE 'href="repodata/[^"]*"' "$m" | sed 's#^href="repodata/##; s#"$##')
  r=$({ grep -oE '<revision>[0-9]+</revision>' "$m" || true; } | { grep -oE '[0-9]+' || true; } | head -1)
  [[ "$r" =~ ^[0-9]+$ ]] || refuse "an index without a revision: ${m#"$W"/x/}"
  # Never back, per index: one architecture's older index must not slip in
  # under another's newer one (Codex, 2026-10-22).
  was=$({ awk -v k="$d" '$1 == k { print $2 }' "$STATE/revisions" 2>/dev/null || true; } | head -1)
  [[ "$was" =~ ^[0-9]+$ ]] || was=0
  [ "$r" -ge "$was" ] || refuse "${d#./}: its index is older than the live one (revision $r, live $was)"
  echo "$d $r" >> "$W/revisions"
  # The packages the index names: primary.xml, checked against the checksum
  # the signed repomd.xml gives it. Only these may be there (Codex: a signed
  # package no index names must not be published either).
  read -r psum phref < <(awk '/<data type="primary">/ { f = 1 }
    f && /<checksum type="sha256">/ { match($0, />[0-9a-f]{64}</); c = substr($0, RSTART + 1, 64) }
    f && /<location href=/ { match($0, /href="[^"]*"/); h = substr($0, RSTART + 6, RLENGTH - 7) }
    f && /<\/data>/ { print c, h; exit }' "$m") || true
  [[ "${psum:-}" =~ ^[0-9a-f]{64}$ && "${phref:-}" =~ ^repodata/[A-Za-z0-9._-]+$ ]] || refuse "${d#./}: its index names no package list"
  echo "$psum  $W/x/$d/$phref" | sha256sum -c --quiet >/dev/null 2>&1 || refuse "${d#./}: its package list does not match the signed index"
  case "$phref" in
    *.gz) cat_p=(gzip -dc) ;; *.zst) cat_p=(zstd -dcq) ;; *.xz) cat_p=(xz -dc) ;; *.bz2) cat_p=(bzip2 -dc) ;; *) cat_p=(cat) ;;
  esac
  while IFS= read -r ph; do
    [[ "$ph" =~ ^Packages/[A-Za-z0-9._+~-]+\.rpm$ ]] || refuse "${d#./}: its package list names an unexpected file: $ph"
    echo "$d/$ph" >> "$allowed"
  done < <("${cat_p[@]}" "$W/x/$d/$phref" | { grep -oE '<location href="[^"]*"' || true; } | sed 's#^<location href="##; s#"$##')
  n=$((n + 1))
done
[ "$n" -gt 0 ] || refuse "no repository index in the snapshot"
gpgconf --kill gpg-agent >/dev/null 2>&1 || true

# Nothing else: a file no signed index names (a .php, a page) never goes live
# (2026-10-22 audit) - packages aside, each of which must carry the key's
# signature itself.
mkdir "$W/rpmdb"
rpmkeys --dbpath "$W/rpmdb" --import "$W/x/RPM-GPG-KEY-bhpanel" || refuse "the key could not be imported for the package check"
while IFS= read -r f; do
  if [[ "$f" =~ ^\./el[0-9]+/(x86_64|aarch64)/Packages/[A-Za-z0-9._+~-]+\.rpm$ ]]; then
    grep -qxF -- "$f" "$allowed" || refuse "a package its signed index does not name: $f"
    out=$(rpmkeys --dbpath "$W/rpmdb" --checksig "$W/x/$f" 2>&1) || true
    case "$out" in *"digests signatures OK"*) ;; *) refuse "a package without a valid signature: $f";; esac
  elif ! grep -qxF -- "$f" "$allowed"; then
    refuse "a file no signed index names: $f"
  fi
done < <(cd "$W/x" && find . -type f | sort)

# Never back to an older repository: each index's signed revision only goes up
# (checked per index above), so a snapshot from before a security rebuild
# cannot be published again.

# What changes, for the alert: EVERY file added and removed.
list() { (cd "$1" 2>/dev/null && find . -type f \( -path './el*' -o -name RPM-GPG-KEY-bhpanel \) | sed 's#^\./##' | sort) || true; }
added=$(comm -13 <(list "$SITE") <(list "$W/x"))
removed=$(comm -23 <(list "$SITE") <(list "$W/x"))

# ⚠ Root's, never the site account's (2026-10-22): the account runs the
# bhpanel.net website, and a hole in it must not reach what servers install.
# The site's own folder is IMMUTABLE (chattr +i), so the account cannot swap
# it for another or a link either - and this script never unlocks it: the
# account owns its parent, and could swap the folder in that moment (Codex).
# A snapshot that needs a new top-level entry (a new index folder, a new key)
# is refused with what to do by hand.
chown -R root:root "$W/x"
find "$W/x" -type d -exec chmod 0755 {} +
find "$W/x" -type f -exec chmod 0644 {} +
top_change() { # a change to the locked folder's top level: by hand only
  refuse "it needs a change at the top of the locked $SITE - by hand: chattr -i $SITE; $*; chattr +i $SITE"
}
[ ! -L "$SITE" ] && [ -d "$SITE" ] && [ "$(stat -c %u "$SITE")" = 0 ] || refuse "$SITE is not root's own folder"
# Packages first, the indexes after them (--delay-updates puts everything in
# place at the end), so a client never reads an index naming a missing file -
# folder by folder: an index only ever names packages beside it. Old packages
# go only in a second pass, once the indexes that stop naming them are live:
# a server mid-download on the old index still finds its files (Codex).
# Anything the locked top level would need is refused BEFORE a file moves.
for d in "$W"/x/el*/; do
  [ -d "$d" ] || continue
  d=$(basename "$d")
  [ -d "$SITE/$d" ] || top_change "make $SITE/$d (root, 0755)"
done
for d in "$SITE"/el*/; do
  [ -d "$d" ] || continue
  d=$(basename "$d")
  [ -d "$W/x/$d" ] || top_change "remove $SITE/$d (the snapshot no longer has it)"
done
cmp -s "$W/x/RPM-GPG-KEY-bhpanel" "$SITE/RPM-GPG-KEY-bhpanel" ||
  top_change "replace $SITE/RPM-GPG-KEY-bhpanel with the snapshot's (a NEW KEY - check it is yours)"
for d in "$W"/x/el*/; do
  [ -d "$d" ] || continue
  d=$(basename "$d")
  rsync -a --delay-updates "$W/x/$d/" "$SITE/$d/"
done
for d in "$W"/x/el*/; do
  [ -d "$d" ] || continue
  d=$(basename "$d")
  rsync -a --delete "$W/x/$d/" "$SITE/$d/"
done
echo "$latest" > "$STATE/current.txt"
# Indexes this snapshot does not carry keep their last revision.
{ cat "$W/revisions"; awk 'NR == FNR { seen[$1] = 1; next } !($1 in seen)' "$W/revisions" "$STATE/revisions" 2>/dev/null || true; } > "$W/revisions.new"
mv -f "$W/revisions.new" "$STATE/revisions"
echo "live: $name ($n indexes)"

{
  printf 'A new signed snapshot is LIVE on repo.bhpanel.net. Servers pick it up within 6 hours.\n\n'
  printf 'Snapshot: %s\nServer: %s\nTime: %s\n\n' "$name" "$(hostname -f)" "$(date -u '+%F %T UTC')"
  printf 'Added (%s):\n%s\n\n' "$(grep -c . <<<"$added" || true)" "${added:-  (none)}"
  printf 'Removed (%s):\n%s\n\n' "$(grep -c . <<<"$removed" || true)" "${removed:-  (none)}"
  printf 'If you did not approve a publish at github.com/wpexpertinbd/bhpanel-php/actions,\ntreat the GitHub account as compromised and tell Claude at once.\n'
} | notify "new snapshot live: $name"
