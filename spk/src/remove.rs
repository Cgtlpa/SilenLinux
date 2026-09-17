//! `spk remove`: delete everything a package installed using the registry
//! written by `spk get` (payload files, PATH shims, the per-app dir).
//!
//! Packages installed by older spk versions have no registry; for those we
//! fall back to removing a lone binary named after the package.

use super::Layout;
use std::fs;
use std::path::Path;
use std::process;

pub(crate) fn remove_package(name: &str, layout: &Layout) {
    // no registry (old install or hand-placed binary)? try the legacy paths.
    if !Path::new(&layout.registry).is_dir() {
        legacy_remove(name, layout);
        return;
    }

    let files = fs::read_to_string(format!("{}/files", layout.registry)).unwrap_or_default();
    let shims = fs::read_to_string(format!("{}/shims", layout.registry)).unwrap_or_default();

    let mut removed = 0;
    for line in files.lines().chain(shims.lines()) {
        let path = line.trim();
        if path.is_empty() {
            continue;
        }
        // safety: only touch paths inside the install scope
        if !in_scope(path, layout) {
            continue;
        }
        if fs::remove_file(path).is_ok() {
            removed += 1;
        } else if Path::new(path).is_dir() && fs::remove_dir(path).is_ok() {
            removed += 1;
        } else {
            continue;
        }
        prune_empty_parents(path, layout);
    }

    // the per-app dir and the registry itself go wholesale (they are ours)
    let _ = fs::remove_dir_all(&layout.appdir);
    let _ = fs::remove_dir_all(&layout.registry);

    if removed == 0 {
        println!("spk: {} was already gone, cleaned up its records", name);
    } else {
        println!("spk: removed {} ({} files)", name, removed);
    }
}

/// rmdir empty parents up to (but never including) the install scope root.
/// rmdir only removes empty dirs, so populated system dirs are untouched.
fn prune_empty_parents(path: &str, layout: &Layout) {
    let stop = scope_root(layout);
    let mut cur = match Path::new(path).parent() {
        Some(p) => p.to_path_buf(),
        None => return,
    };
    loop {
        let s = cur.to_string_lossy().to_string();
        if s == stop || !s.starts_with(stop.as_str()) {
            break;
        }
        if fs::remove_dir(&cur).is_err() {
            break;
        }
        match cur.parent() {
            Some(p) => cur = p.to_path_buf(),
            None => break,
        }
    }
}

/// install scope: system root (or --root), or the user's spk tree + bin dir.
fn scope_root(layout: &Layout) -> String {
    if layout.user_mode {
        match std::env::var("HOME") {
            Ok(h) if !h.is_empty() => h.trim_end_matches('/').to_string(),
            _ => String::from("/"),
        }
    } else if layout.root.is_empty() {
        String::from("/")
    } else {
        layout.root.clone()
    }
}

fn in_scope(path: &str, layout: &Layout) -> bool {
    let stop = scope_root(layout);
    if stop == "/" {
        return path.starts_with('/');
    }
    path == stop || path.starts_with(&format!("{}/", stop))
}

/// old spk versions only dropped a binary; delete it from the usual places.
fn legacy_remove(name: &str, layout: &Layout) {
    let mut dirs: Vec<String> = Vec::new();
    if layout.user_mode {
        dirs.push(layout.shimdir.clone());
    } else {
        let prefix = if layout.root == "/" || layout.root.is_empty() {
            String::new()
        } else {
            layout.root.clone()
        };
        for d in ["/usr/bin", "/usr/local/bin", "/bin"] {
            dirs.push(format!("{}{}", prefix, d));
        }
    }
    for dir in &dirs {
        let path = format!("{}/{}", dir.trim_end_matches('/'), name);
        if fs::remove_file(&path).is_ok() {
            println!("spk: removed {}", path);
            return;
        }
    }

    println!("spk: could not find {}", name);
    process::exit(1);
}
