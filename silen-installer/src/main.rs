mod backend;

use backend::{InstallSettings, TITLE};
use std::sync::{Arc, Mutex};

// wizard pages in order, installing runs on its own thread
#[derive(PartialEq, Clone, Copy)]
enum Page {
    Loading,
    Welcome,
    Disk,
    Settings,
    Confirm,
    Installing,
    Done,
}

const UI_SCALE: f32 = 1.5;

struct InstallerApp {
    page: Page,
    settings: InstallSettings,
    disks: Vec<(String, String)>,
    log: Arc<Mutex<Vec<String>>>,
    installing: bool,
    done_ok: bool,
    done_msg: String,
    confirm_wipe: bool,
    show_rootpass: bool,
    show_userpass: bool,
    error: String,
    preview: bool,
    loading_since: std::time::Instant,
}

impl Default for InstallerApp {
    fn default() -> Self {
        let preview = std::env::args().any(|a| a == "--preview");
        let disks = backend::list_disks();
        Self {
            page: Page::Loading,
            settings: InstallSettings::default(),
            disks,
            log: Arc::new(Mutex::new(Vec::new())),
            installing: false,
            done_ok: false,
            done_msg: String::new(),
            confirm_wipe: false,
            show_rootpass: false,
            show_userpass: false,
            error: String::new(),
            preview,
            loading_since: std::time::Instant::now(),
        }
    }
}

impl InstallerApp {

    fn start_install(&mut self, ctx: egui::Context) {
        // the wipe runs on a thread so the window never freezes up
        if self.installing {
            return;
        }
        self.installing = true;
        self.page = Page::Installing;
        self.error.clear();
        let mut settings = std::mem::take(&mut self.settings);
        settings.hostname = backend::sanitize_hostname(&settings.hostname);
        if settings.hostname.is_empty() {
            settings.hostname = "silen".into();
        }
        let log_arc = self.log.clone();
        let ctx_thread = ctx.clone();
        std::thread::spawn(move || {
            let log_arc2 = log_arc.clone();
            let ctx2 = ctx_thread.clone();
            let mut log_fn = move |line: String| {
                if let Ok(mut v) = log_arc2.lock() {
                    v.push(line);
                }
                ctx2.request_repaint();
            };
            let res = backend::do_install(&mut settings, &mut log_fn);
            if let Ok(mut v) = log_arc.lock() {
                match &res {
                    Ok(()) => v.push("[installer] Silen is installed. Reboot to use it.".into()),
                    Err(e) => v.push(format!("[installer] FAILED: {}", e)),
                }
            }
            ctx_thread.request_repaint();
        });
    }
}

