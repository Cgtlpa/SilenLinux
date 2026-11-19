<p align="center">
  <img src="https://raw.githubusercontent.com/Cgtlpa/SilenLinux/main/assets/logo.png" alt="Silen Linux" width="100"/>
  <img src="https://raw.githubusercontent.com/Cgtlpa/SilenLinux/main/assets/mascot.png" alt="Silen Mascot" width="150"/>
</p>

<h1 align="center">Silen Linux</h1>

<p align="center">
  <b>Independent, lightweight x86_64 Linux distribution</b>
</p>

---

**No systemd • No NetworkManager • No bloat**

- **Init**: OpenRC
- **Package Manager**: `cres` (custom, Go)
- **Wi-Fi**: iwd only
- **Desktop**: InstantWM (Wayland)
- **Bootloader**: GRUB2 (UEFI-only)
- **Kernel**: Linux 6.18 LTS

## Quick Start

```bash
# Build ISO
make iso

# Test in QEMU (requires KVM)
make qemu
```

## Links

- **Discord**: https://discord.gg/6b4uaaQDzN
- **GitHub**: https://github.com/Cgtlpa/SilenLinux
- **Issues**: https://github.com/Cgtlpa/SilenLinux/issues

## License

AGPL-3.0-or-later — see `LICENSE`.