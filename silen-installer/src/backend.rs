use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

pub const ROOT_PATH: &str = "/silen";
pub const TITLE: &str = "Silen Linux";

// this is the whole install, partition then unpack then grub, in that order
pub type LogFn = dyn FnMut(String) + Send;

pub struct InstallSettings {
    pub disk: String,
    pub hostname: String,
    pub rootpass: String,
    pub newuser: String,
    pub userpass: String,
    pub zone: String,
    pub keymap: String,
    pub locale: String,
    pub fstype: String,
    pub want_swap: String,
    pub bootp: String,
    pub rootp: String,
    pub kver: String,
}

impl Default for InstallSettings {
    fn default() -> Self {
        Self {
            disk: String::new(),
            hostname: "silen".into(),
            rootpass: String::new(),
            newuser: String::new(),
            userpass: String::new(),
            zone: "UTC".into(),
            keymap: "us".into(),
            locale: "en_US.UTF-8".into(),
            fstype: "ext4".into(),
            want_swap: String::new(),
            bootp: String::new(),
            rootp: String::new(),
            kver: String::new(),
        }
    }
}

fn sh_log(log: &mut LogFn, msg: &str) {
    log(format!("[installer] {}", msg));
}

fn run(cmd: &str, args: &[&str]) -> bool {
    Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_capture(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

fn run_sh(script: &str) -> bool {
    Command::new("/bin/bash")
        .arg("-c")
        .arg(script)
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn must_be_root() -> bool {
    run_capture("id", &["-u"]).trim() == "0"
}

pub fn is_efi() -> bool {
    Path::new("/sys/firmware/efi").is_dir()
}

pub fn list_disks() -> Vec<(String, String)> {
    let mut out = Vec::new();
    let patterns = ["sd", "vd", "xvd", "nvme", "mmcblk"];
    let mut seen: Vec<String> = Vec::new();
    if let Ok(entries) = fs::read_dir("/sys/block") {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let is_disk = patterns.iter().any(|p| name.starts_with(p))
                || name.starts_with("nvme")
                || name.starts_with("mmcblk");
            if !is_disk {
                continue;
            }
            if name.starts_with("loop") || name.starts_with("ram") || name.starts_with("zram") || name.starts_with("fd") {
                continue;
            }
            if name.chars().last().map(|c| c.is_ascii_digit()).unwrap_or(false) {
                if name.contains('p') {
                    continue;
                }
                if Path::new(&format!("/sys/block/{}/device", name)).exists() == false {
                    let dev = format!("/dev/{}", name);
                    if !Path::new(&dev).exists() {
                        continue;
                    }
                }
            }
            let dev = format!("/dev/{}", name);
            if !Path::new(&dev).exists() {
                continue;
            }
            if seen.contains(&dev) {
                continue;
            }
            seen.push(dev.clone());
            out.push((dev.clone(), disk_label(&dev)));
        }
    }
    for d in ["/dev/sd", "/dev/vd", "/dev/xvd"] {
        for c in b'a'..=b'z' {
            let dev = format!("{}{}", d, c as char);
            if Path::new(&dev).exists() && !seen.contains(&dev) {
                seen.push(dev.clone());
                out.push((dev.clone(), disk_label(&dev)));
            }
        }
    }
    out.sort();
    out
}

fn disk_size(dev: &str) -> String {
    let base = dev.trim_start_matches("/dev/");
    let s = run_capture("lsblk", &["-dn", "-o", "SIZE", dev]);
    let s = s.replace(' ', "");
    if !s.is_empty() {
        return s;
    }
    if let Ok(sectors) = fs::read_to_string(format!("/sys/block/{}/size", base)) {
        if let Ok(sec) = sectors.trim().parse::<u64>() {
            let b = sec * 512;
            if b >= 1073741824 {
                return format!("{}G", b / 1073741824);
            } else if b >= 1048576 {
                return format!("{}M", b / 1048576);
            } else {
                return format!("{}K", b / 1024);
            }
        }
    }
    "unknown-size".into()
}

fn disk_model(dev: &str) -> String {
    let base = dev.trim_start_matches("/dev/");
    if let Ok(m) = fs::read_to_string(format!("/sys/block/{}/device/model", base)) {
        let m = m.split_whitespace().collect::<Vec<_>>().join(" ");
        if !m.is_empty() {
            return m;
        }
    }
    let m = run_capture("lsblk", &["-dn", "-o", "MODEL", dev]);
    let m = m.split_whitespace().collect::<Vec<_>>().join(" ");
    if !m.is_empty() {
        return m;
    }
    "unknown-model".into()
}

pub fn disk_label(dev: &str) -> String {
    format!("{} {} {}", dev, disk_size(dev), disk_model(dev))
}

pub fn medium_has_tarball_at(dir: &str) -> bool {
    let skip = ["kernel-", "headers-", "network.tar", "spk.tar", "nvidia-kmods-", "desktop.tar"];
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return false,
    };
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let p = e.path();
        if !p.is_file() {
            continue;
        }
        let is_tar = name.starts_with("stage3-") || name.starts_with("tarball-") || name.ends_with(".tar.xz") || name.ends_with(".tar.zst");
        if !is_tar {
            continue;
        }
        if skip.iter().any(|s| name.starts_with(s)) {
            continue;
        }
        return true;
    }
    false
}

pub fn medium_has_tarball() -> bool {
    medium_has_tarball_at("/mnt")
}

pub fn find_tarball() -> Option<String> {
    let entries = fs::read_dir("/mnt").ok()?;
    let mut cands: Vec<String> = Vec::new();
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let p = format!("/mnt/{}", name);
        if !Path::new(&p).is_file() {
            continue;
        }
        let is_tar = name.starts_with("stage3-") || name.starts_with("tarball-") || name.ends_with(".tar.xz") || name.ends_with(".tar.zst");
        if !is_tar {
            continue;
        }
        if name.starts_with("kernel-") || name.starts_with("headers-") || name.starts_with("network.tar") || name.starts_with("spk.tar") || name.starts_with("nvidia-kmods-") || name.starts_with("desktop.tar") {
            continue;
        }
        cands.push(p);
    }
    cands.sort();
    cands.into_iter().next()
}

pub fn medium_on_disk(disk: &str) -> bool {
    if let Ok(rec) = fs::read_to_string("/run/silen-medium-dev") {
        let rec = rec.trim().to_string();
        if !rec.is_empty() {
            if rec == disk || rec.starts_with(&format!("{}1", disk)) || rec.starts_with(&format!("{}p", disk)) {
                return true;
            }
            if rec.starts_with(disk) {
                return true;
            }
        }
    }
    let mounts = run_capture("mount", &[]);
    for line in mounts.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 && parts[2] == "/mnt" {
            let src = parts[0];
            if src == disk || src.starts_with(disk) {
                return true;
            }
        }
        if parts.len() >= 3 && parts[2] == "/run/ventoy" {
            let src = parts[0];
            if src == disk || src.starts_with(disk) {
                return true;
            }
        }
    }
    false
}

pub fn cleanup() {
    for m in ["/silen/proc", "/silen/sys", "/silen/dev", "/silen/run", "/silen/boot", "/silen"] {
        let _ = Command::new("umount").args(["-R", m]).status();
    }
}

pub fn sanitize_hostname(raw: &str) -> String {
    let mut s: String = raw.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect();
    while s.starts_with('-') {
        s.remove(0);
    }
    while s.ends_with('-') {
        s.pop();
    }
    if s.is_empty() {
        s = "silen".into();
    }
    s
}

