# Personal NixOS Configuration

A comprehensive, modular NixOS configuration with Home Manager integration, optimized for development, gaming, and daily use on an ASUS ROG laptop with NVIDIA graphics.

## 🚀 Features

- **Modular Architecture**: Clean separation of concerns with reusable modules
- **NVIDIA Support**: Optimized hybrid graphics with Intel/NVIDIA PRIME
- **Gaming Ready**: Steam, GameMode, MangoHud, and gaming optimizations
- **Development Environment**: Python development, Docker, and essential development tools
- **Laptop Optimized**: Power management, thermal control, and ASUS ROG features
- **Modern Desktop**: GNOME with Wayland, fractional scaling, and customizations
- **Automated Management**: Justfile commands for easy system maintenance

## 📁 Structure

```
nix/
├── flake.nix                 # Main flake configuration
├── flake.lock                # Locked input versions
├── justfile                  # Command shortcuts
├── README.md                 # This file
├── hosts/
│   └── g16/                  # Host-specific configuration
│       ├── configuration.nix # Main system config
│       ├── hardware-configuration.nix # Hardware detection
│       ├── me.nix            # Home Manager config
│       └── options.nix       # Configuration options
└── modules/
    ├── desktop/
    │   └── gnome.nix         # GNOME desktop environment
    ├── programs/
    │   ├── development.nix   # Development tools
    │   └── gaming.nix        # Gaming setup
    ├── system/
    │   ├── base.nix          # Base system configuration
    │   └── laptop.nix        # Laptop optimizations
    └── nvidia.nix            # NVIDIA graphics configuration
```

## 🛠️ Quick Start

### Prerequisites

- NixOS installed with flakes enabled
- Git configured
- Internet connection

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/your-username/nix.git ~/nix
   cd ~/nix
   ```

2. **Review and customize configuration:**
   ```bash
   # Edit host-specific settings
   vim hosts/g16/configuration.nix
   
   # Customize user settings
   vim hosts/g16/me.nix
   
   # Adjust hardware-specific options
   vim hosts/g16/hardware-configuration.nix
   ```

3. **Build and switch:**
   ```bash
   # Using just (recommended)
   just switch
   
   # Or manually
   sudo nixos-rebuild switch --flake .#g16
   ```

4. **Apply Home Manager configuration:**
   ```bash
   just hm-switch
   ```

## 🎮 Just Commands

This configuration includes a `justfile` with convenient shortcuts:

### Build and Deploy
- `just build` - Build configuration without switching
- `just switch` - Build and switch to new configuration
- `just test` - Test configuration temporarily
- `just boot` - Set configuration for next boot

### Updates
- `just update` - Update all flake inputs
- `just upgrade` - Update and set for next boot (safe for Nvidia drivers)
- `just upgrade-now` - Update and switch immediately (may fail with Nvidia driver mismatch)
- `just hm-switch` - Switch Home Manager configuration

### Maintenance
- `just clean` - Clean old generations (7+ days)
- `just cleanup` - Deep cleanup (all old generations)
- `just optimize` - Optimize Nix store

### Development
- `just fmt` - Format all Nix files
- `just check` - Check configuration syntax
- `just shell` - Enter development shell

### System Info
- `just status` - Show system status
- `just hardware` - Show hardware information
- `just generations` - List system generations
- `just health` - Quick health check

Run `just` without arguments to see all available commands.

## 🤖 Claude Code (AI Coding Assistant)

Claude Code is installed via npm for the latest version. It's an AI-powered coding assistant that runs in your terminal.

### Setup

1. **Authenticate (first time only):**
   ```bash
   claude auth login
   ```
   This opens a browser for authentication with your Claude account.

2. **Start Claude Code:**
   ```bash
   cc
   # or
   claude
   ```

3. **Common commands inside Claude:**
   - `/help` - Show available commands
   - `/commit` - Generate and create a git commit
   - `/diff` - Show git diff
   - `/files` - Show files in context
   - `/exit` - Exit Claude Code

### Updating Claude Code

```bash
npm update -g @anthropic-ai/claude-code
```

📖 **Detailed setup guide:** See [CLAUDE_CODE_SETUP.md](./CLAUDE_CODE_SETUP.md)

## 🔧 Configuration Guide

### Hardware-Specific Setup

#### NVIDIA Graphics
The configuration includes optimized NVIDIA settings for:
- Hybrid graphics (Intel + NVIDIA)
- Wayland compatibility
- Power management
- Gaming performance

Update bus IDs in `modules/nvidia.nix`:
```bash
# Find your GPU bus IDs
lspci | grep -E "VGA|3D"
```

#### ASUS ROG Features
- Supergfxd for GPU switching
- ASUSD for fan control and keyboard
- Power profiles daemon for battery optimization

### User Customization

#### Adding Packages
System packages go in `hosts/g16/configuration.nix`:
```nix
environment.systemPackages = with pkgs; [
  your-package-here
];
```

User packages go in `hosts/g16/me.nix`:
```nix
home.packages = with pkgs; [
  your-package-here
];
```

#### Shell Configuration
The configuration uses Fish shell by default with:
- Custom aliases and functions
- Starship prompt
- Direnv integration

Modify in `hosts/g16/me.nix` under `programs.fish`.

#### Desktop Customization
GNOME settings are managed via dconf in `hosts/g16/me.nix`:
- Fractional scaling (1.15x by default)
- Custom keybindings
- Theme preferences
- Extensions (add via NUR)

### Development Environments

#### Available Shells
```bash
nix develop .#python    # Python development
```

#### Programming Languages
Enabled by default:
- Python 3.12 with UV package manager

Add more languages in `modules/programs/development.nix` as needed.

### Gaming Setup

The configuration includes:
- Steam with Proton support
- GameMode for performance optimization
- MangoHud for performance monitoring
- Lutris for non-Steam games
- Wine compatibility layer

Gaming optimizations:
- Kernel parameters for performance
- Audio optimizations for low latency
- Network tuning for online gaming

## 🚨 Troubleshooting

### Common Issues

#### NVIDIA Driver Problems
```bash
# Check NVIDIA status
nvidia-smi

