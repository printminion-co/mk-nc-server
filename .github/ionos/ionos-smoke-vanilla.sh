#!/usr/bin/env bash
# Downloads the vanilla OFFICIAL archive of a base release and verifies it (the starting point of the upgrade smoke
# test, 07-validation.md "Upgrade from"):
#   ionos-smoke-vanilla.sh <base release, for example 33.0.9> <output folder>
# The output folder must not exist or must be empty (a download is untrusted data: it gets its own fresh folder).
# It then holds nextcloud-<base>.zip, its .sha256 and its .asc; the last line printed is the path of the zip.
#
# TRUST MODEL
#   - SHA-256: the checksum file comes from the same host as the archive, so it only catches a corrupt or truncated
#     download. It says nothing about a tampered host. (The published file lists the zip and the .metadata file, so
#     the line of the zip is picked out by name.)
#   - Signature: nextcloud-<base>.zip.asc is checked with gpg against the Nextcloud release key
#     (Nextcloud Security <security@nextcloud.com>) that is COMMITTED to this repository
#     (ionos-nextcloud-release-key.asc) in a throw-away GNUPGHOME, and the primary key of the signature must have the
#     pinned fingerprint. Key and fingerprint do not come from the download host, so this is the check that
#     catches a tampered archive. Changing the key is a reviewed commit. (nextcloud.com/nextcloud.asc and the
#     fingerprint on https://nextcloud.com/security/ agree with it.)
#
# Environment (defaults are the real ones; the tests point them at local fixtures and a throw-away key):
#   VANILLA_URL        the folder with the archives, default https://download.nextcloud.com/server/releases
#                      (only https:// and file:// are accepted)
#   NC_RELEASE_KEY     the public key file, default ionos-nextcloud-release-key.asc next to this script
#   NC_RELEASE_KEY_FPR the pinned fingerprint of its primary key, default 28806A878AE423A28372792ED75899B9A724937A
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-smoke
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

[ $# -eq 2 ] || die "usage: ionos-smoke-vanilla.sh <base release> <output folder>"
BASE=$1
OUT=$2
[[ $BASE =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$BASE' is not a base release like 33.0.9"
URL=${VANILLA_URL:-https://download.nextcloud.com/server/releases}
URL=${URL%/}
case "$URL" in https://*|file://*) ;; *) die "VANILLA_URL must start with https:// or file://" ;; esac
KEY=${NC_RELEASE_KEY:-$HERE/ionos-nextcloud-release-key.asc}
FPR=${NC_RELEASE_KEY_FPR:-28806A878AE423A28372792ED75899B9A724937A}
[[ $FPR =~ ^[0-9A-F]{40}$ ]] || die "the pinned fingerprint is not 40 upper case hex digits"
[ -f "$KEY" ] || die "no release key at $KEY"
command -v gpg >/dev/null || die "gpg is needed to check the signature of the official archive"

if [ -e "$OUT" ]; then
  if [ ! -d "$OUT" ] || [ -n "$(ls -A "$OUT")" ]; then die "$OUT exists and is not an empty folder"; fi
fi
mkdir -p "$OUT"
NAME="nextcloud-$BASE.zip"

fetch() { # fetch <file name>
  curl -sSfL --retry 3 --retry-delay 5 --max-time 1800 -o "$OUT/$1" "$URL/$1" || die "could not download $URL/$1"
}
log "downloading $URL/$NAME"
start=$SECONDS
fetch "$NAME"
fetch "$NAME.sha256"
fetch "$NAME.asc"
log "downloaded $NAME ($(du -h "$OUT/$NAME" | cut -f1)) in $((SECONDS - start)) s"

# checksum: the line of the zip, by exact file name
want=$(awk -v n="$NAME" '$2 == n || $2 == "*" n { print $1 }' "$OUT/$NAME.sha256" | head -n1)
[[ $want =~ ^[0-9a-f]{64}$ ]] || die "$NAME.sha256 has no SHA-256 line for $NAME"
have=$(sha256sum "$OUT/$NAME" | cut -d' ' -f1)
[ "$have" = "$want" ] || die "the SHA-256 of $NAME is $have, the published file says $want (a corrupt download; the same host cannot prove more)"
log "sha256 ok ($have)"

# signature
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
chmod 700 "$GNUPGHOME"
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --batch --quiet --import "$KEY" 2>/dev/null || die "could not import the release key $KEY"
primary=$(gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
[ "$primary" = "$FPR" ] || die "the release key $KEY has the fingerprint '$primary', not the pinned $FPR"
status=$(gpg --batch --status-fd 1 --verify "$OUT/$NAME.asc" "$OUT/$NAME" 2>/dev/null) \
  || die "the signature $NAME.asc does not verify against the Nextcloud release key"
valid=$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $NF }' <<<"$status" | head -n1)
[ "$valid" = "$FPR" ] || die "the signature $NAME.asc was not made by the pinned key $FPR (it names '${valid:-nothing}')"
log "signature ok (Nextcloud release key $FPR)"
echo "$OUT/$NAME"
