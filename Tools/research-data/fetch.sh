#!/usr/bin/env bash
# fetch.sh — download one or more public research datasets into the git-ignored research-data/ folder.
#
#   Tools/research-data/fetch.sh list
#   Tools/research-data/fetch.sh fantasia slpdb
#   RESEARCH_DATA_DIR=/Volumes/big/research-data Tools/research-data/fetch.sh sleep-accel
#
# Every dataset is described by one row of datasets.tsv (name, kind, url, verify, licence, note). The data
# lands in $RESEARCH_DATA_DIR/<name>/ (default: <repo>/research-data/, which .gitignore excludes) and is
# NEVER committed. A dataset's own licence applies; most require attribution (see README.md).
#
# Verification: PhysioNet archives ship a SHA256SUMS.txt that is checked file by file after extraction;
# Zenodo files are checked against the md5 the records API publishes; UCI and ORA publish no checksum, so
# the script records the sha256 it observed in <name>/.fetched for the next person to compare against.
#
# Re-running is safe: a finished dataset (a .fetched stamp present) is skipped; a partial download resumes.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
manifest="$here/datasets.tsv"
root="${RESEARCH_DATA_DIR:-$repo/research-data}"
dl="$root/_downloads"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

row_for() {   # name -> the tab-separated manifest row
    awk -F'\t' -v n="$1" '$0 !~ /^#/ && $1 == n { print; exit }' "$manifest"
}

list() {
    printf '%-32s %-10s %-40s %s\n' NAME KIND LICENCE NOTE
    awk -F'\t' '$0 !~ /^#/ && NF >= 6 { printf "%-32s %-10s %-40s %s\n", $1, $2, $5, $6 }' "$manifest"
    echo
    echo "data dir: $root"
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else sha256sum "$1" | awk '{print $1}'; fi
}
md5_of() {
    if command -v md5 >/dev/null 2>&1; then md5 -q "$1"
    else md5sum "$1" | awk '{print $1}'; fi
}

fetch_one() {
    local name="$1" row kind url verify licence note
    row="$(row_for "$name")"
    if [ -z "$row" ]; then echo "fetch.sh: unknown dataset '$name' (try: fetch.sh list)" >&2; return 2; fi
    IFS=$'\t' read -r name kind url verify licence note <<<"$row"
    local dest="$root/$name"
    if [ -f "$dest/.fetched" ]; then echo "[$name] already fetched: $(head -1 "$dest/.fetched")"; return 0; fi

    if [ "$kind" = manual ]; then
        cat <<MSG
[$name] needs a data-use agreement; nothing is downloaded automatically.
  1. Sign in at $url and complete the access steps the page lists.
  2. Download the files by hand into: $dest/
  3. Then: date -u +%FT%TZ > "$dest/.fetched"
  Licence: $licence
MSG
        return 0
    fi

    mkdir -p "$dl" "$dest"
    local file="$dl/$name.zip"
    echo "[$name] downloading $url"
    echo "          licence: $licence"
    # -C - resumes a partial file; -L follows PhysioNet's get-zip redirect to S3.
    curl -L --fail --retry 3 --retry-delay 5 -C - -o "$file" -A "noop-research-fetch" "$url"

    local seen_sha seen_md5
    seen_sha="$(sha256_of "$file")"
    case "$verify" in
        md5:*)
            seen_md5="$(md5_of "$file")"
            if [ "$seen_md5" != "${verify#md5:}" ]; then
                echo "[$name] md5 mismatch: expected ${verify#md5:} got $seen_md5 — delete $file and retry" >&2
                return 1
            fi
            echo "[$name] md5 ok" ;;
        sha256sums|none) ;;
        *) echo "[$name] unknown verify mode '$verify'" >&2; return 2 ;;
    esac

    echo "[$name] extracting into $dest"
    unzip -q -o "$file" -d "$dest"

    if [ "$verify" = sha256sums ]; then
        # PhysioNet zips wrap everything in one directory that carries SHA256SUMS.txt.
        local inner
        inner="$(find "$dest" -maxdepth 2 -name SHA256SUMS.txt | head -1)"
        if [ -z "$inner" ]; then echo "[$name] SHA256SUMS.txt not found after extraction" >&2; return 1; fi
        echo "[$name] verifying files against $(basename "$(dirname "$inner")")/SHA256SUMS.txt"
        ( cd "$(dirname "$inner")" && if command -v shasum >/dev/null 2>&1; then shasum -a 256 -c --quiet SHA256SUMS.txt; else sha256sum -c --quiet SHA256SUMS.txt; fi )
        echo "[$name] all files verified"
    fi

    {
        echo "$(date -u +%FT%TZ) $name"
        echo "url: $url"
        echo "zip sha256: $seen_sha"
        echo "verify: $verify"
        echo "licence: $licence"
    } > "$dest/.fetched"
    echo "[$name] done — $(du -sh "$dest" | cut -f1) in $dest"
    [ "$verify" = none ] && echo "[$name] no published checksum; observed zip sha256 $seen_sha (recorded in .fetched)"
    return 0
}

case "${1:-}" in
    ""|-h|--help) usage; exit 0 ;;
    list) list; exit 0 ;;
esac
status=0
for n in "$@"; do fetch_one "$n" || status=$?; done
exit $status