impl eframe::App for InstallerApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        ctx.set_zoom_factor(UI_SCALE);
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading(format!("{} installer", TITLE));
            ui.separator();
            if !backend::must_be_root() && !self.preview {
                ui.colored_label(egui::Color32::RED, "this installer needs root");
                return;
            }
            if self.preview && !backend::must_be_root() {
                ui.colored_label(egui::Color32::YELLOW, "preview mode (--preview): install will refuse without root");
            }
            if !backend::is_efi() {
                ui.colored_label(egui::Color32::RED, "legacy boot detected: Silen installs an EFI bootloader only. Reboot the ISO in UEFI mode.");
            }
            match self.page {
                Page::Loading => {
                    ui.vertical_centered(|ui| {
                        ui.add_space(60.0);
                        ui.heading(format!("{} installer", TITLE));
                        ui.add_space(16.0);
                        ui.spinner();
                        ui.add_space(8.0);
                        ui.label("Starting… probing disks and install medium");
                    });
                    if self.loading_since.elapsed() >= std::time::Duration::from_millis(700) {
                        self.page = Page::Welcome;
                    } else {
                        ctx.request_repaint();
                    }
                }
                Page::Welcome => {
                    ui.label("Welcome to the Silen Linux installer (instantwm live edition).");
                    ui.label("This will wipe the selected disk: GPT with a 512M ESP (FAT32) + root.");
                    ui.label("Live session runs as root with no login; the installer auto-launched on boot.");
                    ui.add_space(8.0);
                    if ui.button("Install Silen").clicked() {
                        self.disks = backend::list_disks();
                        self.page = Page::Disk;
                    }
                    if ui.button("Open shell (exit installer)").clicked() {
                        std::process::exit(0);
                    }
                    if ui.button("Reboot").clicked() {
                        let _ = std::process::Command::new("reboot").arg("-f").status();
                    }
                }
                Page::Disk => {
                    ui.label("Select the disk to install on:");
                    if self.disks.is_empty() {
                        ui.colored_label(egui::Color32::RED, "no disks found");
                    }
                    for (dev, label) in self.disks.clone() {
                        let selected = self.settings.disk == dev;
                        if ui.selectable_label(selected, format!("{}  [{}]", dev, label)).clicked() {
                            self.settings.disk = dev.clone();
                        }
                    }
                    ui.add_space(8.0);
                    ui.checkbox(&mut self.confirm_wipe, "I understand the selected disk will be wiped");
                    if !self.error.is_empty() {
                        ui.colored_label(egui::Color32::RED, &self.error);
                    }
                    ui.horizontal(|ui| {
                        if ui.button("Back").clicked() {
                            self.page = Page::Welcome;
                        }
                        if ui.button("Next").clicked() {
                            if self.settings.disk.is_empty() {
                                self.error = "pick a disk first".into();
                            } else if backend::medium_on_disk(&self.settings.disk) {
                                self.error = format!("{} holds the install medium, pick a different disk", self.settings.disk);
                            } else if !self.confirm_wipe {
                                self.error = "tick the wipe confirmation to continue".into();
                            } else if !backend::medium_has_tarball() {
                                self.error = "no Silen tarball found at /mnt".into();
                            } else {
                                self.error.clear();
                                self.page = Page::Settings;
                            }
                        }
                    });
                    if ui.button("Rescan disks").clicked() {
                        self.disks = backend::list_disks();
                    }
                }
                Page::Settings => {
                    ui.label("System settings:");
                    egui::Grid::new("settings").num_columns(2).show(ui, |ui| {
                        ui.label("hostname:");
                        ui.text_edit_singleline(&mut self.settings.hostname);
                        ui.end_row();
                        ui.label("root password:");
                        ui.horizontal(|ui| {
                            if self.show_rootpass {
                                ui.text_edit_singleline(&mut self.settings.rootpass);
                            } else {
                                ui.add(egui::TextEdit::singleline(&mut self.settings.rootpass).password(true));
                            }
                            ui.checkbox(&mut self.show_rootpass, "show");
                        });
                        ui.end_row();
                        ui.label("user (empty = skip):");
                        ui.text_edit_singleline(&mut self.settings.newuser);
                        ui.end_row();
                        ui.label("user password:");
                        ui.horizontal(|ui| {
                            if self.show_userpass {
                                ui.text_edit_singleline(&mut self.settings.userpass);
                            } else {
                                ui.add(egui::TextEdit::singleline(&mut self.settings.userpass).password(true));
                            }
                            ui.checkbox(&mut self.show_userpass, "show");
                        });
                        ui.end_row();
                        ui.label("timezone:");
                        egui::ComboBox::from_id_salt("tz").selected_text(&self.settings.zone).show_ui(ui, |ui| {
                            for z in ["UTC", "Europe/Berlin", "Europe/London", "Europe/Paris", "Europe/Moscow", "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "America/Sao_Paulo", "Asia/Tokyo", "Asia/Shanghai", "Asia/Kolkata", "Asia/Dubai", "Australia/Sydney"] {
                                ui.selectable_value(&mut self.settings.zone, z.to_string(), z);
                            }
                        });
                        ui.end_row();
                        ui.label("keyboard:");
                        egui::ComboBox::from_id_salt("km").selected_text(&self.settings.keymap).show_ui(ui, |ui| {
                            for k in ["us", "de", "gb", "fr", "es", "it", "pt", "nl", "se", "no", "dk", "fi", "pl", "ru", "tr"] {
                                ui.selectable_value(&mut self.settings.keymap, k.to_string(), k);
                            }
                        });
                        ui.end_row();
                        ui.label("locale:");
                        egui::ComboBox::from_id_salt("lc").selected_text(&self.settings.locale).show_ui(ui, |ui| {
                            for l in ["en_US.UTF-8", "de_DE.UTF-8", "en_GB.UTF-8", "fr_FR.UTF-8", "es_ES.UTF-8"] {
                                ui.selectable_value(&mut self.settings.locale, l.to_string(), l);
                            }
                        });
                        ui.end_row();
                        ui.label("filesystem:");
                        egui::ComboBox::from_id_salt("fs").selected_text(&self.settings.fstype).show_ui(ui, |ui| {
                            for f in ["ext4", "btrfs", "vfat"] {
                                ui.selectable_value(&mut self.settings.fstype, f.to_string(), f);
                            }
                        });
                        ui.end_row();
                        ui.label("swapfile:");
                        egui::ComboBox::from_id_salt("sw").selected_text(if self.settings.want_swap.is_empty() { "none" } else { &self.settings.want_swap }).show_ui(ui, |ui| {
                            for s in ["none", "1G", "2G", "4G", "8G"] {
                                let v = if s == "none" { String::new() } else { s.to_string() };
                                ui.selectable_value(&mut self.settings.want_swap, v, s);
                            }
                        });
                        ui.end_row();
                    });
                    if !self.error.is_empty() {
                        ui.colored_label(egui::Color32::RED, &self.error);
                    }
                    ui.horizontal(|ui| {
                        if ui.button("Back").clicked() {
                            self.page = Page::Disk;
                        }
                        if ui.button("Next").clicked() {
                            if self.settings.rootpass.is_empty() {
                                self.error = "password can't be empty".into();
                            } else if self.settings.rootpass.contains(':') {
                                self.error = "password can't contain :".into();
                            } else if let Err(e) = backend::valid_username(&self.settings.newuser) {
                                self.error = e.to_string();
                            } else if !self.settings.newuser.is_empty() && self.settings.userpass.is_empty() {
                                self.error = "user password can't be empty".into();
                            } else {
                                self.error.clear();
                                self.page = Page::Confirm;
                            }
                        }
                    });
                }
                Page::Confirm => {
                    ui.label(format!("disk: {}", self.settings.disk));
                    ui.label(format!("hostname: {}", self.settings.hostname));
                    ui.label(format!("user: {}", if self.settings.newuser.is_empty() { "none" } else { &self.settings.newuser }));
                    ui.label(format!("timezone: {}  keyboard: {}  locale: {}", self.settings.zone, self.settings.keymap, self.settings.locale));
                    ui.label(format!("filesystem: {}  swapfile: {}", self.settings.fstype, if self.settings.want_swap.is_empty() { "none" } else { &self.settings.want_swap }));
                    ui.add_space(8.0);
                    ui.horizontal(|ui| {
                        if ui.button("Back").clicked() {
                            self.page = Page::Settings;
                        }
                        if ui.button("Install now (wipe disk)").clicked() {
                            let ctx2 = ctx.clone();
                            self.start_install(ctx2);
                        }
                    });
                }
                Page::Installing => {
                    ui.label("Installing... do not power off.");
                    egui::ScrollArea::vertical().max_height(400.0).stick_to_bottom(true).show(ui, |ui| {
                        if let Ok(v) = self.log.lock() {
                            for line in v.iter() {
                                ui.monospace(line);
                            }
                            let finished = v.iter().any(|l| l.contains("Silen is installed") || l.contains("FAILED:"));
                            if finished && !self.installing {
                            } else if finished {
                                self.installing = false;
                                self.done_ok = v.iter().any(|l| l.contains("Silen is installed"));
                                self.done_msg = v.iter().rev().find(|l| l.contains("FAILED:") || l.contains("installed")).cloned().unwrap_or_default();
                            }
                        }
                    });
                    if !self.installing {
                        ui.add_space(8.0);
                        if ui.button("Continue").clicked() {
                            self.page = Page::Done;
                        }
                    }
                }
                Page::Done => {
                    ui.label(&self.done_msg);
                    ui.label("Wi-Fi: use iwctl in the installed system (help: silen-wifi-check).");
                    ui.label("Guide saved to /usr/share/silen/spk-help.txt");
                    ui.horizontal(|ui| {
                        if ui.button("Reboot now").clicked() {
                            let _ = std::process::Command::new("reboot").arg("-f").status();
                        }
                        if ui.button("Back to start").clicked() {
                            self.page = Page::Welcome;
                            self.installing = false;
                            if let Ok(mut v) = self.log.lock() {
                                v.clear();
                            }
                        }
                    });
                }
            }
        });
    }
}

