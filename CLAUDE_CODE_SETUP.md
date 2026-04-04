# Claude Code Setup Guide

This document explains how Claude Code is installed and configured in your NixOS system.

## Installation Method

Claude Code is installed via npm (Node.js package manager) rather than through nixpkgs because:
- The official Claude Code package updates frequently
- The nixpkgs versions often become outdated quickly
- npm installation ensures you get the latest stable version

## Prerequisites

The following are already configured in your system:
- Node.js 22 (installed via `home.nix`)
- npm configured to use `~/.npm-global` as the global packages directory
- Shell configuration with proper PATH setup

## Installation

Claude Code has been installed using:

```bash
npm install -g @anthropic-ai/claude-code
```

The binary is installed as `claude` in `~/.npm-global/bin/claude`.

## Verification

To verify the installation, run:

```bash
claude --version
```

You should see output like: `2.1.92 (Claude Code)`

## Shell Aliases

For convenience, the following aliases have been configured:

### Fish Shell
- `cc` → `claude` (Claude Code shortcut)

### Bash
- `cc` → `claude` (Claude Code shortcut)

## First Time Setup

1. **Authenticate with Anthropic:**
   ```bash
   claude auth login
   ```
   
   This will open a browser window for you to sign in with your Anthropic account (Claude Pro, Max, or API credentials).

2. **Test Claude Code:**
   ```bash
   cc --help
   ```
   
   Or simply:
   ```bash
   cc
   ```

## Basic Usage

- Start Claude Code: `cc` or `claude`
- Ask Claude to help with code: Just type your request
- Exit Claude Code: Type `/exit` or press `Ctrl+D`

## Common Commands

- `/help` - Show available commands
- `/files` - Show files in context
- `/commit` - Generate and create a git commit
- `/diff` - Show git diff
- `/exit` - Exit Claude Code

## Updating Claude Code

To update to the latest version:

```bash
npm update -g @anthropic-ai/claude-code
```

Or to reinstall:

```bash
npm install -g @anthropic-ai/claude-code
```

## Configuration

Claude Code stores its configuration in:
- `~/.claude/` - Settings and authentication
- `~/.config/claude-code/` - Additional configuration

## Troubleshooting

### Command not found

If you get "command not found" after installation:

1. Ensure the PATH is set correctly:
   ```bash
   echo $PATH | grep npm-global
   ```

2. If not present, reload your shell configuration:
   ```bash
   # For Fish
   source ~/.config/fish/config.fish
   
   # For Bash
   source ~/.bashrc
   ```

3. Or restart your terminal

### npm global path issues

If npm packages aren't found, verify the npm prefix:

```bash
npm config get prefix
```

Should show: `/home/me/.npm-global`

If not, set it:
```bash
npm config set prefix '~/.npm-global'
```

### Authentication Issues

If you have trouble authenticating:

1. Make sure you have an active Claude subscription (Pro or Max)
2. Try logging out and back in:
   ```bash
   claude auth logout
   claude auth login
   ```

## Resources

- [Official Documentation](https://code.claude.com/docs)
- [CLI Reference](https://code.claude.com/docs/en/cli-reference)
- [GitHub Repository](https://github.com/anthropics/claude-code)

## Notes

- Claude Code requires an active internet connection
- It uses your Claude subscription or API credits
- The tool can read and modify files in your current directory (with your permission)
- Always review changes before accepting them

## Integration with NixOS

This setup is maintained as part of your Home Manager configuration in:
- `~/nix/hosts/g16/me.nix`

If you rebuild your system, Node.js will remain installed, but you may need to reinstall Claude Code via npm if the `~/.npm-global` directory is cleared.