#!/bin/bash
# Builds Remi's scl-phpNN recipe, unchanged, inside a clean AlmaLinux container
# (9 for PHP 7.4+, 8 for 5.6-7.3 - the EL8 tree BHPanel runs them in).
#
#   ci/build.sh NN OUTDIR
#
# Lessons from building these by hand on 2026-10-21 (PHP CVE-2026-109618/109619):
#  - git.remirepo.net timed out about half the time that day: every download is
#    retried, and recipes/phpNN/ in this repository is the fallback copy;
#  - a recipe that already carries the fix is built UNCHANGED; our patch from
#    patches/phpNN/ goes in only when it does not, after Remi's last patch, with
#    release N.bhp1 - below his next N+1, so his package replaces ours;
#  - patches touching zend_vm_def.h made make regenerate the VM with whatever
#    php was on the build machine and write a broken header: the VM files the
#    patches regenerated are marked up to date after the last patch;
#  - the php.net tarball's signature is checked by the recipe itself.
set -euo pipefail
NN="${1:?php version, e.g. 85}"
OUT="${2:?output directory}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"   # absolute: the build cds away (first run lost its packages)
HERE="$(cd "$(dirname "$0")/.." && pwd)"
case "$NN" in 56|70|71|72|73) EL=8 ;; 74|80|81|82|83|84|85|86) EL=9 ;; *) echo "unknown version $NN"; exit 1 ;; esac
grep -q "release ${EL}\." /etc/redhat-release || { echo "php$NN builds on EL$EL; this is $(cat /etc/redhat-release)"; exit 1; }

dl() { curl -4 -fsS -m 90 --retry 8 --retry-delay 10 --retry-all-errors -o "$1" "$2"; }
# rpms.remirepo.net timed out too that day (remi-modular metadata): long
# timeouts, many retries, and each dnf step tried three times.
DNF=(dnf -y -q --setopt=retries=10 --setopt=timeout=120 --setopt=minrate=1)
dnf_retry() { local i; for i in 1 2 3; do "${DNF[@]}" "$@" && return 0; echo "dnf $1 failed (try $i of 3)"; sleep 30; done; return 1; }

echo "::group::build root (EL$EL)"
dnf_retry install dnf-plugins-core epel-release >/dev/null
if [ "$EL" = 9 ]; then dnf config-manager --set-enabled crb; else dnf config-manager --set-enabled powertools; fi
dl /tmp/remi-release.rpm "https://rpms.remirepo.net/enterprise/remi-release-$EL.rpm"
dnf_retry install /tmp/remi-release.rpm >/dev/null
# Only remi-safe (the -build macros) and remi (the build dependencies) are used.
dnf config-manager --set-disabled remi-modular >/dev/null 2>&1 || true
dnf_retry install rpm-build scl-utils-build "php$NN-build" gnupg2 git >/dev/null
echo "::endgroup::"

TOP="$(mktemp -d)"
mkdir -p "$TOP"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
cd "$TOP/SOURCES"

echo "::group::recipe scl-php$NN"
G="https://git.remirepo.net/cgit/rpms/scl-php$NN/php.git"
files=""
for _ in 1 2 3 4 5 6; do
  files=$(curl -4 -fsS -m 60 "$G/tree/" 2>/dev/null | grep -oE "href='/cgit/rpms/scl-php$NN/php.git/tree/[^']+'" | sed "s#.*/tree/##; s/'\$//") && [ -n "$files" ] && break
  sleep 15
done
ok=0
if [ -n "$files" ]; then
  ok=1
  for f in $files; do dl "$f" "$G/plain/$f" || { ok=0; break; }; done
fi
if [ "$ok" = 1 ]; then
  echo "from $G ($(echo "$files" | wc -w) files)"
elif [ -s "$HERE/recipes/php$NN/php.spec" ]; then
  echo "git.remirepo.net did not answer - using the copy in recipes/php$NN"
  cp -f "$HERE/recipes/php$NN/"* .
else
  echo "no recipe: git.remirepo.net did not answer and recipes/php$NN is empty"; exit 1
fi
mv -f php.spec "$TOP/SPECS/php.spec"
SPEC="$TOP/SPECS/php.spec"
UP=$(grep -m1 -E '^%global upver' "$SPEC" | awk '{print $3}')
echo "recipe for PHP $UP, $(grep -m1 '^Release:' "$SPEC")"
echo "::endgroup::"

echo "::group::patches"
if grep -qiE '^Patch[0-9]+:.*cve-2026-10961[89]' "$SPEC"; then
  echo "the recipe already carries Remi's fix: built unchanged"
elif compgen -G "$HERE/patches/php$NN/*.patch" >/dev/null; then
  n=900
  last=$(grep -nE '^%patch -P[0-9]+ ' "$SPEC" | tail -1 | cut -d: -f1)
  lastdecl=$(grep -E '^Patch[0-9]+:' "$SPEC" | tail -1)
  for p in "$HERE/patches/php$NN/"*.patch; do
    b=$(basename "$p"); cp -f "$p" "$b"
    sed -i "s|^${lastdecl}\$|${lastdecl}\nPatch${n}: ${b}|" "$SPEC"; lastdecl="Patch${n}: ${b}"
    sed -i "${last}a %patch -P${n} -p1 -b .bhp${n}" "$SPEC"; last=$((last + 1))
    echo "added Patch${n}: ${b}"; n=$((n + 1))
  done
  sed -i 's|^Release: \([0-9]*\)%{?dist}$|Release: \1.bhp1%{?dist}|' "$SPEC"
  grep -qE '^Release: [0-9]+\.bhp1' "$SPEC" || { echo "could not mark the release as ours"; exit 1; }
else
  echo "no patch of ours for php$NN"
fi
ln=$(grep -nE '^%patch -P[0-9]+ ' "$SPEC" | tail -1 | cut -d: -f1)
[ -n "$ln" ] && sed -i "${ln}a touch Zend/zend_vm_opcodes.h Zend/zend_vm_opcodes.c Zend/zend_vm_execute.h" "$SPEC"
grep -nE '^Release:|^Patch9[0-9][0-9]:|^touch Zend' "$SPEC" || true
echo "::endgroup::"

echo "::group::php.net tarball + signature (checked by the recipe)"
dl "php-$UP.tar.xz" "https://www.php.net/distributions/php-$UP.tar.xz"
dl "php-$UP.tar.xz.asc" "https://www.php.net/distributions/php-$UP.tar.xz.asc"
echo "::endgroup::"

echo "::group::build dependencies"
dnf_retry builddep --enablerepo=remi --define "scl php$NN" "$SPEC"
echo "::endgroup::"

echo "::group::rpmbuild (tests skipped: --nocheck)"
rpmbuild -bb --define "_topdir $TOP" --define "scl php$NN" --nocheck "$SPEC"
echo "::endgroup::"

mkdir -p "$OUT"
find "$TOP/RPMS" -name '*.rpm' ! -name '*-debuginfo-*' ! -name '*-debugsource-*' -exec cp -f {} "$OUT/" \;
n=$(find "$OUT" -maxdepth 1 -name "*.rpm" | wc -l)
[ "$n" -gt 0 ] || { echo "no packages were built"; exit 1; }
echo "built $n packages:"; ls "$OUT"
rpm -qp --changelog "$OUT/php$NN-php-cli-"*.rpm | head -4
