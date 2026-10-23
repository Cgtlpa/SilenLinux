#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-gcc stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

PKGDIR="${PKGDIR:-spk-pkgs/packages}"
GCC_VERSION="${GCC_VERSION:-16.2.1-silen1}"

STAGE="$(mktemp -d /tmp/opencode/gcc.XXXXXX 2>/dev/null || echo /tmp/opencode/gcc.$$)"
mkdir -p "$STAGE" || exit 1

# Create directory structure matching gcc's compiled-in expectations
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/libexec/gcc" "$STAGE/usr/lib/gcc" "$STAGE/usr/lib64" || exit 1

# Copy gcc binaries
cp -a /usr/bin/gcc /usr/bin/g++ /usr/bin/gcc-ar /usr/bin/gcc-nm /usr/bin/gcc-ranlib "$STAGE/usr/bin/" || exit 1

# Copy libexec (cc1, cc1plus, collect2, lto1, etc.) - using redhat triplet paths
# (matches gcc's compiled-in search directories)
mkdir -p "$STAGE/usr/libexec/gcc/x86_64-redhat-linux/16" || exit 1
cp -a /usr/libexec/gcc/x86_64-redhat-linux/16/* "$STAGE/usr/libexec/gcc/x86_64-redhat-linux/16/" || exit 1

# Create pc-linux-gnu symlink for convenience
ln -sfn x86_64-redhat-linux "$STAGE/usr/libexec/gcc/x86_64-pc-linux-gnu" || exit 1

# Copy gcc runtime libraries
mkdir -p "$STAGE/usr/lib/gcc/x86_64-redhat-linux/16" || exit 1
cp -a /usr/lib/gcc/x86_64-redhat-linux/16/* "$STAGE/usr/lib/gcc/x86_64-redhat-linux/16/" || exit 1

# Create pc-linux-gnu symlink for lib dir too
ln -sfn x86_64-redhat-linux "$STAGE/usr/lib/gcc/x86_64-pc-linux-gnu" || exit 1

# Fix libstdc++.so symlink to use absolute path (relative symlink breaks in package)
rm -f "$STAGE/usr/lib/gcc/x86_64-redhat-linux/16/libstdc++.so"
ln -sf /usr/lib64/libstdc++.so.6.0.36 "$STAGE/usr/lib/gcc/x86_64-redhat-linux/16/libstdc++.so" || exit 1

# Copy libstdc++ to /usr/lib64
cp -a /usr/lib/libstdc++.so.6 /usr/lib/libstdc++.so.6.0.36 "$STAGE/usr/lib64/" || exit 1
ln -sfn libstdc++.so.6.0.36 "$STAGE/usr/lib64/libstdc++.so.6" || exit 1
ln -sfn libstdc++.so.6 "$STAGE/usr/lib64/libstdc++.so" || exit 1

# Copy libgcc_s.so.1 to /usr/lib64 for runtime
cp -a /usr/lib/gcc/x86_64-redhat-linux/16/libgcc_s.so.1 "$STAGE/usr/lib64/" 2>/dev/null || true
ln -sfn libgcc_s.so.1 "$STAGE/usr/lib64/libgcc_s.so" 2>/dev/null || true

# Build package
tar -czpf "$PKGDIR/gcc/gcc.spk" -C "$STAGE" . || { echo "  ERROR tar failed"; rm -rf "$STAGE"; exit 1; }
_s="$(sha256sum "$PKGDIR/gcc/gcc.spk" | awk '{print $1}')"
printf '{"filename": "gcc.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": ["linux-headers"], "category": "sys-devel", "description": "GCC 16.2.1 C/C++ compiler"}' "$_s" "$GCC_VERSION" > "$PKGDIR/gcc/package.json"
echo "gcc $GCC_VERSION $(du -h "$PKGDIR/gcc/gcc.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true