fn main() -> eframe::Result<()> {
    // --cli just prints a checklist, no args opens the real gui
    if std::env::args().any(|a| a == "--cli-help" || a == "--help" || a == "-h") {
        eprintln!("usage: silen-installer [--cli] [--preview] — graphical Silen installer (Rust+egui port of installer/*.sh)");
        eprintln!("  no args: open the egui wizard (auto-launched by live init under instantwm, no login)");
        eprintln!("  --preview: open the wizard without root (look around only, install still needs root)");
        eprintln!("  --cli:   run a non-interactive checklist (disks, medium, efi) and exit");
        return Ok(());
    }
    if std::env::args().any(|a| a == "--cli") {
        println!("Silen installer CLI check:");
        println!("  root: {}", if backend::must_be_root() { "yes" } else { "NO (needs root)" });
        println!("  efi: {}", if backend::is_efi() { "yes" } else { "NO (legacy boot, EFI install will refuse)" });
        println!("  medium tarball: {}", if backend::medium_has_tarball() { "found" } else { "MISSING at /mnt" });
        for (dev, label) in backend::list_disks() {
            println!("  disk: {} [{}]", dev, label);
        }
        return Ok(());
    }
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1000.0, 720.0]).with_title("Silen Linux installer"),
        ..Default::default()
    };
    eframe::run_native("Silen Linux installer", options, Box::new(|_cc| Ok(Box::new(InstallerApp::default()))))
}
