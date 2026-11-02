use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;

pub const ROOT_PATH: &str = "/silen";
pub const TITLE: &str = "Silen Linux";
pub const REPO: &str = "https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main";

pub const PACKAGES: &[&str] = &[
    "silen-base",
    "linux-6.18",
    "silen-firmware",
    "dbus",
    "iwd",
    "silen-desktop",
    "cres",
    "silen-config",
    "grub",
];

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
    pub wifi_ssid: String,
    pub wifi_pass: String,
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
            wifi_ssid: String::new(),
            wifi_pass: String::new(),
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

fn run_stream(program: &str, args: &[String], log: &mut LogFn) -> Result<(), String> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run {}: {}", program, e))?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let (tx, rx) = mpsc::channel::<String>();
    let mut readers = Vec::new();
    if let Some(out) = stdout {
        let tx = tx.clone();
        readers.push(thread::spawn(move || {
            for line in BufReader::new(out).lines().flatten() {
                let _ = tx.send(line);
            }
        }));
    }
    if let Some(err) = stderr {
        let tx = tx.clone();
        readers.push(thread::spawn(move || {
            for line in BufReader::new(err).lines().flatten() {
                let _ = tx.send(line);
            }
        }));
    }
    drop(tx);
    for line in rx {
        if !line.trim().is_empty() {
            log(line);
        }
    }
    for r in readers {
        let _ = r.join();
    }
    let status = child.wait().map_err(|e| format!("{}: {}", program, e))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{} exited with {}", program, status))
    }
}

