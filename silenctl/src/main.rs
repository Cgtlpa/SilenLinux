use std::io::{self, Stdout};
use std::process::Command;
use std::time::Duration;

use crossterm::{
    event::{self, Event, KeyCode},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::Line,
    widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph},
    layout::Rect,
    Terminal,
};

const RICE_WM_TOML: &str = include_str!("../rice/instantwm-config.toml");
const RICE_KITTY: &str = include_str!("../rice/kitty.conf");
const RICE_WALLPAPER: &[u8] = include_bytes!("../rice/wallhaven-lyde92_1920x1080.png");
const RICE_WALLPAPER_NAME: &str = "wallhaven-lyde92_1920x1080.png";

const MANAGED_SERVICES: &[&str] = &["dbus", "elogind", "seatd", "iwd", "dhcpcd", "sshd"];

enum Kind {
    Packages,
    Action(&'static str),
    Input(InputKind),
    Service,
}

#[derive(Clone, PartialEq)]
enum InputKind {
    CustomPkg,
    Hostname,
    Timezone,
    WifiSsid,
    WifiPass { ssid: String },
    NewUser,
    NewUserPass { user: String },
    RootPass,
}

struct Item {
    pkg: &'static str,
    blurb: &'static str,
    kind: Kind,
    checked: bool,
    rice: bool,
}

struct Cat {
    name: String,
    items: Vec<Item>,
}

fn pkg(p: &'static str, b: &'static str) -> Item {
    Item { pkg: p, blurb: b, kind: Kind::Packages, checked: false, rice: false }
}

fn input_item(blurb: &'static str, k: InputKind) -> Item {
    Item { pkg: "", blurb, kind: Kind::Input(k), checked: false, rice: false }
}

fn categories() -> Vec<Cat> {
    vec![
        Cat {
            name: "Window managers".into(),
            items: vec![
                Item { pkg: "instantwm", blurb: "hybrid tiling/floating (X11+Wayland) (recommended)", kind: Kind::Packages, checked: false, rice: true },
                pkg("mango", "tiling Wayland compositor"),
                pkg("niri", "scrollable-tiling Wayland compositor"),
                pkg("dwm", "dynamic X11 window manager"),
            ],
        },
        Cat {
            name: "Login managers".into(),
            items: vec![
                pkg("greetd", "tuigreet graphical login (starts on boot)"),
            ],
        },
        Cat {
            name: "Terminals".into(),
            items: vec![
                pkg("kitty", "GPU terminal"),
                pkg("alacritty", "GPU terminal"),
                pkg("st", "simple X terminal"),
            ],
        },
        Cat {
            name: "Launchers".into(),
            items: vec![
                pkg("rofi", "X11 app launcher"),
                pkg("wofi", "Wayland app launcher"),
                pkg("dmenu", "minimal X menu"),
                pkg("instantmenu", "instantWM menu"),
            ],
        },
        Cat { name: "Bar".into(), items: vec![pkg("waybar", "Wayland status bar (not needed for instantwm — it has its own bar)")] },
        Cat {
            name: "Fonts".into(),
            items: vec![
                pkg("dejavu", "DejaVu family"),
                pkg("noto-fonts", "Noto Sans/Serif/Mono"),
                pkg("noto-emoji", "color emoji"),
                pkg("liberation", "Arial/Times/Courier metrics"),
                pkg("nerd-symbols", "icons for bars"),
            ],
        },
        Cat {
            name: "Languages".into(),
            items: vec![
                pkg("fennel", "Lisp on Lua"),
                pkg("janet", "functional scripting"),
                pkg("nim", "systems language"),
                pkg("quickjs", "tiny JS engine"),
            ],
        },
        Cat {
            name: "Tools".into(),
            items: vec![
                pkg("instantcli", "instantOS helper (ins)"),
                pkg("iwtui", "terminal UI widgets"),
                pkg("pipewire", "audio server"),
            ],
        },
        Cat {
            name: "Setup".into(),
            items: vec![
                input_item("set hostname", InputKind::Hostname),
                input_item("set timezone (e.g. Europe/Berlin)", InputKind::Timezone),
                input_item("connect to WiFi", InputKind::WifiSsid),
                input_item("create user account", InputKind::NewUser),
                input_item("set root password", InputKind::RootPass),
            ],
        },
        Cat { name: "Services".into(), items: vec![] },
        Cat {
            name: "System".into(),
            items: vec![
                Item { pkg: "", blurb: "update every installed package", kind: Kind::Action("spk update"), checked: false, rice: false },
                Item { pkg: "", blurb: "run WiFi diagnostics", kind: Kind::Action("silen-wifi-check"), checked: false, rice: false },
                input_item("type any package name(s)", InputKind::CustomPkg),
                Item { pkg: "", blurb: "reboot the machine", kind: Kind::Action("reboot"), checked: false, rice: false },
            ],
        },
        Cat {
            name: "Install".into(),
            items: vec![
                Item { pkg: "", blurb: "install everything selected", kind: Kind::Action("__INSTALL__"), checked: false, rice: false },
            ],
        },
    ]
}

#[derive(PartialEq)]
enum Mode {
    Cats,
    Items,
    Rice,
    Confirm,
    Input,
    Busy,
}

struct App {
    cats: Vec<Cat>,
    services: Vec<(String, bool)>,
    cat_state: ListState,
    item_state: ListState,
    rice_state: ListState,
    confirm_state: ListState,
    log: Vec<String>,
    mode: Mode,
    input: String,
    input_kind: InputKind,
    input_prompt: &'static str,
    confirm_q: String,
    confirm_install: bool,
    rice_wanted: bool,
    want_reboot: bool,
    busy_since: Option<std::time::Instant>,
}

impl App {
    fn new() -> Self {
        let mut cat_state = ListState::default();
        cat_state.select(Some(0));
        let mut item_state = ListState::default();
        item_state.select(Some(0));
        let mut rice_state = ListState::default();
        rice_state.select(Some(0));
        let mut confirm_state = ListState::default();
        confirm_state.select(Some(1));
        let mut app = Self {
            cats: categories(),
            services: vec![],
            cat_state,
            item_state,
            rice_state,
            confirm_state,
            log: vec![],
            mode: Mode::Cats,
            input: String::new(),
            input_kind: InputKind::CustomPkg,
            input_prompt: "",
            confirm_q: String::new(),
            confirm_install: false,
            rice_wanted: false,
            want_reboot: false,
            busy_since: None,
        };
        app.preflight();
        app.refresh_services();
        app
    }

