pub mod remove;

use std::fs;
use std::io::Read;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process;

use sha2::Digest;
use sha2::Sha256;

const DEFAULT_BASE: &str =
    "https://raw.githubusercontent.com/Cgtlpa/spk_pkgs/main/packages";

/// Where a package install lives: system-wide (under `root`) or per-user
/// (under the invoking user's $HOME).
struct Layout {
    /// prefix payload files are extracted under ("/" normally, or --root)
    root: String,
    /// per-package registry dir: version + installed file list + shims
    registry: String,
    /// per-app dir: version + bin/ links + run launcher
    appdir: String,
    /// dir for PATH shims of commands installed outside bin dirs
    shimdir: String,
    /// where the downloaded archive goes
    tmp: String,
    user_mode: bool,
}

struct Installed {
    /// absolute destination path (includes `root` prefix, if any)
    path: String,
    mode: u32,
    /// regular file (not dir); symlinks/hardlinks count as files here
    is_link: bool,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        usage();
        return;
    }

    // global flags may appear anywhere after the subcommand
    let mut root = String::from("/");
    let mut user_mode = false;
    let mut positional: Vec<String> = Vec::new();
    let mut i = 2;
    while i < args.len() {
        if args[i] == "--root" {
            if i + 1 >= args.len() {
                println!("spk: error: --root needs a directory");
                process::exit(1);
            }
            root = args[i + 1].clone();
            i += 2;
        } else if args[i] == "--user" {
            user_mode = true;
            i += 1;
        } else {
            positional.push(args[i].clone());
            i += 1;
        }
    }

    match args[1].as_str() {
        "list" => {
            let layout = layout_for(&root, user_mode, "");
            list(&layout);
        }
        "remove" => {
            if positional.is_empty() {
                println!("usage: spk remove <package> [--root DIR] [--user]");
                process::exit(1);
            }
            let layout = layout_for(&root, user_mode, &positional[0]);
            remove::remove_package(&positional[0], &layout);
        }
        "get" => {
            if positional.is_empty() {
                println!("usage: spk get <package> [--root DIR] [--user]");
                process::exit(1);
            }
            let name = positional[0].clone();
            let layout = layout_for(&root, user_mode, &name);
            get(&name, &layout);
        }
        _ => usage(),
    }
}

fn usage() {
    println!("usage:");
    println!("  spk get <package> [--root DIR] [--user]");
    println!("  spk remove <package> [--root DIR] [--user]");
    println!("  spk list [--root DIR] [--user]");
}

fn base_url() -> String {
    match std::env::var("SPK_BASE_URL") {
        Ok(v) if !v.trim().is_empty() => v.trim_end_matches('/').to_string(),
        _ => DEFAULT_BASE.to_string(),
    }
}

/// Work out every directory for this install. In user mode everything lives
/// under the user's $HOME (own filesystem tree per user); --root is ignored
/// there because the home dir already scopes the install.
fn layout_for(root: &str, user_mode: bool, name: &str) -> Layout {
    if user_mode {
        let home = std::env::var("HOME").unwrap_or_default();
        if home.is_empty() {
            println!("spk: error: --user needs $HOME to be set");
            process::exit(1);
        }
        if !root.is_empty() && root != "/" {
            println!("spk: note: --root is ignored with --user (installing into $HOME)");
        }
        let base = format!("{}/.local/share/spk", home.trim_end_matches('/'));
        Layout {
            root: String::new(),
            registry: format!("{}/packages/{}", base, name),
            appdir: format!("{}/apps/{}", base, name),
            shimdir: format!("{}/.local/bin", home.trim_end_matches('/')),
            tmp: format!("{}/.cache/spk/{}.spk", home.trim_end_matches('/'), name),
            user_mode: true,
        }
    } else {
        let r = root.trim_end_matches('/').to_string();
        let prefix = if r.is_empty() { "/".to_string() } else { r.clone() };
        Layout {
            root: if r.is_empty() { "/".to_string() } else { r },
            registry: format!("{}/var/lib/spk/packages/{}", prefix, name),
            appdir: format!("{}/opt/spk/{}", prefix, name),
            shimdir: format!("{}/usr/local/bin", prefix),
            tmp: format!("/tmp/{}.spk", name),
            user_mode: false,
        }
    }
}

/// runtime path: destination with the install prefix stripped, i.e. the path
/// as the running system will see it ("/" when no --root was given).
fn runtime_path(dest: &str, layout: &Layout) -> String {
    if layout.user_mode || layout.root == "/" || layout.root.is_empty() {
        return dest.to_string();
    }
    match dest.strip_prefix(layout.root.as_str()) {
        Some(rest) if !rest.is_empty() => rest.to_string(),
        _ => dest.to_string(),
    }
}

