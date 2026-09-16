use std::fs;
use std::io::Read;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process;

use sha2::Digest;
use sha2::Sha256;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 3 || args[1] != "get" {
        println!("usage: spk get <package> [--root DIR]");
        return;
    }

    let name = args[2].clone();
    let mut root = String::from("/");

    let mut i = 3;
    while i + 1 < args.len() {
        if args[i] == "--root" {
            root = args[i + 1].clone();
        }
        i = i + 1;
    }

    let base = "https://raw.githubusercontent.com/Cgtlpa/spk_pkgs/main/packages";
    let manifest_url = format!("{}/{}/package.json", base, name);

    println!("spk: fetching manifest for {}", name);
    let manifest = http_get(&manifest_url);

    let file_name = read_field(&manifest, "filename");
    let version = read_field(&manifest, "version");
    let expected = read_field(&manifest, "sha256");
    let parts: u32 = read_field(&manifest, "parts").parse().unwrap_or(1);

    let download_url = format!("{}/{}/{}", base, name, file_name);
    println!("spk: downloading {}", file_name);

    let tmp = format!("/tmp/{}.spk", name);
    let digest = download(&download_url, &tmp, parts);

    let size = match fs::metadata(&tmp) {
        Ok(m) => m.len(),
        Err(err) => {
            println!("spk: error: cannot open downloaded file {}: {}", tmp, err);
            process::exit(1);
        }
    };
    println!("spk: downloaded {} bytes", size);

    if expected.is_empty() {
        println!("spk: no sha256 in manifest, skipping check");
    } else if digest != expected {
        println!("spk: sha256 mismatch for {} expected {} got {}", name, expected, digest);
        let _ = fs::remove_file(&tmp);
        process::exit(1);
    } else {
        println!("spk: checksum ok");
    }

    let count = extract(&tmp, &root);
    let _ = fs::remove_file(&tmp);

    if version.is_empty() {
        println!("spk: installed {} ({} files)", name, count);
    } else {
        println!("spk: installed {} v{} ({} files)", name, version, count);
    }
    if root != "/" {
        println!("spk: installed into {}", root);
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

    for i in 0..parts {
        let part_url = if parts > 1 {
            format!("{}.{:03}", url, i)
        } else {
            url.to_string()
        };
        if parts > 1 {
            println!("spk: downloading part {} of {}", i + 1, parts);
        }

        let mut resp = match ureq::get(&part_url).call() {
            Ok(resp) => resp,
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

fn extract(archive: &str, root: &str) -> usize {
    let mut count = 0;

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

        let name = entry.path().unwrap().to_string_lossy().to_string();
        let dest = clean(&name, root);

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
            let _ = fs::remove_file(&dest);
            check(
                std::os::unix::fs::symlink(&link, &dest),
                &format!("cannot create link {}", dest),
            );
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
            let mode = entry.header().mode().unwrap();
            check(
                fs::set_permissions(&dest, fs::Permissions::from_mode(mode)),
                &format!("cannot set mode on {}", dest),
            );
        }

        count = count + 1;
    }

    count
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

    if root == "/" {
        format!("/{}", joined)
    } else {
        format!("{}/{}", root.trim_end_matches('/'), joined)
    }
}

fn resolve(target: &str, root: &str) -> String {
    if target.starts_with('/') {
        format!("{}{}", root, target)
    } else {
        target.to_string()
    }
}

fn is_gzip(path: &str) -> bool {
    let mut file = fs::File::open(path).unwrap();
    let mut buf = [0u8; 2];
    file.read(&mut buf).unwrap();
    buf[0] == 0x1f && buf[1] == 0x8b
}