    fn push_log(&mut self, line: String) {
        self.log.push(line);
        if self.log.len() > 500 {
            let d = self.log.len() - 500;
            self.log.drain(0..d);
        }
    }

    fn preflight(&mut self) {
        self.push_log("silenctl preflight:".into());
        let os = std::fs::read_to_string("/etc/os-release").unwrap_or_default();
        if os.to_lowercase().contains("silen") {
            self.push_log("  system: Silen Linux".into());
        } else {
            self.push_log("  warning: this does not look like Silen (continuing anyway)".into());
        }
        let spk = Command::new("sh").arg("-c").arg("command -v spk").output();
        match spk {
            Ok(o) if o.status.success() => self.push_log("  spk: found".into()),
            _ => self.push_log("  WARNING: spk not on PATH, installs will fail".into()),
        }
        let base = std::env::var("SPK_BASE_URL").unwrap_or_else(|_| "https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main/packages".into());
        let probe = Command::new("curl").args(["-sI", "--max-time", "5", &format!("{}/index.json", base)]).output();
        match probe {
            Ok(o) if o.status.success() && !o.stdout.is_empty() => self.push_log("  network: package repo reachable".into()),
            _ => self.push_log("  WARNING: package repo unreachable (offline?), installs will fail".into()),
        }
    }

    fn refresh_services(&mut self) {
        self.services.clear();
        let has_rc = Command::new("sh").arg("-c").arg("command -v rc-update").output().map(|o| o.status.success()).unwrap_or(false);
        if !has_rc {
            self.services.push(("(no OpenRC here)".into(), false));
            return;
        }
        let out = Command::new("rc-update").arg("show").arg("default").output();
        let txt = out.map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
        for svc in MANAGED_SERVICES {
            let on = txt.lines().any(|l| {
                let parts: Vec<&str> = l.split('|').collect();
                parts.len() == 2 && parts[0].trim() == *svc && parts[1].contains("default")
            });
            self.services.push((svc.to_string(), on));
        }
        if let Some(cat) = self.cats.iter_mut().find(|c| c.name == "Services") {
            cat.items = self
                .services
                .iter()
                .map(|(s, on)| Item {
                    pkg: "",
                    blurb: if s.starts_with('(') { "service manager not found" } else { if *on { "enabled" } else { "disabled" } },
                    kind: Kind::Service,
                    checked: false,
                    rice: false,
                })
                .collect();
        }
    }