fn parent_bin_dirs() -> [&'static str; 6] {
    [
        "/bin/",
        "/sbin/",
        "/usr/bin/",
        "/usr/sbin/",
        "/usr/local/bin/",
        "/usr/local/sbin/",
    ]
}

fn on_path(runtime: &str) -> bool {
    parent_bin_dirs().iter().any(|d| runtime.starts_with(d))
}

/// relative symlink target from `link` to `dest` (both absolute). Stays
/// valid whether viewed under the install prefix (--root) or on the running
/// system, and survives a $HOME rename in --user mode.
fn rel_target(link: &str, dest: &str) -> String {
    let l: Vec<&str> = link.split('/').filter(|s| !s.is_empty()).collect();
    let d: Vec<&str> = dest.split('/').filter(|s| !s.is_empty()).collect();
    if l.is_empty() || d.is_empty() {
        return dest.to_string();
    }
    let dir = &l[..l.len() - 1];
    let mut common = 0;
    while common < dir.len() && common < d.len() && dir[common] == d[common] {
        common += 1;
    }
    let mut rel = String::new();
    for _ in common..dir.len() {
        rel.push_str("../");
    }
    rel.push_str(&d[common..].join("/"));
    if rel.is_empty() {
        dest.to_string()
    } else {
        rel
    }
}

fn get(name: &str, layout: &Layout) {
    let base = base_url();
    let manifest_url = format!("{}/{}/package.json", base, name);

    println!("spk: fetching manifest for {}", name);
    let manifest = http_get(&manifest_url);

    let file_name = read_field(&manifest, "filename");
    let version = read_field(&manifest, "version");
    let expected = read_field(&manifest, "sha256");
    let parts: u32 = read_field(&manifest, "parts").parse().unwrap_or(1);

    if file_name.is_empty() {
        println!("spk: error: manifest for {} has no filename", name);
        process::exit(1);
    }

    let download_url = format!("{}/{}/{}", base, name, file_name);
    println!("spk: downloading {}", file_name);

    if let Some(parent) = Path::new(&layout.tmp).parent() {
        check(
            fs::create_dir_all(parent),
            &format!("cannot create {}", parent.display()),
        );
    }
    let digest = download(&download_url, &layout.tmp, parts);

    let size = match fs::metadata(&layout.tmp) {
        Ok(m) => m.len(),
        Err(err) => {
            println!(
                "spk: error: cannot open downloaded file {}: {}",
                layout.tmp, err
            );
            process::exit(1);
        }
    };
    println!("spk: downloaded {} bytes", size);

    if expected.is_empty() {
        println!("spk: no sha256 in manifest, skipping check");
    } else if digest != expected {
        println!(
            "spk: sha256 mismatch for {} expected {} got {}",
            name, expected, digest
        );
        let _ = fs::remove_file(&layout.tmp);
        process::exit(1);
    } else {
        println!("spk: checksum ok");
    }

    // user mode installs the payload *inside* the app dir (the app dir is
    // the prefix), so nothing touches the system and no root is needed.
    // system mode extracts straight to the target root as before.
    let root = if layout.user_mode {
        layout.appdir.as_str()
    } else {
        layout.root.as_str()
    };
    let installed = extract(&layout.tmp, root);
    let _ = fs::remove_file(&layout.tmp);

    finish_install(name, &version, &installed, layout);
}