pub fn valid_username(name: &str) -> Result<(), &'static str> {
    if name.is_empty() {
        return Ok(());
    }
    if name == "root" {
        return Err("root already exists");
    }
    if name.len() > 32 {
        return Err("username too long max 32");
    }
    let mut chars = name.chars();
    match chars.next() {
        Some(c) if c.is_ascii_lowercase() || c == '_' => {}
        _ => return Err("must start with a lowercase letter or underscore"),
    }
    for c in name.chars() {
        if !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-') {
            return Err("only lowercase letters, digits, _ and - allowed");
        }
    }
    Ok(())
}

fn part_devs(disk: &str) -> (String, String) {
    let p1 = format!("{}p1", disk);
    if Path::new(&p1).exists() || disk.contains("nvme") || disk.contains("mmcblk") {
        (format!("{}p1", disk), format!("{}p2", disk))
    } else {
        (format!("{}1", disk), format!("{}2", disk))
    }
}

pub fn do_partition(s: &mut InstallSettings, log: &mut LogFn) -> Result<(), String> {
    // wipes the disk for real, esp first then root, no going back after this
    sh_log(log, &format!("Partitioning {} writing GPT", s.disk));
    for cmd in ["sfdisk", "mkfs.vfat", "mkfs.ext4", "blkid"] {
        if run_capture("command", &["-v", cmd]).is_empty() && Command::new(cmd).arg("--help").output().is_err() {
            let probe = Command::new("sh").args(["-c", &format!("command -v {}", cmd)]).output();
            let found = probe.map(|o| !o.stdout.is_empty()).unwrap_or(false);
            if !found {
                return Err(format!("{} not found on the install medium", cmd));
            }
        }
    }
    let _ = run("wipefs", &["-a", &s.disk]);
    let sfdisk_input = "label: gpt\n, 1G, U\n, , L\n";
    let ok = Command::new("sfdisk")
        .args(["--no-reread", &s.disk])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            if let Some(stdin) = child.stdin.as_mut() {
                let _ = stdin.write_all(sfdisk_input.as_bytes());
            }
            child.wait()
        })
        .map(|st| st.success())
        .unwrap_or(false);
    if !ok {
        let ok2 = Command::new("sfdisk")
            .arg(&s.disk)
            .stdin(Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                if let Some(stdin) = child.stdin.as_mut() {
                    let _ = stdin.write_all(sfdisk_input.as_bytes());
                }
                child.wait()
            })
            .map(|st| st.success())
            .unwrap_or(false);
        if !ok2 {
            return Err(format!("couldn't write partition table to {}", s.disk));
        }
    }
    let _ = run("partprobe", &[&s.disk]);
    let _ = run("blockdev", &["--rereadpt", &s.disk]);
    let (bootp, rootp) = part_devs(&s.disk);
    let mut waited = 0;
    while (!Path::new(&bootp).exists() || !Path::new(&rootp).exists()) && waited < 50 {
        std::thread::sleep(std::time::Duration::from_millis(200));
        waited += 1;
        if waited == 20 {
            let _ = run("blockdev", &["--rereadpt", &s.disk]);
        }
    }
    if !Path::new(&bootp).exists() || !Path::new(&rootp).exists() {
        return Err(format!("partitioning failed, no partitions on {}", s.disk));
    }
    s.bootp = bootp.clone();
    s.rootp = rootp.clone();
    sh_log(log, &format!("Formatting {} FAT32 and {} {}", bootp, rootp, s.fstype));
    if !run("mkfs.vfat", &["-F", "32", "-n", "SILENBOOT", &bootp]) {
        return Err(format!("couldn't format {} as FAT32", bootp));
    }
    match s.fstype.as_str() {
        "btrfs" => {
            if !run("mkfs.btrfs", &["-f", "-L", "silenroot", &rootp]) {
                return Err("couldn't format the partitions".into());
            }
        }
        "vfat" => {
            if !run("mkfs.vfat", &["-F", "32", "-n", "silenroot", &rootp]) {
                return Err("couldn't format the partitions".into());
            }
        }
        _ => {
            if !run("mkfs.ext4", &["-F", "-q", "-L", "silenroot", "-E", "nodiscard,lazy_itable_init=1,lazy_journal_init=1", &rootp]) {
                if !run("mkfs.ext4", &["-F", "-L", "silenroot", "-E", "nodiscard", &rootp]) {
                    return Err("couldn't format the partitions".into());
                }
            }
        }
    }
    Ok(())
}

