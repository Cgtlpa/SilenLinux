#!/bin/bash
set -e
set -E
set -o pipefail

REPO="${REPO:-vgzz/spk-pkgs}"
PKGDIR="${PKGDIR:-packages}"
OUT="${OUT:-index.json}"
JOBS="${JOBS:-16}"
UPLOAD="${UPLOAD:-0}"
WORK="${WORK:-$(mktemp -d /tmp/opencode/index.XXXXXX)}"

TREE_URL="https://huggingface.co/api/datasets/$REPO/tree/main/$PKGDIR"
BASE_URL="https://huggingface.co/datasets/$REPO/resolve/main/$PKGDIR"

mkdir -p "$WORK/manifests" || exit 1

curl -fsSL --max-time 120 "$TREE_URL" -o "$WORK/tree.json" || exit 1
python3 -c 'import json,sys
for e in json.load(open(sys.argv[1])):
	if e.get("type") == "directory":
		print(e["path"].split("/")[-1])' "$WORK/tree.json" | sort > "$WORK/names.txt"
[ -s "$WORK/names.txt" ] || { echo "no packages found in $TREE_URL" >&2; exit 1; }

xargs -P "$JOBS" -n1 bash -c 'curl -fsSL --max-time 120 "$1/$3/package.json" -o "$2/$3.json" 2>/dev/null || rm -f "$2/$3.json"' _ "$BASE_URL" "$WORK/manifests" < "$WORK/names.txt"

curl -fsSL --max-time 120 "$BASE_URL/index.json" -o "$WORK/index-old.json" 2>/dev/null || true

python3 - "$WORK/manifests" "$WORK/index-old.json" "$OUT" <<'PY'
import json, os, sys

mandir, oldpath, outpath = sys.argv[1], sys.argv[2], sys.argv[3]

old = {}
try:
	for e in json.load(open(oldpath)):
		if isinstance(e, dict) and e.get("name"):
			old[e["name"]] = e.get("description", "")
except Exception:
	pass

entries = []
for fn in sorted(os.listdir(mandir)):
	if not fn.endswith(".json"):
		continue
	name = fn[:-5]
	try:
		man = json.load(open(os.path.join(mandir, fn)))
	except Exception as err:
		print("skip %s: %s" % (name, err), file=sys.stderr)
		continue
	if not isinstance(man, dict):
		print("skip %s: not an object" % name, file=sys.stderr)
		continue
	entries.append({
		"name": name,
		"filename": man.get("filename", name + ".spk"),
		"version": man.get("version", ""),
		"system": bool(man.get("system", False)),
		"category": man.get("category", ""),
		"description": man.get("description", "") or old.get(name, ""),
	})

with open(outpath, "w") as fh:
	json.dump(entries, fh, indent=1)
	fh.write("\n")
print("index: %d packages -> %s" % (len(entries), outpath))
PY

if [ "$UPLOAD" = "1" ]; then
	hf upload "$REPO" "$OUT" "$PKGDIR/index.json" --repo-type dataset || exit 1
	echo "  uploaded $PKGDIR/index.json to $REPO"
fi