/// Write the registry, the per-app dir with its bin/ links + run launcher,
/// and PATH shims for commands that landed outside bin dirs.
fn finish_install(name: &str, version: &str, installed: &[Installed], layout: &Layout) {
    check(
        fs::create_dir_all(&layout.registry),
        &format!("cannot create {}", layout.registry),
    );
    check(
        fs::create_dir_all(format!("{}/bin", layout.appdir)),
        &format!("cannot create {}/bin", layout.appdir),
    );
    check(
        fs::create_dir_all(&layout.shimdir),
        &format!("cannot create {}", layout.shimdir),
    );

    // registry: version + every installed file + shims we create below
    check(
        fs::write(format!("{}/version", layout.registry), format!("{}\n", version)),
        &format!("cannot write {}/version", layout.registry),
    );
    let mut files = String::new();
    for e in installed {
        files.push_str(&e.path);
        files.push('\n');
    }
    check(
        fs::write(format!("{}/files", layout.registry), files),
        &format!("cannot write {}/files", layout.registry),
    );
    check(
        fs::write(format!("{}/version", layout.appdir), format!("{}\n", version)),
        &format!("cannot write {}/version", layout.appdir),
    );

    let mut commands: Vec<String> = Vec::new();
    let mut shims = String::new();
    for e in installed {
        if e.is_link || e.mode & 0o111 == 0 {
            continue;
        }
        let base = match Path::new(&e.path).file_name() {
            Some(b) => b.to_string_lossy().to_string(),
            None => continue,
        };
        if base.is_empty() {
            continue;
        }
        let runtime = runtime_path(&e.path, layout);

        // link from the app dir so every command is runnable from there:
        // /opt/spk/<name>/bin/<cmd> (or ~/.local/share/spk/apps/<name>/bin).
        // relative links on purpose: they resolve both under --root right
        // now and as absolute locations after boot / without the prefix.
        let link = format!("{}/bin/{}", layout.appdir, base);
        let _ = fs::remove_file(&link);
        if std::os::unix::fs::symlink(&rel_target(&link, &e.path), &link).is_ok() {
            if !commands.contains(&base) {
                commands.push(base.clone());
            }
        }

        // already on PATH (e.g. installed straight into /usr/bin)? then it
        // just runs - otherwise drop a shim into the shim dir.
        if on_path(&runtime) {
            continue;
        }
        let shim = format!("{}/{}", layout.shimdir, base);
        if Path::new(&shim).exists() || Path::new(&shim).symlink_metadata().is_ok() {
            continue;
        }
        if std::os::unix::fs::symlink(&rel_target(&shim, &e.path), &shim).is_ok() {
            shims.push_str(&shim);
            shims.push('\n');
            if !commands.contains(&base) {
                commands.push(base);
            }
        }
    }
    check(
        fs::write(format!("{}/shims", layout.registry), shims),
        &format!("cannot write {}/shims", layout.registry),
    );

    // `run` launcher: ./run <command> [args...] from inside the app dir
    let run_path = format!("{}/run", layout.appdir);
    let run_body = format!(
        "#!/bin/sh\n# spk launcher for {name}: run one of this app's commands\n# usage: ./run <command> [args...]\n# commands: {cmds}\n\
         cmd=\"$1\"\nif [ -z \"$cmd\" ]; then\n    echo \"usage: ./run <command> [args...]\"\n    echo \"commands:\"\n    ls \"$(dirname \"$0\")/bin\"\n    exit 1\nfi\nshift\nexec \"$(dirname \"$0\")/bin/$cmd\" \"$@\"\n",
        name = name,
        cmds = commands.join(" ")
    );
    check(
        fs::write(&run_path, run_body),
        &format!("cannot write {}", run_path),
    );
    check(
        fs::set_permissions(&run_path, fs::Permissions::from_mode(0o755)),
        &format!("cannot set mode on {}", run_path),
    );

    commands.sort();
    if version.is_empty() {
        println!("spk: installed {} ({} files)", name, installed.len());
    } else {
        println!("spk: installed {} v{} ({} files)", name, version, installed.len());
    }
    println!("spk: app dir: {}", layout.appdir);
    if commands.is_empty() {
        println!("spk: note: package installed no runnable commands");
    } else {
        println!("spk: commands: {}", commands.join(" "));
        println!("spk: run one with: {}/run <command>  (or ./bin/<command> from {})", layout.appdir, layout.appdir);
    }
    if layout.user_mode && !path_contains(&layout.shimdir) {
        println!(
            "spk: hint: add {} to PATH to run shims directly (export PATH=\"$HOME/.local/bin:$PATH\")",
            layout.shimdir
        );
    }
    if !layout.user_mode && layout.root != "/" {
        println!("spk: installed into {}", layout.root);
    }
}

fn path_contains(dir: &str) -> bool {
    match std::env::var("PATH") {
        Ok(p) => p.split(':').any(|e| e == dir),
        Err(_) => false,
    }
}

fn list(layout: &Layout) {
    // for list the package name is empty, so the registry path is the
    // packages dir itself (with a trailing slash)
    let pkgs = layout.registry.trim_end_matches('/');
    let entries = match fs::read_dir(&pkgs) {
        Ok(e) => e,
        Err(_) => {
            println!("spk: nothing installed");
            return;
        }
    };
    let mut found = 0;
    let mut rows: Vec<(String, String)> = Vec::new();
    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let pkg = entry.file_name().to_string_lossy().to_string();
        let ver = fs::read_to_string(dir.join("version"))
            .unwrap_or_default()
            .trim()
            .to_string();
        rows.push((pkg, ver));
    }
    rows.sort();
    for (pkg, ver) in &rows {
        found += 1;
        if ver.is_empty() {
            println!("{}", pkg);
        } else {
            println!("{} v{}", pkg, ver);
        }
    }
    if found == 0 {
        println!("spk: nothing installed");
    }
}