fn chroot_run(root: &str, cmd: &str) -> bool {
    Command::new("chroot")
        .args([root, "/bin/bash", "-c", cmd])
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn fix_permissions(log: &mut LogFn) {
    let r = ROOT_PATH;
    if !Path::new(&format!("{}/bin/bash", r)).exists() {
        let _ = std::os::unix::fs::symlink("/usr/bin/bash", format!("{}/bin/bash", r));
    }
    if !Path::new(&format!("{}/bin/sh", r)).exists() {
        let _ = std::os::unix::fs::symlink("bash", format!("{}/bin/sh", r));
    }
    for rel in ["bin/su", "usr/bin/su", "bin/passwd", "usr/bin/passwd", "usr/bin/chage", "usr/bin/chfn", "usr/bin/chsh", "usr/bin/gpasswd", "usr/bin/newgrp", "bin/mount", "usr/bin/mount", "bin/umount", "usr/bin/umount", "usr/bin/sudo", "bin/sudo", "usr/bin/sudoedit", "bin/sudoedit"] {
        let p = format!("{}/{}", r, rel);
        if Path::new(&p).exists() && !Path::new(&p).is_symlink() {
            let _ = Command::new("chown").args(["root:root", &p]).status();
            let _ = Command::new("chmod").args(["4755", &p]).status();
        }
    }
    for rel in ["bin/unix_chkpwd", "usr/bin/unix_chkpwd", "sbin/unix_chkpwd", "usr/sbin/unix_chkpwd"] {
        let p = format!("{}/{}", r, rel);
        if Path::new(&p).exists() && !Path::new(&p).is_symlink() {
            let _ = Command::new("chown").args(["root:shadow", &p]).status();
            let _ = Command::new("chmod").args(["4755", &p]).status();
        }
    }
    for (f, mode) in [("etc/shadow", "640"), ("etc/gshadow", "640")] {
        let p = format!("{}/{}", r, f);
        if Path::new(&p).exists() {
            let _ = Command::new("chown").args(["root:shadow", &p]).status();
            let _ = Command::new("chmod").args([mode, &p]).status();
        }
    }
    let sudoers = format!("{}/etc/sudoers", r);
    if !Path::new(&sudoers).exists() || Path::new(&sudoers).is_symlink() {
        let _ = fs::write(&sudoers, "## Silen Linux sudoers\nroot ALL=(ALL:ALL) ALL\n%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n## Read drop-in files from /etc/sudoers.d\n@includedir /etc/sudoers.d\n");
    }
    let _ = Command::new("chown").args(["root:root", &sudoers]).status();
    let _ = Command::new("chmod").args(["440", &sudoers]).status();
    let _ = fs::create_dir_all(format!("{}/etc/pam.d", r));
    for pam in ["sudo", "sudo-i"] {
        let p = format!("{}/etc/pam.d/{}", r, pam);
        if !Path::new(&p).exists() {
            let _ = fs::write(&p, "auth\tinclude\t\tsystem-auth\naccount\tinclude\t\tsystem-auth\nsession\tinclude\t\tsystem-auth\n");
        }
        let _ = Command::new("chmod").args(["644", &p]).status();
    }
    // DEBUG: fixed wheel/sudo groups missing on target
    for g in ["wheel", "sudo"] {
        if !chroot_run(r, &format!("getent group {}", g)) {
            let _ = chroot_run(r, &format!("groupadd -r {}", g));
        }
    }
    sh_log(log, "permissions fixed");
}

pub fn apply_settings(s: &InstallSettings, log: &mut LogFn) {
    let r = ROOT_PATH;
    let zone_src = format!("{}/usr/share/zoneinfo/{}", r, s.zone);
    if Path::new(&zone_src).exists() {
        let _ = fs::remove_file(format!("{}/etc/localtime", r));
        let _ = std::os::unix::fs::symlink(format!("/usr/share/zoneinfo/{}", s.zone), format!("{}/etc/localtime", r));
    } else {
        sh_log(log, &format!("timezone {} missing in target", s.zone));
        let _ = std::os::unix::fs::symlink(format!("/usr/share/zoneinfo/{}", s.zone), format!("{}/etc/localtime", r));
    }
    let _ = fs::create_dir_all(format!("{}/etc/conf.d", r));
    let _ = fs::write(format!("{}/etc/conf.d/keymaps", r), format!("keymap=\"{}\"\n", s.keymap));
    let _ = fs::write(format!("{}/etc/locale.gen", r), format!("{} UTF-8\n", s.locale));
    if !chroot_run(r, "locale-gen") {
        sh_log(log, "couldn't generate locales");
    }
    let _ = fs::create_dir_all(format!("{}/etc/env.d", r));
    let _ = fs::write(format!("{}/etc/env.d/02locale", r), format!("LANG=\"{}\"\n", s.locale));
    if !s.want_swap.is_empty() {
        match s.want_swap.as_str() {
            "1G" | "2G" | "4G" | "8G" => {
                if !chroot_run(r, &format!("fallocate -l {} /swapfile && chmod 600 /swapfile && mkswap /swapfile", s.want_swap)) {
                    sh_log(log, "couldn't create the swapfile");
                }
            }
            _ => {}
        }
    }
    let _ = fs::write(format!("{}/etc/motd", r), "Welcome to Silen Linux\n");
    let _ = fs::create_dir_all(format!("{}/etc/sudoers.d", r));
    let _ = fs::write(format!("{}/etc/sudoers.d/10-silen", r), "%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n");
    let _ = Command::new("chown").args(["root:root", &format!("{}/etc/sudoers.d/10-silen", r)]).status();
    let _ = Command::new("chmod").args(["0440", &format!("{}/etc/sudoers.d/10-silen", r)]).status();
    let _ = fs::write(format!("{}/etc/profile.d/silen-hostname.sh", r), "if [ -f /etc/hostname ]; then\n    HOSTNAME=$(cat /etc/hostname 2>/dev/null)\n    export HOSTNAME\nfi\n");
    let _ = fs::write(format!("{}/etc/bash.bashrc", r), "[ -f /etc/profile.d/silen-hostname.sh ] && . /etc/profile.d/silen-hostname.sh\nif [ -f /etc/bash_completion ]; then\n    . /etc/bash_completion\nfi\n");
}

pub fn create_user(s: &InstallSettings, log: &mut LogFn) {
    if s.newuser.is_empty() {
        return;
    }
    let r = ROOT_PATH;
    if !chroot_run(r, "command -v useradd") {
        sh_log(log, &format!("couldn't create user {} (no useradd)", s.newuser));
        return;
    }
    // DEBUG: fixed wheel/sudo groups missing before useradd
    for g in ["wheel", "sudo"] {
        if !chroot_run(r, &format!("getent group {}", g)) {
            let _ = chroot_run(r, &format!("groupadd -r {}", g));
        }
    }
    let mut groups: Vec<String> = Vec::new();
    for g in ["wheel", "sudo", "audio", "video", "network", "plugdev"] {
        if chroot_run(r, &format!("getent group {}", g)) {
            groups.push(g.into());
        }
    }
    let uflags = if groups.is_empty() { "-m -s /bin/bash".to_string() } else { format!("-m -s /bin/bash -G {}", groups.join(",")) };
    if !chroot_run(r, &format!("useradd {} {}", uflags, s.newuser)) {
        sh_log(log, &format!("couldn't create user {}", s.newuser));
        return;
    }
    // DEBUG: fixed chpasswd quoting breaking on ' in password
    let esc_user = s.newuser.replace('\'', "'\\''");
    let esc_pass = s.userpass.replace('\'', "'\\''");
    let script = format!("printf '%s:%s\\n' '{}' '{}' | chpasswd", esc_user, esc_pass);
    if !chroot_run(r, &script) {
        sh_log(log, &format!("user {} created but password couldn't be set", s.newuser));
    }
    // DEBUG: fixed locked account never unlocked (passwd -S pattern)
    if chroot_run(r, &format!("passwd -S {} 2>/dev/null | grep -q '^{} L[[:space:]]'", s.newuser, s.newuser)) {
        let _ = chroot_run(r, &format!("passwd -u {} 2>/dev/null", s.newuser));
    }
    let _ = chroot_run(r, &format!("usermod -aG wheel {0} 2>/dev/null || gpasswd -a {0} wheel 2>/dev/null", s.newuser));
    if chroot_run(r, "getent group sudo") {
        let _ = chroot_run(r, &format!("usermod -aG sudo {0} 2>/dev/null || gpasswd -a {0} sudo 2>/dev/null", s.newuser));
    }
    if !chroot_run(r, &format!("id -nG {} 2>/dev/null | grep -qw wheel", s.newuser)) {
        sh_log(log, &format!("user {} is not in wheel, run: usermod -aG wheel {}", s.newuser, s.newuser));
    }
    // DEBUG: fixed sudo test failing even when sudoers is correct
    let _ = fs::create_dir_all(format!("{}/etc/sudoers.d", r));
    if !Path::new(&format!("{}/etc/sudoers.d/10-silen", r)).exists() {
        let _ = fs::write(format!("{}/etc/sudoers.d/10-silen", r), "%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n");
    }
    let _ = Command::new("chown").args(["root:root", &format!("{}/etc/sudoers", r)]).status();
    let _ = Command::new("chmod").args(["440", &format!("{}/etc/sudoers", r)]).status();
    let _ = Command::new("chown").args(["root:root", &format!("{}/etc/sudoers.d/10-silen", r)]).status();
    let _ = Command::new("chmod").args(["440", &format!("{}/etc/sudoers.d/10-silen", r)]).status();
    if !chroot_run(r, &format!("sudo -U {} -l 2>/dev/null | grep -q '(ALL'", s.newuser))
        && !chroot_run(r, &format!("su -s /bin/sh {} -c 'sudo -n true' 2>/dev/null", s.newuser))
    {
        sh_log(log, &format!("sudo doesn't work for {} yet, run: passwd {}; chown root:root /etc/sudoers /etc/sudoers.d/*; chmod 440 /etc/sudoers /etc/sudoers.d/*", s.newuser, s.newuser));
    }
    let _ = fs::create_dir_all(format!("{}/home/{}/.local/bin", r, s.newuser));
    let _ = chroot_run(r, &format!("chown -R {0}:{0} /home/{0}/.local 2>/dev/null; chown {0} /home/{0} 2>/dev/null; chmod 755 /home/{0} 2>/dev/null", s.newuser));
    sh_log(log, &format!("user {} created", s.newuser));
}

pub fn install_branding(s: &InstallSettings, log: &mut LogFn) {
    let mut logo_src = String::new();
    for f in ["/mnt/branding/fastfetch_logo.txt", "/mnt/fastfetch_logo.txt"] {
        if Path::new(f).exists() {
            logo_src = f.into();
            break;
        }
    }
    if logo_src.is_empty() {
        return;
    }
    let r = ROOT_PATH;
    let _ = fs::create_dir_all(format!("{}/usr/share/silen", r));
    let _ = fs::copy(&logo_src, format!("{}/usr/share/silen/fastfetch_logo.txt", r));
    if Path::new("/mnt/branding/info.txt").exists() {
        let _ = fs::copy("/mnt/branding/info.txt", format!("{}/usr/share/silen/info.txt", r));
    }
    let _ = fs::create_dir_all(format!("{}/usr/local/bin", r));
    let _ = fs::write(format!("{}/usr/local/bin/silenfetch", r), "#!/bin/sh\ncommand -v fastfetch >/dev/null 2>&1 || { echo \"silenfetch: fastfetch is not installed (sudo spk get fastfetch)\" >&2; exit 127; }\nexec fastfetch -l /usr/share/silen/fastfetch_logo.txt \"$@\"\n");
    let _ = Command::new("chmod").args(["755", &format!("{}/usr/local/bin/silenfetch", r)]).status();
    let cfg = "{\n    \"logo\": {\n        \"type\": \"file\",\n        \"source\": \"/usr/share/silen/fastfetch_logo.txt\",\n        \"padding\": { \"top\": 0, \"left\": 1, \"right\": 3 }\n    },\n    \"modules\": [ \"title\", \"separator\", \"os\", \"host\", \"kernel\", \"uptime\", \"shell\", \"cpu\", \"memory\", \"disk\", \"break\", \"colors\" ]\n}\n";
    for d in ["etc/fastfetch", "etc/xdg/fastfetch", "etc/skel/.config/fastfetch", "root/.config/fastfetch"] {
        let _ = fs::create_dir_all(format!("{}/{}", r, d));
    }
    let _ = fs::write(format!("{}/etc/fastfetch/config.jsonc", r), cfg);
    let _ = fs::copy(format!("{}/etc/fastfetch/config.jsonc", r), format!("{}/etc/xdg/fastfetch/config.jsonc", r));
    let _ = fs::copy(format!("{}/etc/fastfetch/config.jsonc", r), format!("{}/etc/skel/.config/fastfetch/config.jsonc", r));
    let _ = fs::copy(format!("{}/etc/fastfetch/config.jsonc", r), format!("{}/root/.config/fastfetch/config.jsonc", r));
    if !s.newuser.is_empty() {
        let _ = fs::create_dir_all(format!("{}/home/{}/.config/fastfetch", r, s.newuser));
        let _ = fs::copy(format!("{}/etc/fastfetch/config.jsonc", r), format!("{}/home/{}/.config/fastfetch/config.jsonc", r, s.newuser));
    }
    sh_log(log, "branding installed");
}

pub fn setup_root_shell() {
    let r = ROOT_PATH;
    let _ = fs::create_dir_all(format!("{}/root", r));
    if !Path::new(&format!("{}/root/.bashrc", r)).exists() {
        let _ = fs::write(format!("{}/root/.bashrc", r), "[ -f /etc/profile.d/silen-hostname.sh ] && . /etc/profile.d/silen-hostname.sh\nPS1='\\u@\\h \\w \\$ '\nalias ls='ls --color=auto'\nalias silenfetch='fastfetch -l /usr/share/silen/fastfetch_logo.txt'\n");
    }
    if !Path::new(&format!("{}/root/.bash_profile", r)).exists() {
        let _ = fs::write(format!("{}/root/.bash_profile", r), "[ -f ~/.bashrc ] && . ~/.bashrc\n");
    }
}

pub fn setup_quiet_boot() {
    let r = ROOT_PATH;
    let inittab = format!("{}/etc/inittab", r);
    if Path::new(&inittab).exists() {
        if let Ok(t) = fs::read_to_string(&inittab) {
            let t = t.replace("/sbin/openrc sysinit", "/sbin/openrc --quiet sysinit").replace("/sbin/openrc boot", "/sbin/openrc --quiet boot").replace("/sbin/openrc shutdown", "/sbin/openrc --quiet shutdown").replace("/sbin/openrc default", "/sbin/openrc --quiet default");
            let _ = fs::write(&inittab, t);
        }
    }
    // DEBUG: fixed blind service failures, always ensure boot logging exists
    let rcconf = format!("{}/etc/rc.conf", r);
    let has_active = fs::read_to_string(&rcconf).map(|t| t.lines().any(|l| { let s = l.trim_start(); s.starts_with("rc_logger=") })).unwrap_or(false);
    if !has_active {
        let mut cur = fs::read_to_string(&rcconf).unwrap_or_default();
        if !cur.is_empty() && !cur.ends_with('\n') {
            cur.push('\n');
        }
        cur.push_str("rc_logger=\"YES\"\n");
        let _ = fs::write(&rcconf, cur);
    }
}


pub fn install_modules(s: &mut InstallSettings, log: &mut LogFn) {
    let r = ROOT_PATH;
    let _ = fs::create_dir_all(format!("{}/lib/modules", r));
    let mut kernel_tar = String::new();
    if let Ok(entries) = fs::read_dir("/mnt") {
        for e in entries.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if n.starts_with("kernel-") && (n.contains(".tar.")) {
                kernel_tar = format!("/mnt/{}", n);
                break;
            }
        }
    }
    if !kernel_tar.is_empty() {
        let base = kernel_tar.rsplit('/').next().unwrap_or("");
        let mut kver = base.trim_start_matches("kernel-").to_string();
        for suffix in [".tar.zst", ".tar.xz", ".tar.gz"] {
            if let Some(stripped) = kver.strip_suffix(suffix) {
                kver = stripped.to_string();
                break;
            }
        }
        sh_log(log, &format!("unpacking kernel {}", base));
        if !run("tar", &["-xpf", &kernel_tar, "-C", r, "--no-same-owner", "--numeric-owner"]) {
            sh_log(log, "couldn't unpack the kernel/modules");
        } else {
            s.kver = kver;
        }
    } else if Path::new("/mnt/modules").is_dir() {
        let _ = run_sh(&format!("cp -a /mnt/modules/. {}/lib/modules/ 2>/dev/null", r));
    } else if Path::new("/lib/modules").is_dir() {
        let _ = run_sh(&format!("cp -a /lib/modules/. {}/lib/modules/ 2>/dev/null", r));
    }
    if s.kver.is_empty() {
        if let Ok(mut entries) = fs::read_dir(format!("{}/lib/modules", r)) {
            if let Some(Ok(e)) = entries.next() {
                s.kver = e.file_name().to_string_lossy().to_string();
            }
        }
    }
    if !s.kver.is_empty() {
        let _ = chroot_run(r, &format!("depmod -a {}", s.kver));
    }
    let mut headers_tar = String::new();
    if let Ok(entries) = fs::read_dir("/mnt") {
        for e in entries.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if n.starts_with("headers-") && n.contains(".tar.") {
                headers_tar = format!("/mnt/{}", n);
                break;
            }
        }
    }
    if !headers_tar.is_empty() && run("tar", &["-xpf", &headers_tar, "-C", r, "--no-same-owner", "--numeric-owner"]) {
        if !s.kver.is_empty() && Path::new(&format!("{}/usr/src/linux-{}", r, s.kver)).is_dir() {
            let _ = std::os::unix::fs::symlink(format!("/usr/src/linux-{}", s.kver), format!("{}/lib/modules/{}/build", r, s.kver));
            let _ = std::os::unix::fs::symlink(format!("/usr/src/linux-{}", s.kver), format!("{}/lib/modules/{}/source", r, s.kver));
        }
    }
    if Path::new("/mnt/firmware").is_dir() {
        let _ = fs::create_dir_all(format!("{}/lib/firmware", r));
        let _ = run_sh(&format!("cp -a /mnt/firmware/. {}/lib/firmware/ 2>/dev/null", r));
    }
    if Path::new("/lib/firmware").is_dir() {
        let _ = run_sh(&format!("mkdir -p {0}/lib/firmware; cp -an /lib/firmware/. {0}/lib/firmware/ 2>/dev/null; cp -a /lib/firmware/. {0}/lib/firmware/ 2>/dev/null", r));
    }
    let _ = fs::create_dir_all(format!("{}/etc/modprobe.d", r));
    let _ = fs::write(format!("{}/etc/modprobe.d/silen-rtw88.conf", r), "options rtw88_pci disable_aspm=Y\noptions rtw88_core disable_lps_deep=Y\n");
    let _ = chroot_run(r, "rc-update add udev sysinit");
    sh_log(log, &format!("kernel modules ready ({})", if s.kver.is_empty() { "unknown" } else { &s.kver }));
}