    fn ci(&self) -> usize {
        self.cat_state.selected().unwrap_or(0)
    }

    fn ii(&self) -> usize {
        let n = self.cats[self.ci()].items.len().max(1);
        self.item_state.selected().unwrap_or(0) % n
    }

    fn run_shell(&mut self, cmd: &str) {
        self.push_log(format!("$ {}", cmd));
        self.push_log("running… (output appears below when done)".into());
        self.mode = Mode::Busy;
        self.busy_since = Some(std::time::Instant::now());
        match Command::new("sh")
            .arg("-c")
            .arg(cmd)
            .stdin(std::process::Stdio::null())
            .output()
        {
            Ok(o) => {
                let txt = format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
                let lines: Vec<&str> = txt.lines().collect();
                let shown = if lines.len() > 30 { &lines[lines.len() - 30..] } else { &lines[..] };
                for l in shown {
                    self.push_log(l.to_string());
                }
                self.push_log(format!("(exit: {}) — done", o.status));
            }
            Err(e) => self.push_log(format!("failed to run: {}", e)),
        }
        self.busy_since = None;
        self.mode = Mode::Items;
    }

    fn run_secret(&mut self, shown: &str, cmd: &str, stdin_data: &str) {
        self.push_log(format!("$ {} (input hidden)", shown));
        self.mode = Mode::Busy;
        self.busy_since = Some(std::time::Instant::now());
        let mut child = match Command::new("sh").arg("-c").arg(cmd).stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).spawn() {
            Ok(c) => c,
            Err(e) => {
                self.push_log(format!("failed to run: {}", e));
                self.busy_since = None;
                self.mode = Mode::Items;
                return;
            }
        };
        use std::io::Write;
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(stdin_data.as_bytes());
        }
        match child.wait_with_output() {
            Ok(o) => {
                let txt = format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
                for l in txt.lines().take(5) {
                    self.push_log(l.to_string());
                }
                self.push_log(format!("(exit: {}) — done", o.status));
            }
            Err(e) => self.push_log(format!("failed: {}", e)),
        }
        self.busy_since = None;
        self.mode = Mode::Items;
    }

    fn sanitize_hostname(raw: &str) -> String {
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

    fn valid_user(name: &str) -> bool {
        if name.is_empty() || name.len() > 32 || name == "root" {
            return false;
        }
        let mut chars = name.chars();
        match chars.next() {
            Some(c) if c.is_ascii_lowercase() || c == '_' => {}
            _ => return false,
        }
        name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
    }

    fn submit_input(&mut self) {
        let value = self.input.trim().to_string();
        let kind = self.input_kind.clone();
        self.input.clear();
        self.mode = Mode::Items;
        match kind {
            InputKind::CustomPkg => {
                if !value.is_empty() {
                    self.run_shell(&format!("spk get {}", value));
                }
            }
            InputKind::Hostname => {
                if value.is_empty() {
                    return;
                }
                let h = Self::sanitize_hostname(&value);
                self.run_shell(&format!("echo {} > /etc/hostname && hostname {}", h, h));
            }
            InputKind::Timezone => {
                if value.is_empty() {
                    return;
                }
                if !std::path::Path::new(&format!("/usr/share/zoneinfo/{}", value)).exists() {
                    self.push_log("unknown timezone (try Area/City, e.g. Europe/Berlin)".to_string());
                    return;
                }
                self.run_shell(&format!("ln -sf /usr/share/zoneinfo/{} /etc/localtime", value));
            }
            InputKind::WifiSsid => {
                if value.is_empty() {
                    return;
                }
                self.input_kind = InputKind::WifiPass { ssid: value };
                self.input_prompt = "WiFi passphrase (empty = open network)";
                self.mode = Mode::Input;
            }
            InputKind::WifiPass { ssid } => {
                let iface = std::fs::read_dir("/sys/class/net")
                    .ok()
                    .and_then(|mut it| {
                        it.find_map(|e| {
                            let n = e.ok()?.file_name().to_string_lossy().to_string();
                            if n.starts_with('w') && n != "lo" {
                                // prefer wireless interfaces
                                let w = std::path::Path::new(&format!("/sys/class/net/{}/wireless", n)).exists();
                                if w {
                                    return Some(n);
                                }
                            }
                            None
                        })
                    })
                    .or_else(|| {
                        std::fs::read_dir("/sys/class/net").ok().and_then(|mut it| {
                            it.find_map(|e| {
                                let n = e.ok()?.file_name().to_string_lossy().to_string();
                                if n != "lo" {
                                    Some(n)
                                } else {
                                    None
                                }
                            })
                        })
                    })
                    .unwrap_or_else(|| "wlan0".into());
                if value.is_empty() {
                    self.run_shell(&format!("iwctl station {} connect '{}'", iface, ssid.replace('\'', "")));
                } else {
                    self.run_secret(
                        &format!("iwctl connect '{}' (passphrase hidden)", ssid),
                        &format!("iwctl --passphrase '{}' station {} connect '{}'", value.replace('\'', ""), iface, ssid.replace('\'', "")),
                        "",
                    );
                }
            }
            InputKind::NewUser => {
                if !Self::valid_user(&value) {
                    self.push_log("bad username (lowercase, digits, _-, max 32, not root)".into());
                    return;
                }
                self.input_kind = InputKind::NewUserPass { user: value };
                self.input_prompt = "password for the new user";
                self.mode = Mode::Input;
            }
            InputKind::NewUserPass { user } => {
                if value.is_empty() || value.contains(':') {
                    self.push_log("password can't be empty or contain ':'".into());
                    return;
                }
                self.run_shell(&format!("useradd -m -s /bin/bash -G wheel,video,input {} 2>&1; echo done", user.replace('\'', "")));
                self.run_secret(&format!("set password for {}", user), "chpasswd", &format!("{}:{}\n", user, value));
            }
            InputKind::RootPass => {
                if value.is_empty() || value.contains(':') {
                    self.push_log("password can't be empty or contain ':'".into());
                    return;
                }
                self.run_secret("set root password", "chpasswd", &format!("root:{}\n", value));
            }
        }
    }

    fn target_home() -> String {
        if let Ok(su) = std::env::var("SUDO_USER") {
            if !su.is_empty() && su != "root" {
                return format!("/home/{}", su);
            }
        }
        if let Ok(entries) = std::fs::read_dir("/home") {
            for e in entries.flatten() {
                let p = e.path();
                if p.is_dir() {
                    return p.to_string_lossy().to_string();
                }
            }
        }
        "/root".to_string()
    }

    fn apply_rice(&mut self) {
        let home = Self::target_home();
        self.push_log(format!("applying instant rice to {} ...", home));
        let wm_dir = format!("{}/.config/instantwm", home);
        let kitty_dir = format!("{}/.config/kitty", home);
        let pic_dir = format!("{}/Pictures/wallpapers", home);
        for d in [&wm_dir, &kitty_dir, &pic_dir] {
            let _ = std::fs::create_dir_all(d);
        }
        let mut cfg = RICE_WM_TOML.replace("/home/vgz", &home);
        let vicinae = format!("\"{}/.local/bin/vicinae\", \"toggle\"", home);
        if cfg.contains(&vicinae) {
            cfg = cfg.replace(&vicinae, "\"instantmenu_run\"");
            self.push_log("note: Super+Space launcher vicinae is not packaged, using instantmenu_run (same role)".into());
        }
        let mut ok = true;
        ok &= std::fs::write(format!("{}/config.toml", wm_dir), cfg).is_ok();
        ok &= std::fs::write(format!("{}/kitty.conf", kitty_dir), RICE_KITTY).is_ok();
        ok &= std::fs::write(format!("{}/{}", pic_dir, RICE_WALLPAPER_NAME), RICE_WALLPAPER).is_ok();
        if let Ok(su) = std::env::var("SUDO_USER") {
            if !su.is_empty() {
                let _ = Command::new("chown").args(["-R", &format!("{}:{}", su, su), &format!("{}/.config/instantwm", home), &format!("{}/.config/kitty", home), &pic_dir]).status();
            }
        }
        if ok {
            self.push_log("rice written: instantwm config + kitty config + wallpaper".into());
        } else {
            self.push_log("WARNING: some rice files failed to write (check permissions)".into());
        }
        self.push_log("note: screenshot keybind needs slurp/grim/wl-copy (not packaged); install them manually to enable it".into());
        self.push_log(format!("note: wallpaper is at ~/Pictures/wallpapers/{} — set it with your wallpaper tool", RICE_WALLPAPER_NAME));
    }

    fn selected_count(&self) -> usize {
        self.cats.iter().flat_map(|c| c.items.iter()).filter(|i| i.checked && matches!(i.kind, Kind::Packages)).count()
    }

    fn selected_pkgs(&self) -> Vec<String> {
        let mut out = vec![];
        for c in &self.cats {
            for i in &c.items {
                if i.checked && matches!(i.kind, Kind::Packages) && !out.contains(&i.pkg.to_string()) {
                    out.push(i.pkg.to_string());
                }
            }
        }
        out
    }

    fn install_selection(&mut self) {
        let picked = self.selected_pkgs();
        if picked.is_empty() {
            self.push_log("nothing selected (Space to select)".into());
            return;
        }
        self.confirm_q = format!("Install {} package(s): {}?", picked.len(), picked.join(" "));
        self.confirm_install = true;
        self.mode = Mode::Confirm;
        self.confirm_state.select(Some(1));
    }

    fn do_install(&mut self) {
        let picked = self.selected_pkgs();
        let run_rice = self.rice_wanted
            && self.cats.iter().flat_map(|c| c.items.iter()).any(|i| i.checked && i.rice);
        if picked.is_empty() {
            self.mode = Mode::Items;
            return;
        }
        let cmd = format!("spk get {}", picked.join(" "));
        self.run_shell(&cmd);
        for c in self.cats.iter_mut() {
            for item in c.items.iter_mut() {
                item.checked = false;
            }
        }
        self.push_log(format!("installed: {} — done", picked.join(", ")));
        let want_rice = run_rice;
        self.rice_wanted = false;
        if want_rice {
            self.apply_rice();
        }
        if picked.iter().any(|p| p == "greetd") {
            self.push_log("enabling greetd login manager on boot ...".into());
            self.run_shell("rc-update add greetd default 2>&1");
            // greetd owns tty1: a competing agetty there makes both fight
            // and the greeter never appears. Consoles stay on tty2-6.
            // Idempotent: already-commented lines don't match ^c1:.
            self.run_shell("sed -i 's|^c1:12345:respawn:/sbin/agetty|#c1:12345:respawn:/sbin/agetty|' /etc/inittab 2>&1; grep -E '^#?c1:' /etc/inittab");
            self.push_log("greetd will greet on tty1 (agetty there disabled) — consoles stay on tty2-6".into());
            self.push_log("to go back: uncomment the c1 line in /etc/inittab and run: rc-update del greetd default".into());
        }
        self.confirm_q = "Reboot recommended — reboot now?".into();
        self.confirm_install = false;
        self.confirm_state.select(Some(0));
        self.mode = Mode::Confirm;
    }

    fn toggle_service(&mut self) {
        let i = self.ii();
        if i >= self.services.len() {
            return;
        }
        let (name, on) = (self.services[i].0.clone(), self.services[i].1);
        if name.starts_with('(') {
            return;
        }
        if on {
            self.run_shell(&format!("rc-update del {} default && service {} stop", name, name));
        } else {
            self.run_shell(&format!("rc-update add {} default && service {} start", name, name));
        }
        self.refresh_services();
        self.mode = Mode::Items;
    }
}