fn http_get(url: &str) -> String {
    let mut resp = match ureq::get(url).call() {
        Ok(resp) => resp,
        Err(err) => {
            println!("spk: error: could not fetch {}: {}", url, err);
            process::exit(1);
        }
    };
    if resp.status().as_u16() != 200 {
        println!("spk: error: could not fetch {}", url);
        process::exit(1);
    }
    match resp.body_mut().read_to_string() {
        Ok(text) => text,
        Err(err) => {
            println!("spk: error: could not read {}: {}", url, err);
            process::exit(1);
        }
    }
}

fn download(url: &str, dst: &str, parts: u32) -> String {
    let _ = fs::remove_file(dst);
    let mut hasher = Sha256::new();
    // split archives (<file>.000, <file>.001, ...) for hosts with per-file
    // size limits: used when the manifest says so, or auto-detected when a
    // plain download 404s but numbered parts exist.
    let mut split = parts > 1;
    let mut i = 0;

    loop {
        let part_url = if split {
            format!("{}.{:03}", url, i)
        } else {
            url.to_string()
        };
        if split {
            if parts > 1 {
                println!("spk: downloading part {} of {}", i + 1, parts);
            } else {
                println!("spk: downloading part {}", i + 1);
            }
        }

        let mut resp = match ureq::get(&part_url).call() {
            Ok(resp) => resp,
            Err(ureq::Error::StatusCode(404)) if !split && parts <= 1 => {
                split = true;
                i = 0;
                continue;
            }
            Err(ureq::Error::StatusCode(404)) if split && parts <= 1 && i > 0 => break,
            Err(err) => {
                let _ = fs::remove_file(dst);
                println!("spk: error: could not download {}: {}", part_url, err);
                process::exit(1);
            }
        };
        if resp.status().as_u16() != 200 {
            let _ = fs::remove_file(dst);
            println!("spk: error: could not download {}", part_url);
            process::exit(1);
        }

        let mut out = match fs::OpenOptions::new().append(true).create(true).open(dst) {
            Ok(file) => file,
            Err(err) => {
                let _ = fs::remove_file(dst);
                println!("spk: error: cannot write {}: {}", dst, err);
                process::exit(1);
            }
        };
        let mut reader = resp.body_mut().as_reader();
        let mut buf = [0u8; 4096];

        loop {
            let count = match reader.read(&mut buf) {
                Ok(count) => count,
                Err(err) => {
                    let _ = fs::remove_file(dst);
                    println!("spk: error: download failed: {}", err);
                    process::exit(1);
                }
            };
            if count == 0 {
                break;
            }
            hasher.update(&buf[..count]);
            if let Err(err) = out.write_all(&buf[..count]) {
                let _ = fs::remove_file(dst);
                println!("spk: error: cannot write {}: {}", dst, err);
                process::exit(1);
            }
        }

        i += 1;
        if !split || (parts > 1 && i == parts) {
            break;
        }
    }

    format!("{:x}", hasher.finalize())
}

fn read_field(text: &str, key: &str) -> String {
    let needle = format!("\"{}\"", key);

    match text.find(&needle) {
        None => String::new(),
        Some(pos) => {
            let rest = &text[pos + needle.len()..];

            match rest.find(':') {
                None => String::new(),
                Some(colon) => {
                    let mut value = String::new();
                    for c in rest[colon + 1..].chars() {
                        if c == ',' || c == '}' || c == '\n' {
                            break;
                        }
                        value.push(c);
                    }
                    value = value.trim().to_string();
                    value.trim_matches('"').to_string()
                }
            }
        }
    }
}

