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
SIZE="$(stat -c %s "$ARCHIVE")"

python3 - "$NAME" "$VERSION" "$ARCHIVE" "$OUTDIR/package.json" "$SUM" "$SIZE" "$DEPS" "$DESCRIPTION" "$CATEGORY" <<'PY'
import datetime, json, os, sys
name, version, archive, meta, checksum, size, deps, description, category = sys.argv[1:]

def split(value):
    return [x.strip() for x in value.replace(',', ' ').split() if x.strip()]

def hooklist(value):
    out = []
    for item in split(value):
        if ':' not in item:
            raise SystemExit("ERROR hooks entries must be RUNPATH:EVENT")
        path, event = item.rsplit(':', 1)
        out.append({"event": event, "run": path})
    return out

data = {
    "schema_version": 2,
    "name": name,
    "filename": os.path.basename(archive),
    "version": version,
    "release": int(os.environ.get("RELEASE", "1") or "1"),
    "os": os.environ.get("OS", "silen"),
    "size": int(size),
    "sha256": checksum,
    "checksum": checksum,
    "system": True,
    "depends": split(deps),
    "category": category or "system",
}
if description.strip():
    data["description"] = description
for key, env in (("provides", "PROVIDES"), ("conflicts", "CONFLICTS"), ("replaces", "REPLACES"),
                 ("optdepends", "OPTDEPS"), ("groups", "GROUPS"), ("backup", "BACKUP")):
    value = os.environ.get(env, "")
    if value.strip():
        data[key] = split(value)
hooks = os.environ.get("HOOKS", "")
if hooks.strip():
    data["hooks"] = hooklist(hooks)
for key, env in (("maintainer", "MAINTAINER"), ("packager", "PACKAGER"), ("architecture", "ARCH")):
    value = os.environ.get(env, "")
    if value.strip():
        data[key] = value
data["build_date"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
out = {key: data[key] for key in sorted(data)}

with open(meta, "w") as f:
    json.dump(out, f, indent=1)
    f.write("\n")
PY

echo "packed $NAME $VERSION $(du -h "$ARCHIVE" | cut -f1) sha256=$SUM size=$SIZE"
