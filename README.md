# Hyprland Config Transpiler (0.55+)

## Overview
This project is a high-performance, two-pass LPeg transpiler designed to effortlessly migrate legacy Hyprland `.conf` configuration files into safe, fully compliant Hyprland 0.55 Lua scripts. It reads your existing shell-style configuration, parses it into an Abstract Syntax Tree (AST), and emits properly formatted, modular, and functional Lua scripts designed exclusively for the latest Hyprland 0.55 API.

## Dependencies
This tool runs natively on Lua 5.1 or LuaJIT and strictly requires the `lpeg` library.

**Arch / CachyOS Setup:**
```bash
sudo pacman -S luajit lua51-lpeg
```
*(Note: Package names may vary slightly by distro. On Arch, `lua-lpeg` is for lua5.4, while `lua51-lpeg` is for lua5.1/LuaJIT)*

## Usage Guide
The transpiler operates via the command line. Provide your source configuration file to automatically convert it, along with any dynamically linked (sourced) configurations.

**Run the transpiler:**
```bash
luajit hypr_convert.lua <path/to/hyprland.conf>
```

For example, to transpile your default configuration:
```bash
luajit hypr_convert.lua ~/.config/hypr/hyprland.conf
```

This process is strictly non-destructive. By default, the transpiler generates matching `.lua` files alongside your original configs (e.g., creating `hyprland.lua`), leaving your legacy settings untouched. If a `.lua` file already exists in the target path, the transpiler will prompt for user confirmation before overwriting it.

## Testing Procedures
The project is built on a heavily validated architecture to guarantee emission safety (e.g. handling uppercase keybindings, complex `hl.dsp` namespace dispatcher conversions, submaps, and expanding shell environment variables). 

The internal testing framework is completely decoupled from the primary engine for optimal production performance.

**To run the test suite:**
```bash
luajit test_suite.lua
```

Running the test suite executes an autonomous mock compilation pipeline. It ensures that the transpiler correctly maps AST structures into safe Lua payloads without breaking. A successful run will print out passing regression assertions and exit with a `0` status code, verifying stability against core API translation logic.
