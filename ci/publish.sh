#!/bin/bash
# Signs the packages a build made and publishes the whole repository as a
# snapshot on this repository's "repo" release, which repo.bhpanel.net pulls.
#
#   ci/publish.sh NEWDIR      (NEWDIR/elN/ARCH/*.rpm from the build jobs)
#
# Runs only in the protected "sign" environment (owner's approval). Needs
# RPM_SIGNING_KEY, RPM_SIGNING_FPR and GH_TOKEN in the environment.
#
# Every package's signature is checked against the PUBLIC key the way a
# server checks it, before anything is published. A snapshot is uploaded
# first and latest.txt (its name and sha256) replaced last, so a server
# reading latest.txt always finds the snapshot it names.
set -euo pipefail
NEW="${1:?directory with elN/ARCH/*.rpm}"
REPO_GH=wpexpertinbd/bhpanel-php
TAG=repo
API="https://api.github.com/repos/$REPO_GH"
: "${RPM_SIGNING_KEY:?}" "${RPM_SIGNING_FPR:?}" "${GH_TOKEN:?}"

dnf -y -q install rpm-sign createrepo_c gnupg2 zstd tar jq >/dev/null

W="$(mktemp -d)"
export GNUPGHOME="$W/gnupg"
mkdir -m 700 "$GNUPGHOME"
trap 'gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$W"' EXIT

echo "::group::signing key"
printf '%s\n' "$RPM_SIGNING_KEY" | gpg --batch --quiet --import
FPR=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
[ "$FPR" = "$RPM_SIGNING_FPR" ] || { echo "the key's fingerprint is not the recorded one"; exit 1; }
gpg --armor --export "$FPR" > "$W/RPM-GPG-KEY-bhpanel"
printf '%%_gpg_name %s\n%%_gpg_path %s\n' "$FPR" "$GNUPGHOME" > "$HOME/.rpmmacros"
mkdir "$W/rpmdb"
rpmkeys --dbpath "$W/rpmdb" --import "$W/RPM-GPG-KEY-bhpanel"
echo "fingerprint $FPR"
echo "::endgroup::"

echo "::group::current repository"
R="$W/repo"
mkdir -p "$R"
latest=$(curl -fsSL "https://github.com/$REPO_GH/releases/download/$TAG/latest.txt" 2>/dev/null || true)
if [ -n "$latest" ]; then
  name=${latest%% *}; sum=${latest##* }
  curl -fsSL -o "$W/$name" "https://github.com/$REPO_GH/releases/download/$TAG/$name"
  echo "$sum  $W/$name" | sha256sum -c --quiet
  tar --zstd -xf "$W/$name" -C "$R" --no-same-owner --no-same-permissions
  # Nothing is carried forward that a repository does not hold: a file planted
  # in the live snapshot must not ride along into every later publish
  # (2026-10-22 audit). repo-sync.sh checks the same on the server.
  odd=$(cd "$R" && find . -mindepth 1 \( ! -type f ! -type d \) -o \( -type f ! -path ./RPM-GPG-KEY-bhpanel \
        ! -regex '\./el[0-9]+/\(x86_64\|aarch64\)/Packages/[A-Za-z0-9._+~-]+\.rpm' \
        ! -regex '\./el[0-9]+/\(x86_64\|aarch64\)/repodata/[A-Za-z0-9._-]+' \) | head -3)
  [ -z "$odd" ] || { echo "the current snapshot holds something a repository does not: $odd"; exit 1; }
  echo "starting from $name"
else
  echo "no repository yet - starting empty"
fi
echo "::endgroup::"

echo "::group::sign and check"
n=0
while IFS= read -r -d '' rpm; do
  rel=${rpm#"$NEW"/}; dir=$(dirname "$rel")       # elN/ARCH
  rpmsign --addsign "$rpm" >/dev/null
  out=$(rpmkeys --dbpath "$W/rpmdb" --checksig "$rpm")
  case "$out" in *"digests signatures OK"*) ;; *) echo "BAD SIGNATURE: $out"; exit 1;; esac
  mkdir -p "$R/$dir/Packages"
  cp -f "$rpm" "$R/$dir/Packages/"
  n=$((n + 1))
done < <(find "$NEW" -name '*.rpm' -print0)
[ "$n" -gt 0 ] || { echo "no packages to publish"; exit 1; }
echo "$n packages signed and checked"
echo "::endgroup::"

echo "::group::repository index"
for d in "$R"/el*/*; do
  [ -d "$d/Packages" ] || continue
  createrepo_c --quiet --update "$d"
  rm -f "$d/repodata/repomd.xml.asc"
  gpg --batch --yes --armor --detach-sign --local-user "$FPR" -o "$d/repodata/repomd.xml.asc" "$d/repodata/repomd.xml"
  echo "$d: $(find "$d/Packages" -name '*.rpm' | wc -l) packages"
done
cp -f "$W/RPM-GPG-KEY-bhpanel" "$R/RPM-GPG-KEY-bhpanel"
echo "::endgroup::"

echo "::group::publish"
snap="repo-$(date -u +%Y%m%d%H%M%S)-${GITHUB_RUN_ID:-local}.tar.zst"
tar --zstd -cf "$W/$snap" -C "$R" .
sum=$(sha256sum "$W/$snap" | awk '{print $1}')
echo "$snap $sum" > "$W/latest.txt"

gh_api() { curl -fsS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }
rid=$(gh_api "$API/releases/tags/$TAG" 2>/dev/null | jq -r .id || true)
if [ -z "$rid" ] || [ "$rid" = null ]; then
  rid=$(gh_api -X POST "$API/releases" -d "$(jq -n --arg t "$TAG" '{tag_name:$t, name:"repo.bhpanel.net snapshots", body:"Signed package repository snapshots pulled by repo.bhpanel.net. latest.txt names the current one.", prerelease:true}')" | jq -r .id)
fi
upload() { gh_api -X POST -H "Content-Type: application/octet-stream" --data-binary @"$1" \
  "https://uploads.github.com/repos/$REPO_GH/releases/$rid/assets?name=$(basename "$1")" >/dev/null; }
assets=$(gh_api "$API/releases/$rid/assets?per_page=100")
upload "$W/$snap"
# latest.txt last: replace it only once the snapshot it names is up.
old_latest=$(jq -r '.[] | select(.name=="latest.txt") | .id' <<<"$assets")
[ -n "$old_latest" ] && gh_api -X DELETE "$API/releases/assets/$old_latest"
upload "$W/latest.txt"
# Keep the new snapshot and the one before it; older ones go.
jq -r '.[] | select(.name|startswith("repo-")) | "\(.created_at) \(.id) \(.name)"' <<<"$assets" | sort -r | tail -n +2 \
  | while read -r _ id name; do gh_api -X DELETE "$API/releases/assets/$id"; echo "removed $name"; done
echo "published $snap ($sum)"
echo "::endgroup::"