pub fn install_spk(log: &mut LogFn) {
    let r = ROOT_PATH;
    let mut spk_src = String::new();
    if let Ok(entries) = fs::read_dir("/mnt") {
        for e in entries.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if n.starts_with("spk.tar") {
                spk_src = format!("/mnt/{}", n);
                break;
            }
        }
    }
    if !spk_src.is_empty() {
        sh_log(log, "installing spk from bundle");
        let tmp = "/tmp/spk-install-rs";
        let _ = fs::create_dir_all(tmp);
        if run("tar", &["-xpf", &spk_src, "-C", tmp, "--no-same-owner", "--numeric-owner"]) {
            if Path::new(&format!("{}/usr/bin/spk", tmp)).exists() {
                let _ = fs::create_dir_all(format!("{}/usr/bin", r));
                let _ = fs::copy(format!("{}/usr/bin/spk", tmp), format!("{}/usr/bin/spk", r));
                let _ = Command::new("chmod").args(["755", &format!("{}/usr/bin/spk", r)]).status();
                let _ = fs::remove_dir_all(tmp);
                if Path::new(&format!("{}/usr/bin/spk", r)).exists() {
                    return;
                }
            }
        }
        let _ = fs::remove_dir_all(tmp);
    }
    if Path::new("/usr/bin/spk").exists() {
        let _ = fs::create_dir_all(format!("{}/usr/bin", r));
        let _ = fs::copy("/usr/bin/spk", format!("{}/usr/bin/spk", r));
        if Path::new(&format!("{}/usr/bin/spk", r)).exists() {
            return;
        }
        sh_log(log, "couldn't install live spk");
    }
    if Path::new("/mnt/spk").exists() && Path::new("/mnt/spk").is_file() {
        let _ = fs::copy("/mnt/spk", format!("{}/usr/bin/spk", r));
    }
}

