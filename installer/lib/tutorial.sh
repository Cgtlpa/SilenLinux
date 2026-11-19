#!/bin/bash

# Post-installation tutorial for Silen Linux
# Displayed after successful installation

show_tutorial() {
    local title="Welcome to Silen Linux"
    
    # Screen 1: Welcome
    whiptail --title "$title" --msgbox "Welcome to Silen Linux!\n\n\"Reliable by default. Powerful when you want it.\"\n\nSilen is a minimal, independent x86_64 Linux distribution focused on simplicity, reliability, and user control. It uses OpenRC for init, iwd for Wi-Fi, and Cres for package management." 12 70
    
    # Screen 2: Cres Package Manager
    whiptail --title "$title - Cres Package Manager" --msgbox "Cres is Silen's package manager.\n\nKey commands:\n  sudo cres get <package>     Install a package\n  sudo cres rm <package>      Remove a package\n  sudo cres update              Update all packages\n  cres search <pattern>         Search available packages\n  cres list                     List installed packages\n  cres info <package>           Show package details\n\nExample: Install fastfetch\n  sudo cres get fastfetch\n\nSystem packages (kernels, drivers, desktop) install to /.\nLeaf apps install isolated with shims in /usr/local/bin." 18 70
    
    # Screen 3: InstantWM
    whiptail --title "$title - InstantWM" --msgbox "InstantWM is Silen's default Wayland compositor - a hybrid tiling window manager.\n\nKey bindings (Super = Windows key):\n  Super+Return    Open terminal (kitty)\n  Super+Space     Application launcher (rofi)\n  Super+E         InstantMenu\n  Super+Shift+Q   Close window\n  Super+C         Toggle floating\n  Super+M         Toggle tiling/maximized\n  Super+Arrows    Focus windows\n  Super+R         Reset layout\n\nConfig file: ~/.config/instantwm/config.toml\nTheme: catppuccin-mocha (default)" 18 70
    
    # Screen 4: System Basics
    whiptail --title "$title - System Basics" --msgbox "Silen uses OpenRC for service management:\n  rc-status           Show running services\n  rc-service <svc> start|stop|restart\n  rc-update add <svc> <runlevel>  Enable service\n\nImportant configs:\n  /etc/conf.d/keymaps    Keyboard layout\n  /etc/locale.gen        Locale generation\n  /etc/env.d/02locale    System locale\n  /etc/iwd/main.conf     Wi-Fi configuration\n  /etc/resolv.conf       DNS (managed by iwd)\n\nNetwork: iwctl for Wi-Fi, dhcpcd for wired.\nNo NetworkManager - iwd handles everything." 18 70
    
    # Screen 5: Help & Documentation
    whiptail --title "$title - Help & Documentation" --msgbox "Getting help:\n  man silen-installer     Installation guide\n  man cres                Package manager manual\n  silen-wifi-check        Wi-Fi diagnostics\n  silen-nvidia-check      GPU/NVIDIA diagnostics\n  silenfetch              System info (install fastfetch)\n\nOnline resources:\n  GitHub: https://github.com/SilenLinux\n  Issues: Report bugs on GitHub\n\nAfter reboot, run 'silenfetch' to verify your installation." 14 70
    
    # Final screen: Installation complete
    local choice
    choice=$(whiptail --title "$title - Installation Complete" --menu "Silen Linux has been successfully installed!\n\nWhat would you like to do?" 15 60 2 \
        "1" "Reboot into Silen" \
        "2" "Exit to shell" 3>&1 1>&2 2>&3)
    
    case "$choice" in
        1)
            sync
            reboot -f
            ;;
        2)
            return 0
            ;;
    esac
}