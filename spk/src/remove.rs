use super::Layout;
use std::fs;
use std::path::Path;
use std::process;

pub fn remove_package(name: &str, layout: &Layout) {
    if !Path::new(&layout.registry).is_dir() {
        legacy_remove(name, layout);
        return;
    }

    let files = fs::read_to_string(format!("{}/files", layout.registry)).unwrap_or_default();
    let shims = fs::read_to_string(format!("{}/shims", layout.registry)).unwrap_or_default();
    let system_files = fs::read_to_string(format!("{}/system-files", layout.appdir)).unwrap_or_default();

    let mut removed = 0;
    for line in files.lines().chain(shims.lines()).chain(system_files.lines()) {
        let path = line.trim();
        if path.is_empty() {
            continue;
        }
        if !in_scope(path, layout) {
            continue;
        }
        let meta = fs::symlink_metadata(path);
        let gone = match meta {
            Ok(m) if m.file_type().is_dir() => fs::remove_dir(path).is_ok(),
            Ok(_) => fs::remove_file(path).is_ok(),
            Err(_) => false,
        };
        if !gone {
            continue;
        }
        removed += 1;
        prune_empty_parents(path, layout);
    }

    let _ = fs::remove_dir_all(&layout.appdir);
    let _ = fs::remove_dir_all(&layout.pkgdir);
    let _ = fs::remove_dir_all(&layout.registry);

    remove_lib_conf(name, layout);

    if removed == 0 {
        println!("spk: {} was already gone, cleaned up its records", name);
    } else {
        println!("spk: removed {} ({} files)", name, removed);
    }
}

fn prune_empty_parents(path: &str, layout: &Layout) {
    let stop = scope_root(layout);
    let mut current = match Path::new(path).parent() {
        Some(parent) => parent.to_path_buf(),
        None => return,
    };
    loop {
        let text = current.to_string_lossy().to_string();
        if text == stop || !text.starts_with(stop.as_str()) {
            break;
        }
        if fs::remove_dir(&current).is_err() {
            break;
        }
        match current.parent() {
            Some(parent) => current = parent.to_path_buf(),
            None => break,
        }
    }
}

fn scope_root(layout: &Layout) -> String {
    if layout.user_mode {
        match std::env::var("HOME") {
            Ok(home) if !home.is_empty() => home.trim_end_matches('/').to_string(),
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

fn remove_lib_conf(name: &str, layout: &Layout) {
    if layout.user_mode {
        return;
    }
    let safe: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_' || *c == '.')
        .collect();
    if safe.is_empty() {
        return;
    }
    let prefix = if layout.root.is_empty() { "/" } else { layout.root.as_str() };
    let spk_dir = format!("{}/usr/lib/spk/{}", prefix.trim_end_matches('/'), safe);
    if fs::remove_dir_all(&spk_dir).is_ok() {
        println!("spk: removed {}", spk_dir);
    }
    let conf = format!("{}/etc/ld.so.conf.d/spk-{}.conf", prefix.trim_end_matches('/'), safe);
    if fs::remove_file(&conf).is_ok() {
        println!("spk: removed {}", conf);
        let status = if prefix == "/" {
            std::process::Command::new("ldconfig").status()
        } else {
            std::process::Command::new("ldconfig").arg("-r").arg(prefix).status()
        };
        if !matches!(status, Ok(code) if code.success()) {
            println!("spk: warning: ldconfig refresh failed - run ldconfig by hand");
        }
    }
}

fn legacy_remove(name: &str, layout: &Layout) {
    remove_lib_conf(name, layout);
    let mut dirs: Vec<String> = Vec::new();
    if layout.user_mode {
        dirs.push(layout.shimdir.clone());
    } else {
        let prefix = if layout.root == "/" || layout.root.is_empty() {
            String::new()
        } else {
            layout.root.clone()
        };
        for dir in ["/usr/bin", "/usr/local/bin", "/bin"] {
            dirs.push(format!("{}{}", prefix, dir));
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