pub fn install_network(log: &mut LogFn) {
    let r = ROOT_PATH;
    let mut net_tar = String::new();
    if let Ok(entries) = fs::read_dir("/mnt") {
        for e in entries.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if n.starts_with("network.tar") {
                net_tar = format!("/mnt/{}", n);
                break;
            }
        }
    }
    if !net_tar.is_empty() {
        sh_log(log, "unpacking network bundle");
        if !run("tar", &["-xpf", &net_tar, "-C", r, "--skip-old-files", "--no-same-owner", "--numeric-owner"]) {
            let _ = run("tar", &["-xpf", &net_tar, "-C", r, "--no-same-owner", "--numeric-owner"]);
        }
    }
    if !Path::new(&format!("{}/usr/libexec/iwd", r)).exists() {
        sh_log(log, "copying network stack from live");
        for d in ["usr/bin", "usr/libexec", "usr/lib", "usr/lib64"] {
            let _ = fs::create_dir_all(format!("{}/{}", r, d));
        }
        for b in ["iwd"] {
            for src in [format!("/usr/libexec/{}", b), format!("/usr/sbin/{}", b), format!("/usr/bin/{}", b)] {
                if Path::new(&src).exists() {
                    let _ = fs::copy(&src, format!("{}/usr/libexec/{}", r, b));
                    break;
                }
            }
        }
        for b in ["iwctl", "iwmon", "dbus-daemon", "dbus-uuidgen"] {
            for src in [format!("/usr/bin/{}", b), format!("/usr/sbin/{}", b)] {
                if Path::new(&src).exists() {
                    let _ = fs::copy(&src, format!("{}/usr/bin/{}", r, b));
                    break;
                }
            }
        }
    }
    for d in ["etc/iwd", "usr/share/dbus-1/system.d", "run/dbus", "run/user", "var/lib/iwd", "var/lib/dbus", "etc/init.d"] {
        let _ = fs::create_dir_all(format!("{}/{}", r, d));
    }
    if Path::new("/etc/iwd/main.conf").exists() {
        let _ = fs::copy("/etc/iwd/main.conf", format!("{}/etc/iwd/main.conf", r));
    }
    if !Path::new(&format!("{}/etc/iwd/main.conf", r)).exists() {
        let _ = fs::write(format!("{}/etc/iwd/main.conf", r), "[General]\nEnableNetworkConfiguration=true\n");
    }
    if !Path::new(&format!("{}/usr/share/dbus-1/system.d/iwd-dbus.conf", r)).exists() && Path::new("/usr/share/dbus-1/system.d/iwd-dbus.conf").exists() {
        let _ = fs::copy("/usr/share/dbus-1/system.d/iwd-dbus.conf", format!("{}/usr/share/dbus-1/system.d/iwd-dbus.conf", r));
    }
    let dbus_init = "#!/sbin/openrc-run\ncommand=/usr/bin/dbus-daemon\ncommand_args=\"--system --fork\"\npidfile=/run/dbus/pid\nname=\"D-Bus system daemon\"\n\ndepend() {\n\tneed localmount\n\tafter bootmisc\n}\n\nstart_pre() {\n\tmkdir -p /run/dbus\n\tif [ ! -s /etc/machine-id ] && [ -x /usr/bin/dbus-uuidgen ]; then\n\t\t/usr/bin/dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null || /usr/bin/dbus-uuidgen --ensure 2>/dev/null || true\n\tfi\n\tif [ ! -s /var/lib/dbus/machine-id ] && [ -s /etc/machine-id ]; then\n\t\tcp /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true\n\tfi\n}\n";
    let _ = fs::write(format!("{}/etc/init.d/dbus", r), dbus_init);
    let iwd_cmd = if Path::new(&format!("{}/usr/libexec/iwd", r)).exists() { "/usr/libexec/iwd" } else { "/usr/bin/iwd" };
    let iwd_init = format!("#!/sbin/openrc-run\ncommand={}\npidfile=/run/iwd.pid\ncommand_background=\"yes\"\nname=\"iwd wireless daemon\"\n\ndepend() {{\n\tneed dbus localmount\n\tafter bootmisc modules\n\tprovide net\n}}\n\nstart_pre() {{\n\tmkdir -p /var/lib/iwd 2>/dev/null || true\n\tif command -v rfkill >/dev/null 2>&1; then\n\t\trfkill unblock all >/dev/null 2>&1 || true\n\tfi\n}}\n", iwd_cmd);
    let _ = fs::write(format!("{}/etc/init.d/iwd", r), iwd_init);
    let _ = Command::new("chmod").args(["755", &format!("{}/etc/init.d/dbus", r)]).status();
    let _ = Command::new("chmod").args(["755", &format!("{}/etc/init.d/iwd", r)]).status();
    let _ = chroot_run(r, "ldconfig");
    let _ = chroot_run(r, "rc-update add dbus default");
    let _ = chroot_run(r, "rc-update add iwd default");
    let _ = chroot_run(r, "rc-update add modules boot");
    let _ = chroot_run(r, "rc-update add local default");
    sh_log(log, "network installed");
}