# Verify driver loading
lsmod | grep nvidia

# Check X11/Wayland compatibility
echo $XDG_SESSION_TYPE
```

#### Build Failures
```bash
# Clear build cache
nix-collect-garbage -d

# Repair Nix store
just repair

# Check configuration syntax
just check
```

#### Boot Issues
```bash
# Boot into previous generation
# At boot menu, select previous generation

# Or rollback from running system
just rollback
```

#### Home Manager Issues
```bash
# Reset Home Manager
rm -rf ~/.config/nixpkgs
home-manager switch --flake .#me@g16
```

### Performance Issues

#### Slow Builds
- Enable binary cache (already configured)
- Use `nix build` with `--builders` for remote building
- Consider `nix-direnv` for faster shell loading

#### Memory Usage
- Adjust ZRAM settings in `modules/system/base.nix`
- Monitor with `just monitor`

### Recovery

#### Emergency Boot
1. Boot from NixOS installer
2. Mount your system
3. Chroot and rebuild:
   ```bash
   nixos-enter
   cd /home/username/nix
   nixos-rebuild switch --flake .#g16
   ```

#### Configuration Backup
```bash
# Create backup before major changes
just backup

# Restore from backup if needed
cp -r ~/nix.backup.* ~/nix-restored
cd ~/nix-restored
```

## 📚 Learning Resources

### NixOS Documentation
- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Nixpkgs Manual](https://nixos.org/manual/nixpkgs/stable/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)

### Community Resources
- [NixOS Wiki](https://nixos.wiki/)
- [NixOS Discourse](https://discourse.nixos.org/)
- [r/NixOS](https://www.reddit.com/r/NixOS/)

### Configuration Examples
- [NixOS Hardware](https://github.com/NixOS/nixos-hardware)
- [Nix Community Configs](https://github.com/nix-community/awesome-nix)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Test your changes thoroughly
4. Format code with `just fmt`
5. Submit a pull request

### Code Style
- Use `nixfmt-classic` for formatting
- Write descriptive commit messages
- Add comments for complex configurations
- Test on clean system when possible

## 📄 License

This configuration is available under the MIT License. See individual package licenses for their respective terms.

## 🙏 Acknowledgments

- [NixOS Community](https://nixos.org/) for the amazing ecosystem
- [Home Manager](https://github.com/nix-community/home-manager) maintainers
- [nixos-hardware](https://github.com/NixOS/nixos-hardware) contributors
- All the package maintainers in nixpkgs

---

**Note**: This configuration is tailored for my specific hardware (ASUS ROG G16) and use cases. You'll need to adjust hardware-specific settings, user preferences, and package selections for your system.