fn ui(f: &mut ratatui::Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(8), Constraint::Length(3), Constraint::Percentage(45)])
        .split(f.area());

    match app.mode {
        Mode::Rice | Mode::Confirm => {
            let (title, opts) = match app.mode {
                Mode::Rice => (" instantwm rice? ", vec!["Yes, apply the instant rice", "No, just install instantwm"]),
                _ => (" Confirm ", vec![app.confirm_q.as_str(), "No, go back"]),
            };
            let items: Vec<ListItem> = opts.into_iter().map(ListItem::new).collect();
            let list = List::new(items)
                .block(Block::default().borders(Borders::ALL).title(title))
                .highlight_style(Style::default().bg(Color::White).fg(Color::Black).add_modifier(Modifier::BOLD))
                .highlight_symbol("> ");
            let st = match app.mode {
                Mode::Rice => &mut app.rice_state,
                _ => &mut app.confirm_state,
            };
            f.render_stateful_widget(list, chunks[0], st);
        }
        Mode::Cats => {
            let items: Vec<ListItem> = app.cats.iter().map(|c| ListItem::new(c.name.as_str())).collect();
            let list = List::new(items)
                .block(Block::default().borders(Borders::ALL).title(" Silenctl — categories "))
                .highlight_style(Style::default().bg(Color::White).fg(Color::Black).add_modifier(Modifier::BOLD))
                .highlight_symbol("> ");
            f.render_stateful_widget(list, chunks[0], &mut app.cat_state);
        }
        _ => {
            let ci = app.ci();
            if app.cats[ci].name == "Services" {
                let items: Vec<ListItem> = app.services.iter().map(|(s, on)| {
                    let mark = if s.starts_with('(') { "    " } else if *on { "[+] " } else { "[ ] " };
                    ListItem::new(Line::from(format!("{}{}", mark, s)))
                }).collect();
                let list = List::new(items)
                    .block(Block::default().borders(Borders::ALL).title(" Services (Enter toggles) "))
                    .highlight_style(Style::default().bg(Color::White).fg(Color::Black).add_modifier(Modifier::BOLD))
                    .highlight_symbol("> ");
                f.render_stateful_widget(list, chunks[0], &mut app.item_state);
            } else {
                let items: Vec<ListItem> = app.cats[ci].items.iter().map(|i| {
                    let mark = match i.kind {
                        Kind::Packages => {
                            if i.checked {
                                "[x] "
                            } else {
                                "[ ] "
                            }
                        }
                        Kind::Action(_) => ">>  ",
                        Kind::Input(_) => "?>  ",
                        Kind::Service => "[ ] ",
                    };
                    let extra = match &i.kind {
                        Kind::Packages => format!("{} — {}", i.pkg, i.blurb),
                        _ => i.blurb.to_string(),
                    };
                    ListItem::new(Line::from(format!("{}{}", mark, extra)))
                }).collect();
                let title = format!(" {} ", app.cats[ci].name);
                let list = List::new(items)
                    .block(Block::default().borders(Borders::ALL).title(title))
                    .highlight_style(Style::default().bg(Color::White).fg(Color::Black).add_modifier(Modifier::BOLD))
                    .highlight_symbol("> ");
                f.render_stateful_widget(list, chunks[0], &mut app.item_state);
            }
        }
    }

    let n = app.selected_count();
    let hint = match app.mode {
        Mode::Cats => format!("Enter open · i install ({}) · q quit", n),
        Mode::Items => format!("Space select · i install ({}) · Esc back · q quit", n),
        Mode::Rice | Mode::Confirm => "Enter choose · Esc cancel".to_string(),
        Mode::Input => "type, Enter confirms, Esc cancels".to_string(),
        Mode::Busy => "working…".to_string(),
    };
    f.render_widget(Paragraph::new(hint).block(Block::default().borders(Borders::ALL)), chunks[1]);

    let log_text: Vec<Line> = match app.mode {
        Mode::Input => vec![Line::from(format!("> {}", app.input))],
        _ => app.log.iter().rev().take(50).rev().map(|l| Line::from(l.as_str())).collect(),
    };
    let title = match app.mode {
        Mode::Input => app.input_prompt,
        _ => " Log ",
    };
    f.render_widget(Paragraph::new(log_text).block(Block::default().borders(Borders::ALL).title(title)), chunks[2]);

    if app.mode == Mode::Busy {
        let dots = match app.busy_since {
            Some(t) => ".".repeat(1 + (t.elapsed().as_millis() / 400 % 3) as usize),
            None => ".".to_string(),
        };
        let popup = Paragraph::new(Line::from(format!("Installing {}", dots)))
            .block(Block::default().borders(Borders::ALL).title(" Please wait "));
        let area = centered_popup(f.area(), 40, 7);
        f.render_widget(Clear, area);
        f.render_widget(popup, area);
    }
}