pub fn install_nvidia_auto(s: &InstallSettings, log: &mut LogFn) {
    if !Path::new("/mnt/nvidia-auto").exists() {
        return;
    }
    let mut nv_run = String::new();
    if let Ok(entries) = fs::read_dir("/mnt") {
        for e in entries.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if n.starts_with("nvidia-") && n.ends_with(".run") {
                nv_run = format!("/mnt/{}", n);
                break;
            }
        }
    }
    if nv_run.is_empty() {
        sh_log(log, "nvidia flag found but no .run on medium");
        return;
    }
    let mut has_nv = false;
    if let Ok(entries) = fs::read_dir("/sys/bus/pci/devices") {
        for e in entries.flatten() {
            let vend = fs::read_to_string(e.path().join("vendor")).unwrap_or_default();
            let class = fs::read_to_string(e.path().join("class")).unwrap_or_default();
            if vend.trim() == "0x10de" && class.trim().starts_with("0x03") {
                has_nv = true;
                break;
            }
        }
    }
    if !has_nv {
        sh_log(log, "no NVIDIA GPU found, skipping proprietary driver");
        return;
    }
    // DEBUG: fixed modern driver breaking pre-Maxwell GPUs, Fermi/Kepler need 390 legacy so stay on nouveau
    let nv_major: u32 = nv_run
        .rsplit('/')
        .next()
        .unwrap_or("")
        .trim_start_matches("nvidia-")
        .split('.')
        .next()
        .unwrap_or("")
        .parse()
        .unwrap_or(999);
    if nv_major >= 550 {
        let mut supported = false;
        if let Ok(entries) = fs::read_dir("/sys/bus/pci/devices") {
            for e in entries.flatten() {
                let vend = fs::read_to_string(e.path().join("vendor")).unwrap_or_default();
                let class = fs::read_to_string(e.path().join("class")).unwrap_or_default();
                if vend.trim() != "0x10de" || !class.trim().starts_with("0x03") {
                    continue;
                }
                let dev = fs::read_to_string(e.path().join("device")).unwrap_or_default();
                if let Ok(id) = u32::from_str_radix(dev.trim().trim_start_matches("0x"), 16) {
                    if id > 0x133f {
                        supported = true;
                        break;
                    }
                }
            }
        }
        if !supported {
            sh_log(log, &format!("NVIDIA GPU predates {}.x support (needs 390 legacy), staying on nouveau; nvidia-smi will not work, desktop uses software rendering", nv_major));
            return;
        }
    }
    let kver = if s.kver.is_empty() {
        fs::read_dir(format!("{}/lib/modules", ROOT_PATH)).ok().and_then(|mut it| it.next()).and_then(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).unwrap_or_default()
    } else {
        s.kver.clone()
    };
    if kver.is_empty() || !Path::new(&format!("{}/usr/src/linux-{}/Makefile", ROOT_PATH, kver)).exists() {
        sh_log(log, "kernel headers missing, skipping NVIDIA driver");
        return;
    }
    let mut kmods = String::new();
    if let Ok(entries) = fs::read_dir("/mnt") {
        for e in entries.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if n.starts_with("nvidia-kmods-") {
                kmods = format!("/mnt/{}", n);
                break;
            }
        }
    }
    if kmods.is_empty() {
        sh_log(log, "no prebuilt NVIDIA driver, continuing with nouveau");
        return;
    }
    let km_base = kmods.rsplit('/').next().unwrap_or("");
    let km_kver = km_base.trim_start_matches("nvidia-kmods-").split(".tar.").next().unwrap_or("").to_string();
    if !km_kver.is_empty() && km_kver != kver {
        sh_log(log, &format!("prebuilt NVIDIA driver is for {} but the system is {}, continuing with nouveau", km_kver, kver));
        return;
    }
    sh_log(log, "installing NVIDIA driver");
    let _ = fs::write(format!("{}/etc/modprobe.d/nvidia-disable-nouveau.conf", ROOT_PATH), "blacklist nouveau\noptions nouveau modeset=0\n");
    if !run("tar", &["-xpf", &kmods, "-C", ROOT_PATH, "--no-same-owner", "--numeric-owner"]) {
        let _ = fs::remove_file(format!("{}/etc/modprobe.d/nvidia-disable-nouveau.conf", ROOT_PATH));
        sh_log(log, "couldn't unpack prebuilt NVIDIA driver");
        return;
    }
    let _ = chroot_run(ROOT_PATH, &format!("depmod -a {}", kver));
    let has_ko = Command::new("find").args([format!("{}/lib/modules", ROOT_PATH), "-iname".to_string(), "nvidia.ko*".to_string()]).output().map(|o| !o.stdout.is_empty()).unwrap_or(false);
    if !has_ko {
        let _ = fs::remove_file(format!("{}/etc/modprobe.d/nvidia-disable-nouveau.conf", ROOT_PATH));
        sh_log(log, "prebuilt NVIDIA modules missing after unpack, continuing with nouveau");
        return;
    }
    // DEBUG: fixed blacklisting nouveau for a GPU the driver cannot see, probe first
    let ko = format!("{}/lib/modules/{}/updates/nvidia.ko", ROOT_PATH, kver);
    if Path::new(&ko).exists() {
        match Command::new("insmod").arg(&ko).output() {
            Ok(o) if o.status.success() => {
                let _ = run("rmmod", &["nvidia"]);
            }
            Ok(o) => {
                let err = String::from_utf8_lossy(&o.stderr).to_string();
                if err.contains("No such device") {
                    let _ = fs::remove_file(format!("{}/etc/modprobe.d/nvidia-disable-nouveau.conf", ROOT_PATH));
                    sh_log(log, "NVIDIA driver cannot see any supported GPU here (probe: No such device), staying on nouveau");
                    return;
                }
            }
            Err(_) => {}
        }
    }
    let _ = fs::copy(&nv_run, format!("{}/tmp/nvidia.run", ROOT_PATH));
    // DEBUG: fixed .run refusing while live nouveau holds the GPU, blacklist+reboot handles it instead
    let ok = chroot_run(ROOT_PATH, "sh /tmp/nvidia.run --silent --accept-license --no-questions -z --no-x-check --no-dkms --no-systemd --no-distro-scripts --no-kernel-modules --no-nouveau-check >>/tmp/nvidia-install.log 2>&1");
    if ok {
        let _ = chroot_run(ROOT_PATH, &format!("depmod -a {}", kver));
        let _ = chroot_run(ROOT_PATH, "ldconfig");
        let _ = fs::create_dir_all(format!("{}/var/log", ROOT_PATH));
        let _ = fs::copy(format!("{}/tmp/nvidia-install.log", ROOT_PATH), format!("{}/var/log/nvidia-install.log", ROOT_PATH));
        let _ = fs::create_dir_all(format!("{}/usr/src", ROOT_PATH));
        if let Some(base) = nv_run.rsplit('/').next() {
            let _ = fs::copy(&nv_run, format!("{}/usr/src/{}", ROOT_PATH, base));
        }
        // DEBUG: fixed nvidia-smi failing, modules never loaded and nouveau kept the GPU
        let _ = fs::create_dir_all(format!("{}/etc/modules-load.d", ROOT_PATH));
        let _ = fs::write(format!("{}/etc/modules-load.d/nvidia.conf", ROOT_PATH), "nvidia\nnvidia_modeset\nnvidia_drm\nnvidia_uvm\n");
        let confd = format!("{}/etc/conf.d/modules", ROOT_PATH);
        if Path::new(&confd).exists() {
            let cur = fs::read_to_string(&confd).unwrap_or_default();
            if !cur.contains("nvidia") {
                let add = if cur.contains("modules=") { "\nmodules=\"$modules nvidia nvidia_modeset nvidia_drm nvidia_uvm\"\n" } else { "modules=\"nvidia nvidia_modeset nvidia_drm nvidia_uvm\"\n" };
                let _ = fs::write(&confd, format!("{}{}", cur, add));
            }
        }
        // DEBUG: fixed dead display when nvidia never binds, first healthy boot keeps it, else nouveau returns
        let _ = fs::create_dir_all(format!("{}/etc/local.d", ROOT_PATH));
        let _ = fs::write(format!("{}/etc/local.d/nvidia-fallback.start", ROOT_PATH), "#!/bin/sh\n# if the proprietary modules never bound, unblock nouveau so the next boot has a GPU\nLOG=/var/log/nvidia-fallback.log\nCONF=/etc/modprobe.d/nvidia-disable-nouveau.conf\n[ -f \"$CONF\" ] || exit 0\n_nv_alive=\"\"\nif command -v lsmod >/dev/null 2>&1; then\n\tlsmod 2>/dev/null | grep -q \"^nvidia \" && _nv_alive=\"1\"\nfi\n[ -e /dev/nvidia0 ] || [ -e /dev/nvidiactl ] && _nv_alive=\"1\"\n[ -n \"$_nv_alive\" ] && exit 0\necho \"$(date -u 2>/dev/null || date): nvidia absent, removing nouveau blacklist (reboot to apply)\" >>\"$LOG\" 2>&1\nrm -f \"$CONF\" /etc/modprobe.d/nvidia-installer-disable-nouveau.conf 2>/dev/null\nrm -f /etc/modules-load.d/nvidia.conf 2>/dev/null\nif [ -f /etc/conf.d/modules ]; then\n\tsed -i 's/ nvidia_modeset//g; s/ nvidia_drm//g; s/ nvidia_uvm//g; s/ nvidia//g' /etc/conf.d/modules 2>/dev/null || true\nfi\nif [ -f /boot/grub/grub.cfg ]; then\n\tsed -i 's/ modprobe\\.blacklist=nouveau//g; s/ nvidia-drm\\.modeset=1//g; s/ nvidia-drm\\.fbdev=1//g' /boot/grub/grub.cfg 2>/dev/null || true\nfi\necho \"$(date -u 2>/dev/null || date): blacklist removed, nouveau returns next boot\" >>\"$LOG\" 2>&1\n");
        let _ = Command::new("chmod").args(["0755", &format!("{}/etc/local.d/nvidia-fallback.start", ROOT_PATH)]).status();
        sh_log(log, "NVIDIA driver installed");
    } else {
        let _ = fs::remove_file(format!("{}/etc/modprobe.d/nvidia-disable-nouveau.conf", ROOT_PATH));
        let _ = fs::remove_file(format!("{}/etc/modules-load.d/nvidia.conf", ROOT_PATH));
        let confd = format!("{}/etc/conf.d/modules", ROOT_PATH);
        if let Ok(cur) = fs::read_to_string(&confd) {
            let scrubbed = cur.replace(" nvidia_modeset", "").replace(" nvidia_drm", "").replace(" nvidia_uvm", "").replace(" nvidia", "").replace("modules=\"\"", "");
            let _ = fs::write(&confd, scrubbed);
        }
        sh_log(log, "NVIDIA install failed, continuing with nouveau");
    }
    let _ = fs::remove_file(format!("{}/tmp/nvidia.run", ROOT_PATH));
}


