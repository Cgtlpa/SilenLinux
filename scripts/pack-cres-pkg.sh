#!/bin/bash
set -e
set -E
set -o pipefail

NAME="${1:?usage: pack-cres-pkg.sh NAME VERSION ROOT OUTDIR DEPS DESCRIPTION CATEGORY}"
VERSION="${2:?}"
ROOT="${3:?}"
OUTDIR="${4:?}"
DEPS="${5:-}"
DESCRIPTION="${6:-}"
CATEGORY="${7:-system}"

[ -d "$ROOT" ] || { echo "ERROR $ROOT is not a directory"; exit 1; }
mkdir -p "$OUTDIR"
ARCHIVE="$OUTDIR/$NAME.spk"
TMP="$(mktemp "$OUTDIR/.$NAME.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

rm -f "$TMP"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
	-C "$ROOT" -cf - . | zstd -q -T0 -15 -f -o "$TMP"
mv "$TMP" "$ARCHIVE"
SUM="$(sha256sum "$ARCHIVE" | awk '{print $1}')"

python3 - "$NAME" "$VERSION" "$ARCHIVE" "$OUTDIR/package.json" "$SUM" "$DEPS" "$DESCRIPTION" "$CATEGORY" <<'PY'
import json, os, sys
name, version, archive, meta, checksum, deps, description, category = sys.argv[1:]
def split(value):
    return [x.strip() for x in value.replace(',', ' ').split() if x.strip()]
data = {
    "filename": os.path.basename(archive),
    "parts": 1,
    "sha256": checksum,
    "system": True,
    "version": version,
    "depends": split(deps),
    "category": category,
    "description": description,
}
for key, env in (("provides", "PROVIDES"), ("conflicts", "CONFLICTS"), ("replaces", "REPLACES"), ("optdeps", "OPTDEPS")):
    value = os.environ.get(env, "")
    if value.strip():
        data[key] = split(value)
with open(meta, "w") as f:
    json.dump(data, f, indent=1)
    f.write("\n")
PY

echo "packed $NAME $VERSION $(du -h "$ARCHIVE" | cut -f1) sha256=$SUM"