fn centered_popup(area: Rect, pct_x: u16, height: u16) -> Rect {
    let y = area.height.saturating_sub(height) / 2;
    let w = area.width * pct_x / 100;
    let x = area.width.saturating_sub(w) / 2;
    Rect { x: area.x + x, y: area.y + y, width: w.min(area.width), height: height.min(area.height) }
}

fn is_root() -> bool {
    Command::new("id")
        .arg("-u")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "0")
        .unwrap_or(false)
}

fn start_input(app: &mut App, kind: InputKind, prompt: &'static str) {
    app.input_kind = kind;
    app.input_prompt = prompt;
    app.input.clear();
    app.mode = Mode::Input;
}

fn main() -> io::Result<()> {
    if !is_root() {
        let args: Vec<String> = std::env::args().collect();
        let prog = args.first().cloned().unwrap_or_else(|| "silenctl".into());
        let mut cmd = Command::new("sudo");
        cmd.arg(prog);
        if args.len() > 1 {
            cmd.args(&args[1..]);
        }
        match cmd.status() {
            Ok(s) => std::process::exit(s.code().unwrap_or(1)),
            Err(e) => {
                eprintln!("silenctl needs root: re-run with sudo ({})", e);
                std::process::exit(1);
            }
        }
    }
    enable_raw_mode()?;
    let mut stdout: Stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    let mut app = App::new();

    loop {
        terminal.draw(|f| ui(f, &mut app))?;
        if !event::poll(Duration::from_millis(200))? {
            continue;
        }
        if let Event::Key(key) = event::read()? {
            match app.mode {
                Mode::Cats => match key.code {
                    KeyCode::Char('q') | KeyCode::Esc => break,
                    KeyCode::Up | KeyCode::Char('k') => {
                        let i = app.ci();
                        app.cat_state.select(Some((i + app.cats.len() - 1) % app.cats.len()));
                    }
                    KeyCode::Down | KeyCode::Char('j') => {
                        let i = app.ci();
                        app.cat_state.select(Some((i + 1) % app.cats.len()));
                    }
                    KeyCode::Enter => {
                        app.item_state.select(Some(0));
                        app.refresh_services();
                        app.mode = Mode::Items;
                    }
                    KeyCode::Char('i') => {
                        app.install_selection();
                    }
                    _ => {}
                },
                Mode::Items => match key.code {
                    KeyCode::Esc => app.mode = Mode::Cats,
                    KeyCode::Char('q') => break,
                    KeyCode::Char('i') => {
                        app.install_selection();
                    }
                    KeyCode::Up | KeyCode::Char('k') => {
                        let n = app.cats[app.ci()].items.len().max(1);
                        let i = app.ii();
                        app.item_state.select(Some((i + n - 1) % n));
                    }
                    KeyCode::Down | KeyCode::Char('j') => {
                        let n = app.cats[app.ci()].items.len().max(1);
                        let i = app.ii();
                        app.item_state.select(Some((i + 1) % n));
                    }
                    KeyCode::Char(' ') => {
                        let i = app.ii();
                        let ci = app.ci();
                        if app.cats[ci].name == "Services" {
                            app.toggle_service();
                            terminal.draw(|f| ui(f, &mut app))?;
                            continue;
                        }
                        enum SpaceAct {
                            ToggleRice,
                            Toggle,
                            Run(String),
                            Ask(InputKind),
                        }
                        let act = {
                            let item = &app.cats[ci].items[i];
                            match &item.kind {
                                Kind::Packages => {
                                    if item.rice {
                                        SpaceAct::ToggleRice
                                    } else {
                                        SpaceAct::Toggle
                                    }
                                }
                                Kind::Action(cmd) => SpaceAct::Run(cmd.to_string()),
                                Kind::Input(kind) => SpaceAct::Ask(kind.clone()),
                                Kind::Service => SpaceAct::Toggle,
                            }
                        };
                        match act {
                            SpaceAct::ToggleRice => {
                                let item = &mut app.cats[ci].items[i];
                                item.checked = !item.checked;
                                if item.checked {
                                    app.rice_state.select(Some(0));
                                    app.mode = Mode::Rice;
                                } else {
                                    app.rice_wanted = false;
                                }
                            }
                            SpaceAct::Toggle => {
                                let item = &mut app.cats[ci].items[i];
                                item.checked = !item.checked;
                            }
                            SpaceAct::Run(cmd) => {
                                if cmd == "__INSTALL__" {
                                    app.install_selection();
                                } else if cmd == "reboot" {
                                    app.confirm_q = "Reboot now?".into();
                                    app.confirm_install = false;
                                    app.confirm_state.select(Some(1));
                                    app.mode = Mode::Confirm;
                                } else {
                                    app.run_shell(&cmd);
                                    terminal.draw(|f| ui(f, &mut app))?;
                                }
                            }
                            SpaceAct::Ask(kind) => {
                                let k = kind;
                                match k {
                                    InputKind::CustomPkg => start_input(&mut app, k, "Package name(s)"),
                                    InputKind::Hostname => start_input(&mut app, k, "New hostname"),
                                    InputKind::Timezone => start_input(&mut app, k, "Timezone (Area/City)"),
                                    InputKind::WifiSsid => start_input(&mut app, k, "WiFi network name (SSID)"),
                                    InputKind::NewUser => start_input(&mut app, k, "New username"),
                                    InputKind::RootPass => start_input(&mut app, k, "New root password"),
                                    _ => {}
                                }
                            }
                        }
                    }
                    KeyCode::Enter => {
                        let i = app.ii();
                        let ci = app.ci();
                        if app.cats[ci].name == "Services" {
                            app.toggle_service();
                            terminal.draw(|f| ui(f, &mut app))?;
                            continue;
                        }
                        let (is_pkg, is_rice, checked, kind) = {
                            let it = &app.cats[ci].items[i];
                            let k = match &it.kind {
                                Kind::Packages => 0,
                                Kind::Action(_) => 1,
                                Kind::Input(_) => 2,
                                Kind::Service => 3,
                            };
                            (k == 0, it.rice, it.checked, k)
                        };
                        if is_pkg {
                            if is_rice && !checked {
                                app.cats[ci].items[i].checked = true;
                                app.rice_state.select(Some(0));
                                app.mode = Mode::Rice;
                            } else {
                                app.install_selection();
                            }
                        } else if kind == 1 {
                            let cmd = match &app.cats[ci].items[i].kind {
                                Kind::Action(c) => *c,
                                _ => "",
                            };
                            if cmd == "__INSTALL__" {
                                app.install_selection();
                            } else if cmd == "reboot" {
                                app.confirm_q = "Reboot now?".into();
                                app.confirm_install = false;
                                app.confirm_state.select(Some(1));
                                app.mode = Mode::Confirm;
                            } else if !cmd.is_empty() {
                                app.run_shell(cmd);
                                terminal.draw(|f| ui(f, &mut app))?;
                            }
                        } else if kind == 2 {
                            let k = match &app.cats[ci].items[i].kind {
                                Kind::Input(k) => k.clone(),
                                _ => InputKind::CustomPkg,
                            };
                            match k {
                                InputKind::CustomPkg => start_input(&mut app, k, "Package name(s)"),
                                InputKind::Hostname => start_input(&mut app, k, "New hostname"),
                                InputKind::Timezone => start_input(&mut app, k, "Timezone (Area/City)"),
                                InputKind::WifiSsid => start_input(&mut app, k, "WiFi network name (SSID)"),
                                InputKind::NewUser => start_input(&mut app, k, "New username"),
                                InputKind::RootPass => start_input(&mut app, k, "New root password"),
                                _ => {}
                            }
                        }
                    }
                    _ => {}
                },
                Mode::Rice => match key.code {
                    KeyCode::Esc => {
                        let i = app.ii();
                        let ci = app.ci();
                        app.cats[ci].items[i].checked = false;
                        app.rice_wanted = false;
                        app.mode = Mode::Items;
                    }
                    KeyCode::Up | KeyCode::Down => {
                        let cur = app.rice_state.selected().unwrap_or(0);
                        app.rice_state.select(Some(1 - cur.min(1)));
                    }
                    KeyCode::Enter => {
                        let yes = app.rice_state.selected().unwrap_or(0) == 0;
                        app.rice_wanted = yes;
                        app.push_log(if yes {
                            "rice: yes — will apply after install".into()
                        } else {
                            "rice: no — plain install".into()
                        });
                        app.mode = Mode::Items;
                    }
                    _ => {}
                },
                Mode::Confirm => match key.code {
                    KeyCode::Esc => {
                        app.mode = Mode::Items;
                    }
                    KeyCode::Up | KeyCode::Down => {
                        let cur = app.confirm_state.selected().unwrap_or(1);
                        app.confirm_state.select(Some(1 - cur.min(1)));
                    }
                    KeyCode::Enter => {
                        if app.confirm_state.selected().unwrap_or(1) == 0 {
                            if app.confirm_install {
                                app.do_install();
                            } else {
                                app.want_reboot = true;
                                break;
                            }
                        }
                        app.mode = Mode::Items;
                    }
                    _ => {}
                },
                Mode::Input => match key.code {
                    KeyCode::Esc => {
                        app.mode = Mode::Items;
                        app.input.clear();
                    }
                    KeyCode::Enter => {
                        app.submit_input();
                    }
                    KeyCode::Backspace => {
                        app.input.pop();
                    }
                    KeyCode::Char(c) => {
                        app.input.push(c);
                    }
                    _ => {}
                },
                Mode::Busy => {}
            }
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    if app.want_reboot {
        let _ = Command::new("reboot").status();
    }
    Ok(())
}