// DEBUG: fixed nouveau binding the GPU before nvidia loads (live initramfs loads nouveau early)
fn nvidia_cmdline() -> String {
    if Path::new("/mnt/nvidia-auto").exists()
        && Path::new(&format!("{}/etc/modprobe.d/nvidia-disable-nouveau.conf", ROOT_PATH)).exists()
    {
        " modprobe.blacklist=nouveau nvidia-drm.modeset=1 nvidia-drm.fbdev=1".to_string()
    } else {
        String::new()
    }
}

pub fn setup_grub(s: &InstallSettings, log: &mut LogFn) -> Result<(), String> {
    let r = ROOT_PATH;
    if Path::new("/mnt/boot/vmlinuz").exists() {
        fs::copy("/mnt/boot/vmlinuz", format!("{}/boot/vmlinuz", r)).map_err(|_| "couldn't copy the kernel".to_string())?;
    } else {
        return Err("no kernel found on the install medium".into());
    }
    let mut initramfs_name = String::new();
    let mut copy_failed = false;
    for dir in ["/mnt/boot", "/mnt"] {
        if initramfs_name.is_empty() {
            if let Ok(entries) = fs::read_dir(dir) {
                for e in entries.flatten() {
                    let n = e.file_name().to_string_lossy().to_string();
                    if n.starts_with("initramfs.") && Path::new(&format!("{}/{}", dir, n)).is_file() {
                        let mut ok = false;
                        for _ in 0..3 {
                            if fs::copy(format!("{}/{}", dir, n), format!("{}/boot/{}", r, n)).is_ok() {
                                ok = true;
                                break;
                            }
                        }
                        if ok {
                            initramfs_name = n;
                            break;
                        }
                        copy_failed = true;
                    }
                }
            }
        }
    }
    if initramfs_name.is_empty() {
        if copy_failed {
            let probe = format!("{}/boot/.writetest", r);
            if fs::write(&probe, "x").is_ok() {
                let _ = fs::remove_file(&probe);
                return Err("found an initramfs on the medium but couldn't read it - bad USB write? Reflash and retry".into());
            }
            return Err("can't write to the new boot partition - repartition and retry".into());
        }
        return Err("no initramfs found in the install ISO".into());
    }
    if !is_efi() {
        return Err("this machine booted in legacy mode, but Silen can currently only install an EFI bootloader. Boot the iso in UEFI mode and try again.".into());
    }
    if Path::new("/mnt/grub/usr/local").is_dir() {
        let _ = fs::create_dir_all(format!("{}/usr/local", r));
        let _ = run_sh(&format!("cp -a /mnt/grub/usr/local/. {}/usr/local/ 2>/dev/null", r));
    }
    let _ = fs::create_dir_all(format!("{}/tmp", r));
    let _ = fs::create_dir_all(format!("{}/sys/firmware/efi/efivars", r));
    let _ = run("mount", &["-t", "efivarfs", "efivarfs", &format!("{}/sys/firmware/efi/efivars", r)]);
    let grub_log = format!("{}/tmp/grub-install.log", r);
    let inst1 = chroot_run(r, "PATH=/usr/local/sbin:/usr/local/bin:$PATH LD_LIBRARY_PATH=/usr/local/lib /usr/local/sbin/grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable >>/tmp/grub-install.log 2>&1");
    let inst2 = if !inst1 { chroot_run(r, "grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable >>/tmp/grub-install.log 2>&1") } else { true };
    if !inst2 {
        return Err("grub-install failed, see /tmp/grub-install.log".into());
    }
    let bootuuid = run_capture("blkid", &["-s", "UUID", "-o", "value", &s.bootp]);
    let rootuuid = run_capture("blkid", &["-s", "UUID", "-o", "value", &s.rootp]);
    if bootuuid.is_empty() || rootuuid.is_empty() {
        cleanup();
        return Err("couldn't read the partition UUIDs".into());
    }
    let grub_cfg = format!("set default=0\nset timeout=10\n\ninsmod part_gpt\ninsmod part_msdos\ninsmod fat\ninsmod ext2\ninsmod search_fs_uuid\ninsmod all_video\ninsmod gfxterm\ninsmod efi_gop\ninsmod efi_uga\nif loadfont $prefix/fonts/unicode.pf2; then\n    set gfxmode=auto\nfi\nterminal_output gfxterm console\nsearch --no-floppy --fs-uuid --set=root {}\n\nmenuentry \"Silen Linux\" {{\n    linux /vmlinuz root=UUID={} ro rootwait loglevel=4 console=ttyS0 console=tty0{}\n    initrd /{}\n}}\n", bootuuid, rootuuid, nvidia_cmdline(), initramfs_name);
    let _ = fs::write(format!("{}/boot/grub/grub.cfg", r), grub_cfg);
    let _ = chroot_run(r, "PATH=/usr/local/sbin:/usr/local/bin:$PATH LD_LIBRARY_PATH=/usr/local/lib /usr/local/sbin/grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --bootloader-id=Silen >>/tmp/grub-install.log 2>&1");
    let _ = grub_log;
    sh_log(log, "GRUB installed");
    Ok(())
}