fn run_sh(script: &str) -> bool {
    Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn chroot_run(root: &str, cmd: &str) -> bool {
    Command::new("chroot")
        .args([root, "/bin/sh", "-c", cmd])
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn chroot_stream(root: &str, cmd: &str, log: &mut LogFn) -> Result<(), String> {
    run_stream(
        "chroot",
        &[root.to_string(), "/bin/sh".to_string(), "-c".to_string(), cmd.to_string()],
        log,
    )
}

fn sh_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
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
            if !patterns.iter().any(|p| name.starts_with(p)) {
                continue;
            }
            if name.starts_with("loop") || name.starts_with("ram") || name.starts_with("zram") || name.starts_with("fd") {
                continue;
            }
            let dev = format!("/dev/{}", name);
            if !Path::new(&dev).exists() || seen.contains(&dev) {
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
    let s = run_capture("lsblk", &["-dn", "-o", "SIZE", dev]).replace(' ', "");
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

fn disk_bytes(dev: &str) -> u64 {
    let base = dev.trim_start_matches("/dev/");
    fs::read_to_string(format!("/sys/block/{}/size", base))
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .map(|s| s * 512)
        .unwrap_or(0)
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

pub fn medium_on_disk(disk: &str) -> bool {
    if let Ok(rec) = fs::read_to_string("/run/silen-medium-dev") {
        let rec = rec.trim().to_string();
        if !rec.is_empty() && (rec == disk || rec.starts_with(&format!("{}p", disk)) || rec.starts_with(&format!("{}1", disk))) {
            return true;
        }
    }
    let mounts = run_capture("mount", &[]);
    for line in mounts.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 && (parts[2] == "/run/silen/live" || parts[2] == "/run/ventoy" || parts[2] == "/mnt") {
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
    sh_log(log, &format!("Partitioning {} (GPT, 1G ESP + root)", s.disk));
    for cmd in ["sfdisk", "mkfs.vfat", "mkfs.ext4", "blkid"] {
        if run_capture("sh", &["-c", &format!("command -v {}", cmd)]).is_empty() {
            return Err(format!("{} not found on the install medium", cmd));
        }
    }
    let _ = run("wipefs", &["-a", &s.disk]);
    let input = "label: gpt\n, 1G, U\n, , L\n";
    let ok = Command::new("sfdisk")
        .args(["--no-reread", &s.disk])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            if let Some(stdin) = child.stdin.as_mut() {
                let _ = stdin.write_all(input.as_bytes());
            }
            child.wait()
        })
        .map(|st| st.success())
        .unwrap_or(false);
    if !ok {
        return Err(format!("couldn't write the partition table to {}", s.disk));
    }
    let _ = run("partprobe", &[&s.disk]);
    let _ = run("blockdev", &["--rereadpt", &s.disk]);
    let (bootp, rootp) = part_devs(&s.disk);
    let mut waited = 0;
    while (!Path::new(&bootp).exists() || !Path::new(&rootp).exists()) && waited < 50 {
        thread::sleep(std::time::Duration::from_millis(200));
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
                return Err("couldn't format the root partition as btrfs".into());
            }
        }
        "vfat" => {
            if !run("mkfs.vfat", &["-F", "32", "-n", "silenroot", &rootp]) {
                return Err("couldn't format the root partition as FAT32".into());
            }
        }
        _ => {
            if !run("mkfs.ext4", &["-F", "-q", "-L", "silenroot", "-E", "nodiscard,lazy_itable_init=1,lazy_journal_init=1", &rootp]) {
                return Err("couldn't format the root partition as ext4".into());
            }
        }
    }
    Ok(())
}

fn mount_target(root: &str) -> Result<(), String> {
    if !run("mount", &[&s_root_part(), root]) {
        return Err(format!("failed to mount {}", s_root_part()));
    }
    let boot = format!("{}/boot", root);
    let _ = fs::create_dir_all(&boot);
    if !run("mount", &[&s_boot_part(), &boot]) {
        return Err(format!("failed to mount {}", s_boot_part()));
    }
    for (src, dst) in [("/proc", "proc"), ("/sys", "sys"), ("/dev", "dev"), ("/run", "run")] {
        let target = format!("{}/{}", root, dst);
        let _ = fs::create_dir_all(&target);
        let _ = run("mount", &["--rbind", src, &target]);
    }
    Ok(())
}

fn s_root_part() -> String {
    fs::read_to_string("/run/silen-root-part").map(|s| s.trim().to_string()).unwrap_or_default()
}

fn s_boot_part() -> String {
    fs::read_to_string("/run/silen-boot-part").map(|s| s.trim().to_string()).unwrap_or_default()
}

pub fn fix_permissions(log: &mut LogFn) {
    let r = ROOT_PATH;
    for rel in ["usr/bin/sudo", "usr/bin/su", "usr/bin/passwd", "usr/bin/mount", "usr/bin/umount", "usr/bin/chsh", "usr/bin/chfn", "usr/bin/newgrp", "usr/bin/gpasswd", "usr/bin/chage"] {
        let p = format!("{}/{}", r, rel);
        if Path::new(&p).exists() && !Path::new(&p).is_symlink() {
            let _ = Command::new("chown").args(["root:root", &p]).status();
            let _ = Command::new("chmod").args(["4755", &p]).status();
        }
    }
    for rel in ["usr/bin/unix_chkpwd", "usr/sbin/unix_chkpwd"] {
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
    if !Path::new(&sudoers).exists() {
        let _ = fs::write(&sudoers, "root ALL=(ALL:ALL) ALL\n%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n@includedir /etc/sudoers.d\n");
    }
    let _ = Command::new("chown").args(["root:root", &sudoers]).status();
    let _ = Command::new("chmod").args(["440", &sudoers]).status();
    for g in ["wheel", "seat", "audio", "video", "input", "render", "plugdev", "network"] {
        let _ = chroot_run(r, &format!("getent group {} >/dev/null 2>&1 || groupadd -r {}", g, g));
    }
    sh_log(log, "permissions fixed");
}

pub fn apply_settings(s: &InstallSettings, log: &mut LogFn) {
    let r = ROOT_PATH;
    let zone_src = format!("{}/usr/share/zoneinfo/{}", r, s.zone);
    if Path::new(&zone_src).exists() {
        let _ = fs::remove_file(format!("{}/etc/localtime", r));
        let _ = std::os::unix::fs::symlink(format!("/usr/share/zoneinfo/{}", s.zone), format!("{}/etc/localtime", r));
        let _ = fs::write(format!("{}/etc/timezone", r), format!("{}\n", s.zone));
    } else {
        sh_log(log, &format!("timezone {} missing in target", s.zone));
    }
    let _ = fs::create_dir_all(format!("{}/etc/conf.d", r));
    let _ = fs::write(format!("{}/etc/conf.d/keymaps", r), format!("keymap=\"{}\"\n", s.keymap));
    let _ = fs::write(format!("{}/etc/locale.gen", r), format!("{} UTF-8\n", s.locale));
    let _ = fs::create_dir_all(format!("{}/etc/env.d", r));
    let _ = fs::write(format!("{}/etc/env.d/02locale", r), format!("LANG=\"{}\"\nLC_ALL=\"{}\"\n", s.locale, s.locale));
    if !s.want_swap.is_empty() {
        if !chroot_run(r, &format!("fallocate -l {} /swapfile && chmod 600 /swapfile && mkswap /swapfile", s.want_swap)) {
            sh_log(log, "couldn't create the swapfile");
        }
    }
    let _ = fs::write(format!("{}/etc/motd", r), "Welcome to Silen Linux\n");
    let _ = fs::create_dir_all(format!("{}/etc/sudoers.d", r));
    let _ = fs::write(format!("{}/etc/sudoers.d/10-silen", r), "%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n");
    let _ = Command::new("chown").args(["root:root", &format!("{}/etc/sudoers.d/10-silen", r)]).status();
    let _ = Command::new("chmod").args(["0440", &format!("{}/etc/sudoers.d/10-silen", r)]).status();
    let _ = fs::create_dir_all(format!("{}/etc/profile.d", r));
    let _ = fs::write(format!("{}/etc/profile.d/silen-hostname.sh", r), "if [ -f /etc/hostname ]; then\n    HOSTNAME=$(cat /etc/hostname 2>/dev/null)\n    export HOSTNAME\nfi\n");
    let _ = fs::write(format!("{}/etc/bash.bashrc", r), "[ -f /etc/profile.d/silen-hostname.sh ] && . /etc/profile.d/silen-hostname.sh\n");
}

pub fn create_user(s: &InstallSettings, log: &mut LogFn) {
    if s.newuser.is_empty() {
        return;
    }
    let r = ROOT_PATH;
    if !chroot_run(r, "command -v useradd >/dev/null 2>&1") {
        sh_log(log, &format!("couldn't create user {} (no useradd)", s.newuser));
        return;
    }
    for g in ["wheel", "seat", "audio", "video", "input", "render", "plugdev", "network", "users"] {
        let _ = chroot_run(r, &format!("getent group {} >/dev/null 2>&1 || groupadd -r {}", g, g));
    }
    let mut groups: Vec<String> = Vec::new();
    for g in ["wheel", "seat", "audio", "video", "input", "render", "plugdev", "network"] {
        if chroot_run(r, &format!("getent group {} >/dev/null 2>&1", g)) {
            groups.push(g.into());
        }
    }
    let uflags = if groups.is_empty() {
        "-m -s /bin/bash".to_string()
    } else {
        format!("-m -s /bin/bash -G {}", groups.join(","))
    };
    if !chroot_run(r, &format!("useradd {} {}", uflags, s.newuser)) {
        sh_log(log, &format!("couldn't create user {}", s.newuser));
        return;
    }
    let script = format!("printf '%s:%s\\n' {} {} | chpasswd", sh_quote(&s.newuser), sh_quote(&s.userpass));
    if !chroot_run(r, &script) {
        sh_log(log, &format!("user {} created but password couldn't be set", s.newuser));
    }
    let _ = chroot_run(r, &format!("usermod -aG wheel {0} 2>/dev/null || gpasswd -a {0} wheel 2>/dev/null", s.newuser));
    let _ = fs::create_dir_all(format!("{}/home/{}/.local/bin", r, s.newuser));
    let _ = chroot_run(r, &format!("chown -R {0}:{0} /home/{0} 2>/dev/null; chmod 755 /home/{0} 2>/dev/null", s.newuser));
    sh_log(log, &format!("user {} created", s.newuser));
}

fn write_silen_config(s: &InstallSettings) {
    let r = ROOT_PATH;
    let packages = PACKAGES.iter().map(|p| format!("\t\t\"{}\",\n", p)).collect::<String>();
    let config = format!(
        "return {{\n\tversion = 1,\n\thostname = \"{}\",\n\ttimezone = \"{}\",\n\tkeymap = \"{}\",\n\tlocale = \"{}\",\n\tpackages = {{\n{}\t}},\n\tservices = {{\n\t\t{{ name = \"dbus\", runlevel = \"boot\" }},\n\t\t{{ name = \"dhcpcd\", runlevel = \"default\" }},\n\t\t{{ name = \"iwd\", runlevel = \"default\" }},\n\t\t{{ name = \"seatd\", runlevel = \"default\" }},\n\t\t{{ name = \"greetd\", runlevel = \"default\" }},\n\t}},\n\tsysctl = {{\n\t\t[\"kernel.sysrq\"] = \"1\",\n\t}},\n}}\n",
        s.hostname, s.zone, s.keymap, s.locale, packages
    );
    let _ = fs::create_dir_all(format!("{}/etc/silen", r));
    let _ = fs::write(format!("{}/etc/silen/config.lua", r), config);
}

pub fn configure_services(log: &mut LogFn) {
    let r = ROOT_PATH;
    let _ = fs::create_dir_all(format!("{}/run/dbus", r));
    let _ = fs::create_dir_all(format!("{}/var/lib/iwd", r));
    let _ = fs::create_dir_all(format!("{}/var/lib/greetd", r));
    let _ = fs::write(format!("{}/etc/iwd/main.conf", r), "[General]\nEnableNetworkConfiguration=true\n");
    for (svc, level) in [
        ("dbus", "boot"),
        ("iwd", "default"),
        ("dhcpcd", "default"),
        ("seatd", "default"),
        ("greetd", "default"),
        ("local", "default"),
        ("elogind", "boot"),
    ] {
        if !chroot_run(r, &format!("test -x /etc/init.d/{}", svc)) {
            continue;
        }
        if !chroot_run(r, &format!("rc-update add {} {}", svc, level)) {
            sh_log(log, &format!("could not enable service {}", svc));
        }
    }
    if chroot_run(r, "command -v dbus-uuidgen >/dev/null 2>&1") {
        let _ = chroot_run(r, "dbus-uuidgen --ensure=/etc/machine-id");
    }
}

pub fn setup_grub(s: &InstallSettings, log: &mut LogFn) -> Result<(), String> {
    let r = ROOT_PATH;
    let _ = fs::create_dir_all(format!("{}/sys/firmware/efi/efivars", r));
    let _ = run("mount", &["-t", "efivarfs", "efivarfs", &format!("{}/sys/firmware/efi/efivars", r)]);
    let grub_log = format!("{}/tmp/grub-install.log", r);
    let _ = fs::create_dir_all(format!("{}/tmp", r));
    let mut cmd = String::from("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH=/usr/local/lib /usr/local/sbin/grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable");
    cmd.push_str(&format!(" >>{} 2>&1", grub_log));
    if !chroot_run(r, &cmd) {
        return Err(format!("grub-install failed, see {}", grub_log));
    }
    let bootuuid = run_capture("blkid", &["-s", "UUID", "-o", "value", &s.bootp]);
    let rootuuid = run_capture("blkid", &["-s", "UUID", "-o", "value", &s.rootp]);
    if bootuuid.is_empty() || rootuuid.is_empty() {
        return Err("couldn't read the partition UUIDs".into());
    }
    let initrd = format!("{}/boot/initramfs-silen.img", r);
    if !Path::new(&initrd).exists() {
        return Err("initramfs-silen.img was not generated".into());
    }
    let cfg = format!(
        "set default=0\nset timeout=5\n\ninsmod part_gpt\ninsmod fat\ninsmod ext2\ninsmod search_fs_uuid\ninsmod all_video\ninsmod gfxterm\nterminal_output gfxterm console\nsearch --no-floppy --fs-uuid --set=root {}\n\nmenuentry \"Silen Linux\" {{\n    linux /vmlinuz root=UUID={} ro rootwait loglevel=4 console=tty0\n    initrd /initramfs-silen.img\n}}\n",
        bootuuid, rootuuid
    );
    fs::write(format!("{}/boot/grub/grub.cfg", r), cfg).map_err(|e| format!("write grub.cfg: {}", e))?;
    let mut cmd2 = String::from("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH=/usr/local/lib /usr/local/sbin/grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --bootloader-id=Silen");
    cmd2.push_str(&format!(" >>{} 2>&1", grub_log));
    let _ = chroot_run(r, &cmd2);
    sh_log(log, "GRUB installed");
    Ok(())
}

pub fn install_packages(log: &mut LogFn) -> Result<(), String> {
    let mut args = vec![
        "--root".to_string(),
        ROOT_PATH.to_string(),
        "--repo".to_string(),
        REPO.to_string(),
        "--cache".to_string(),
        "/var/cache/cres".to_string(),
        "--yes".to_string(),
        "install".to_string(),
    ];
    for p in PACKAGES {
        args.push((*p).to_string());
    }
    sh_log(log, &format!("installing {} packages with cres", PACKAGES.len()));
    run_stream("/usr/bin/cres", &args, log).map_err(|e| format!("cres install failed: {}", e))
}

pub fn regenerate_initramfs(log: &mut LogFn) -> Result<(), String> {
    sh_log(log, "generating initramfs");
    chroot_stream(ROOT_PATH, "/usr/local/bin/silen-mkinitramfs", log)
}

pub fn do_install(s: &mut InstallSettings, log: &mut LogFn) -> Result<(), String> {
    if !must_be_root() {
        return Err("this installer needs root".into());
    }
    if !is_efi() {
        return Err("legacy boot detected: Silen installs an EFI bootloader only".into());
    }
    if s.disk.is_empty() {
        return Err("no disk selected".into());
    }
    if medium_on_disk(&s.disk) {
        return Err(format!("{} holds the install medium, pick a different disk", s.disk));
    }
    if disk_bytes(&s.disk) < 8 * 1024 * 1024 * 1024 {
        return Err(format!("{} is smaller than the 8 GiB minimum", s.disk));
    }
    do_partition(s, log)?;
    let _ = fs::write("/run/silen-root-part", &s.rootp);
    let _ = fs::write("/run/silen-boot-part", &s.bootp);
    let r = ROOT_PATH;
    let _ = fs::remove_dir_all(r);
    fs::create_dir_all(r).map_err(|e| format!("create {}: {}", r, e))?;
    mount_target(r)?;
    let _ = fs::write(format!("{}/etc/resolv.conf", r), "nameserver 1.1.1.1\nnameserver 9.9.9.9\n");
    install_packages(log)?;
    fix_permissions(log);
    let _ = fs::write(format!("{}/etc/hostname", r), format!("{}\n", s.hostname));
    let _ = fs::write(format!("{}/etc/hosts", r), format!("127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t{}\n", s.hostname));
    let chpasswd = ["/usr/bin/chpasswd", "/usr/sbin/chpasswd", "/bin/chpasswd", "/sbin/chpasswd"]
        .iter()
        .find(|c| Path::new(&format!("{}{}", r, c)).exists())
        .map(|s| s.to_string())
        .unwrap_or("/usr/bin/chpasswd".into());
    let script = format!("printf 'root:%s\\n' {} | {}", sh_quote(&s.rootpass), chpasswd);
    if !chroot_run(r, &script) {
        return Err("couldn't set the root password".into());
    }
    apply_settings(s, log);
    create_user(s, log);
    let bootuuid = run_capture("blkid", &["-s", "UUID", "-o", "value", &s.bootp]);
    let rootuuid = run_capture("blkid", &["-s", "UUID", "-o", "value", &s.rootp]);
    if bootuuid.is_empty() || rootuuid.is_empty() {
        return Err("couldn't read the partition UUIDs".into());
    }
    let fspass = if s.fstype == "ext4" { "0 1" } else { "0 0" };
    let mut fstab = format!("UUID={} / {} defaults {}\nUUID={} /boot vfat defaults 0 2\n", rootuuid, s.fstype, fspass, bootuuid);
    if !s.want_swap.is_empty() {
        fstab.push_str("/swapfile none swap sw 0 0\n");
    }
    let _ = fs::write(format!("{}/etc/fstab", r), fstab);
    write_silen_config(s);
    configure_services(log);
    regenerate_initramfs(log)?;
    setup_grub(s, log)?;
    let _ = run("sync", &[]);
    cleanup();
    sh_log(log, "Silen is installed");
    Ok(())
}

pub fn network_status() -> String {
    let mut out = String::new();
    let addrs = run_capture("ip", &["-brief", "addr"]);
    if !addrs.is_empty() {
        out.push_str(&addrs);
        out.push('\n');
    }
    let route = run_capture("ip", &["route"]);
    if !route.is_empty() {
        out.push_str(&route);
        out.push('\n');
    }
    let dns = fs::read_to_string("/etc/resolv.conf").unwrap_or_default();
    for line in dns.lines() {
        if line.starts_with("nameserver") {
            out.push_str(line);
            out.push('\n');
        }
    }
    if out.trim().is_empty() {
        "no network information available".into()
    } else {
        out.trim().to_string()
    }
}

pub fn wifi_devices() -> Vec<String> {
    let out = run_capture("iwctl", &["device", "list"]);
    let mut devs = Vec::new();
    for line in out.lines().skip(2) {
        let line = line.replace('>', " ").replace('*', " ");
        let mut parts = line.split_whitespace();
        if let Some(name) = parts.next() {
            if !name.is_empty() && name != "Name" {
                devs.push(name.to_string());
            }
        }
    }
    devs
}

pub fn wifi_scan() -> Vec<String> {
    let devs = wifi_devices();
    let mut networks = Vec::new();
    for dev in devs {
        let _ = run("iwctl", &["station", &dev, "scan"]);
        thread::sleep(std::time::Duration::from_secs(2));
        let out = run_capture("iwctl", &["station", &dev, "get-networks"]);
        for line in out.lines().skip(2) {
            let clean = line.replace('>', " ").replace('*', " ");
            let mut parts = clean.split_whitespace();
            if let Some(ssid) = parts.next() {
                if !ssid.is_empty() && ssid != "Network" && !networks.contains(&ssid.to_string()) {
                    networks.push(ssid.to_string());
                }
            }
        }
    }
    networks
}

pub fn wifi_connect(ssid: &str, pass: &str) -> Result<(), String> {
    let devs = wifi_devices();
    let dev = devs.first().ok_or("no Wi-Fi device found")?;
    let mut args = Vec::new();
    if !pass.is_empty() {
        args.push("--passphrase".to_string());
        args.push(pass.to_string());
    }
    args.extend(["station".to_string(), dev.clone(), "connect".to_string(), ssid.to_string()]);
    let mut log = |line: String| eprintln!("{}", line);
    run_stream("iwctl", &args, &mut log)?;
    for _ in 0..30 {
        thread::sleep(std::time::Duration::from_secs(1));
        if run_capture("ip", &["route"]).contains("default") {
            return Ok(());
        }
    }
    Err("Wi-Fi connected but no default route appeared yet".into())
}