fn extract(archive: &str, root: &str) -> Vec<Installed> {
    let mut installed: Vec<Installed> = Vec::new();

    let file = match fs::File::open(archive) {
        Ok(file) => file,
        Err(err) => {
            println!("spk: error: cannot open {}: {}", archive, err);
            process::exit(1);
        }
    };
    let reader: Box<dyn Read> = if is_gzip(archive) {
        Box::new(flate2::read::GzDecoder::new(file))
    } else {
        Box::new(file)
    };

    let mut tar = tar::Archive::new(reader);

    let entries = match tar.entries() {
        Ok(entries) => entries,
        Err(err) => {
            let _ = fs::remove_file(archive);
            println!("spk: error: bad archive {}: {}", archive, err);
            process::exit(1);
        }
    };

    for entry in entries {
        let mut entry = match entry {
            Ok(entry) => entry,
            Err(err) => {
                let _ = fs::remove_file(archive);
                println!("spk: error: bad archive {}: {}", archive, err);
                process::exit(1);
            }
        };
        let typ = entry.header().entry_type();

        if typ.is_pax_global_extensions()
            || typ.is_pax_local_extensions()
            || typ.is_gnu_longname()
            || typ.is_gnu_longlink()
        {
            continue;
        }

        let name = match entry.path() {
            Ok(path) => path.to_string_lossy().to_string(),
            Err(err) => {
                let _ = fs::remove_file(archive);
                println!("spk: error: bad path in {}: {}", archive, err);
                process::exit(1);
            }
        };
        let dest = clean(&name, root);
        let mode = entry.header().mode().unwrap_or(0o644);

        if typ.is_dir() {
            check(fs::create_dir_all(&dest), &format!("cannot create {}", dest));
        } else if typ.is_symlink() {
            let target = match entry.link_name() {
                Ok(Some(target)) => target,
                _ => {
                    let _ = fs::remove_file(archive);
                    println!("spk: error: symlink without target in {}", name);
                    process::exit(1);
                }
            };
            let target = target.to_string_lossy().to_string();
            let link = resolve(&target, root);
            let parent = Path::new(&dest).parent().unwrap();
            check(fs::create_dir_all(parent), &format!("cannot create {}", parent.display()));
            let _ = fs::remove_file(&dest);
            check(
                std::os::unix::fs::symlink(&link, &dest),
                &format!("cannot create link {}", dest),
            );
            installed.push(Installed {
                path: dest,
                mode,
                is_link: true,
            });
        } else if typ.is_hard_link() {
            let target = match entry.link_name() {
                Ok(Some(target)) => target,
                _ => {
                    let _ = fs::remove_file(archive);
                    println!("spk: error: hardlink without target in {}", name);
                    process::exit(1);
                }
            };
            let src = clean(&target.to_string_lossy(), root);
            let parent = Path::new(&dest).parent().unwrap();
            check(fs::create_dir_all(parent), &format!("cannot create {}", parent.display()));
            let _ = fs::remove_file(&dest);
            check(
                fs::hard_link(&src, &dest),
                &format!("cannot create hardlink {}", dest),
            );
            installed.push(Installed {
                path: dest,
                mode,
                is_link: true,
            });
        } else {
            let parent = Path::new(&dest).parent().unwrap();
            check(fs::create_dir_all(parent), &format!("cannot create {}", parent.display()));
            let _ = fs::remove_file(&dest);
            let mut out = match fs::File::create(&dest) {
                Ok(file) => file,
                Err(err) => {
                    println!("spk: error: cannot create {}: {}", dest, err);
                    process::exit(1);
                }
            };
            if let Err(err) = std::io::copy(&mut entry, &mut out) {
                println!("spk: error: cannot write {}: {}", dest, err);
                process::exit(1);
            }
            check(
                fs::set_permissions(&dest, fs::Permissions::from_mode(mode)),
                &format!("cannot set mode on {}", dest),
            );
            installed.push(Installed {
                path: dest,
                mode,
                is_link: false,
            });
        }
    }

    installed
}

fn check(result: std::io::Result<()>, what: &str) {
    if let Err(err) = result {
        println!("spk: error: {}: {}", what, err);
        process::exit(1);
    }
}

fn clean(name: &str, root: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();

    for part in name.split('/') {
        if part == "." || part.is_empty() {
            continue;
        }
        if part == ".." {
            parts.pop();
            continue;
        }
        parts.push(part);
    }

    let joined = parts.join("/");

    if root == "/" || root.is_empty() {
        format!("/{}", joined)
    } else {
        format!("{}/{}", root.trim_end_matches('/'), joined)
    }
}

fn resolve(target: &str, root: &str) -> String {
    if target.starts_with('/') {
        if root == "/" || root.is_empty() {
            target.to_string()
        } else {
            format!("{}{}", root.trim_end_matches('/'), target)
        }
    } else {
        target.to_string()
    }
}

fn is_gzip(path: &str) -> bool {
    let mut file = match fs::File::open(path) {
        Ok(file) => file,
        Err(_) => return false,
    };
    let mut buf = [0u8; 2];
    if file.read_exact(&mut buf).is_err() {
        return false;
    }
    buf[0] == 0x1f && buf[1] == 0x8b
}