pub fn do_install(s: &mut InstallSettings, log: &mut LogFn) -> Result<(), String> {
    // never wipe the disk the live medium is sitting on
    if !must_be_root() {
        return Err("this installer needs root".into());
    }
    if medium_on_disk(&s.disk) {
        return Err(format!("{} holds the install medium, pick a different disk", s.disk));
    }
    do_partition(s, log)?;
    let r = ROOT_PATH;
    let _ = fs::create_dir_all(r);
    if !run("mount", &[&s.rootp, r]) {
        return Err(format!("failed to mount {}", s.rootp));
    }
    let _ = fs::create_dir_all(format!("{}/boot", r));
    if !run("mount", &[&s.bootp, &format!("{}/boot", r)]) {
        cleanup();
        return Err(format!("failed to mount {}", s.bootp));
    }
    let stage3 = find_tarball().ok_or("no Silen tarball found on the install medium")?;
    sh_log(log, &format!("extracting {}", stage3));
    let single_top: bool = Command::new("tar").args(["-tf", &stage3]).output().map(|o| {
        let text = String::from_utf8_lossy(&o.stdout).to_string();
        let mut tops = std::collections::HashSet::new();
        for line in text.lines() {
            let l = line.trim_start_matches("./");
            if let Some(pos) = l.find('/') {
                tops.insert(l[..pos].to_string());
            }
        }
        tops.len() == 1
    }).unwrap_or(false);
    let ok = if single_top {
        run("tar", &["-xpf", &stage3, "-C", r, "--strip-components=1", "--no-same-owner", "--numeric-owner", "--xattrs-include=*.*"])
    } else {
        run("tar", &["-xpf", &stage3, "-C", r, "--no-same-owner", "--numeric-owner", "--xattrs-include=*.*"])
    };
    if !ok {
        cleanup();
        return Err("failed to unpack the system tarball".into());
    }
    fix_permissions(log);
    for d in ["proc", "sys", "dev", "run", "etc", "usr/share/zoneinfo"] {
        let _ = fs::create_dir_all(format!("{}/{}", r, d));
    }
    let _ = run("mount", &["-t", "proc", "proc", &format!("{}/proc", r)]);
    let _ = run("mount", &["-t", "sysfs", "sysfs", &format!("{}/sys", r)]);
    let _ = run("mount", &["--rbind", "/dev", &format!("{}/dev", r)]);
    let _ = run("mount", &["--rbind", "/run", &format!("{}/run", r)]);
    if Path::new(&format!("{}/etc/resolv.conf", r)).is_symlink() {
        let _ = fs::remove_file(format!("{}/etc/resolv.conf", r));
    }
    if let Ok(live_resolv) = fs::read_to_string("/etc/resolv.conf") {
        if live_resolv.contains("nameserver") {
            let _ = fs::write(format!("{}/etc/resolv.conf", r), live_resolv.replace("127.0.0.53\n", ""));
        }
    }
    if fs::read_to_string(format!("{}/etc/resolv.conf", r)).map(|t| !t.contains("nameserver")).unwrap_or(true) {
        let _ = fs::write(format!("{}/etc/resolv.conf", r), "nameserver 1.1.1.1\nnameserver 9.9.9.9\n");
    }
    let _ = fs::write(format!("{}/etc/hostname", r), format!("{}\n", s.hostname));
    let chpasswd_bin = ["/usr/bin/chpasswd", "/usr/sbin/chpasswd", "/bin/chpasswd", "/sbin/chpasswd"].iter().find(|c| Path::new(&format!("{}{}", r, c)).exists()).map(|s| s.to_string()).unwrap_or("/usr/bin/chpasswd".into());
    let script = format!("printf 'root:%s\\n' '{}' | {} 2>/dev/null", s.rootpass.replace('\'', "'\\''"), chpasswd_bin);
    if !chroot_run(r, &script) {
        sh_log(log, "couldn't set the root password");
    }
    let bootuuid = run_capture("blkid", &["-s", "UUID", "-o", "value", &s.bootp]);
    let rootuuid = run_capture("blkid", &["-s", "UUID", "-o", "value", &s.rootp]);
    if bootuuid.is_empty() || rootuuid.is_empty() {
        return Err("couldn't read the partition UUIDs".into());
    }
    let fspass = if s.fstype == "ext4" { "0 1" } else { "0 0" };
    let _ = fs::write(format!("{}/etc/fstab", r), format!("UUID={} / {} defaults {}\nUUID={} /boot vfat defaults 0 2\n", rootuuid, s.fstype, fspass, bootuuid));
    apply_settings(s, log);
    let has_swap = Path::new(&format!("{}/swapfile", r)).exists();
    if has_swap {
        let mut fstab = fs::read_to_string(format!("{}/etc/fstab", r)).unwrap_or_default();
        fstab.push_str("/swapfile none swap sw 0 0\n");
        let _ = fs::write(format!("{}/etc/fstab", r), fstab);
    }
    let _ = chroot_run(r, "ldconfig");
    sh_log(log, "copying kernel and drivers");
    install_modules(s, log);
    sh_log(log, "installing packages and network");
    install_spk(log);
    install_network(log);
    install_nvidia_auto(s, log);
    sh_log(log, "creating users and finishing setup");
    create_user(s, log);
    install_branding(s, log);
    let _ = fs::create_dir_all(format!("{}/usr/share/silen", r));
    let _ = fs::write(format!("{}/usr/share/silen/spk-help.txt", r), "spk - Silen package manager\n\n  sudo spk get <package>   install\n  sudo spk rm <package>    remove\n  sudo spk update          update all\n\nWi-Fi: iwctl, diagnostics: silen-wifi-check\nNVIDIA: proprietary driver auto-installed from this ISO on NVIDIA GPUs (see /var/log/nvidia-install.log).\nNo desktop is installed: boot lands on a tty login, add one later with spk.\n");
    setup_root_shell();
    setup_quiet_boot();
    let _ = fs::remove_dir_all(format!("{}/lost+found", r));
    if !setup_grub_result(s, log) {
        cleanup();
        return Err("GRUB setup failed".into());
    }
    let _ = run("sync", &[]);
    cleanup();
    Ok(())
}

fn setup_grub_result(s: &InstallSettings, log: &mut LogFn) -> bool {
    match setup_grub(s, log) {
        Ok(()) => true,
        Err(e) => {
            sh_log(log, &format!("GRUB failed: {}", e));
            false
        }
    }
}
