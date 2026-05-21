---
trigger: always_on
description: Hyprland 0.55 specific Lua API mapping rules
---

---

## description: Hyprland 0.55 specific Lua API mapping rules

# API TRANSLATION MAPPING

- Functional Binds: Do NOT emit keybinds as a standard Lua table. The 0.55 API requires the `hl.bind()` function.
  - STRING ESCAPING CRITICAL: Wrap dispatcher arguments in quotes (`hl.dsp.exec_cmd("waybar")`).
  - MODIFIER SYNTAX CRITICAL: Modifiers MUST be separated by spaces around the plus sign (e.g., `"SUPER + SHIFT"`). Convert to uppercase.
  - EMPTY MODIFIERS: If a bind has no modifiers, emit ONLY the key (e.g., `"Print"`).
- KEY CASE SENSITIVITY (CRITICAL): The `key` argument is strictly case-sensitive. All standard keyboard alpha-keys, single letters (e.g., `Q`, `K`, `Z`), and named control keys (e.g., `ESCAPE`, `SLASH`, `SPACE`, `PRINT`, `RETURN`) MUST be completely converted to UPPERCASE. Mixed/CamelCase multimedia or driver keys (e.g., `XF86AudioMute`, `Caps_Lock`, `mouse:272`) must be PRESERVED exactly as written.
- Bind Flags & Options: Legacy bind flags map to properties inside an options table passed as parameter 3:
  - `binde` -> `{ repeating = true }`
  - `bindm` -> `{ mouse = true }`
  - `bindl` -> `{ locked = true }`
  - `bindr` -> `{ release = true }`
  - `bindd` / `bindde` etc. -> Exclude description from the `hl.bind()` function parameters and append it as a trailing Lua comment: `-- Description`
- Window Rules: Legacy rules MUST be translated using `hl.window_rule()` and `hl.workspace_rule()`. They must NEVER be placed inside `hl.config()`.
  - TARGET MATCHING: Legacy targets MUST be parsed into distinct key-value pairs inside the `match` table: `match = { class = "kitty", title = "video" }`. Never emit `match = { match = "..." }`.
  - Supported Match Keys: `class`, `title`, `initial_class`, `initial_title`, `tag`, `xwayland`, `float`, `fullscreen`, `pin`, `focus`, `group`, `modal`, `workspace`.
- Layer Rules: Legacy `layerrule` translates to the standalone `hl.layer_rule()` function. Do NOT place inside `hl.config()`. Parse the target into a match table: `match = { namespace = "rofi" }`.
- TABLE VALUE QUOTING (CRITICAL): Any value assigned to a key inside a Lua table MUST be wrapped in double quotes, UNLESS it is a pure numeric digit, a sub-table object, or a boolean.
- Inline Colon Categories: Legacy syntax like `decoration:screen_shader = path` MUST be translated into nested Lua tables: `decoration = { screen_shader = "path" }`.
- File Sourcing & Require: Legacy `source = path.conf` must become `require("path")`. Strip absolute path prefixes (`$HOME/.config/hypr/`, etc.) to leave only relative module paths.
- Startup Commands: Collect all legacy `exec-once` configurations and emit them inside a single `hl.on("hyprland.start", function() ... end)` event listener block at the bottom of `hyprland.lua`.
- Reload Commands: Collect legacy `exec` rules and emit them at the bottom as standalone `hl.exec_cmd("...")` lines.
- Environment Variables: Emit as standalone `hl.env("KEY", "VALUE")` lines outside `hl.config()`.
- Monitor Configuration: Emit as a standalone table function: `hl.monitor({ output = "NAME", mode = "RES", position = "POS", scale = SCALE })`.
  - CRITICAL: If the legacy name is empty (e.g., `monitor=,preferred...`), map `output = ""`. Do not shift the parameters into wrong keys.
- Device Configurations: Legacy `device { name = ... }` translates to `hl.device({ name = "...", ... })`.
- Plugins: Legacy `plugin { ... }` blocks have no verified Lua mapping. Emit a `-- FIXME: API documentation missing for: plugin` comment.
- Gradients: A string with multiple colors (e.g., `rgba(1) rgba(2) 45deg`) must be translated to the `{ colors = { "rgba(1)", "rgba(2)" }, angle = 45 }` format.
- Shell Environment Paths: If any string path value begins with `$HOME/` or `~/`, strip the prefix and use string concatenation with the environment call: `os.getenv("HOME") .. "/.config/..."`.

- Verified Namespaced Dispatcher Mapping (CRITICAL): Legacy flat dispatcher names MUST be translated to their 0.55 namespaced forms. Parameters must be passed as key-value pairs inside tables.
  - `movefocus, DIRECTION` / `workspace, WORKSPACE` -> `hl.dsp.focus({ direction = "DIRECTION" })` or `hl.dsp.focus({ workspace = "WORKSPACE" })`
  - `movewindow, DIRECTION` -> `hl.dsp.window.move({ direction = "DIRECTION" })`
  - `movetoworkspace, WORKSPACE` -> `hl.dsp.window.move({ workspace = "WORKSPACE" })`
  - `resizeactive, X Y` -> Split by space, cast to integers, and map: `hl.dsp.window.resize({ x = X, y = Y, relative = true })`
  - `killactive` -> `hl.dsp.window.close()`
  - `togglefloating` -> `hl.dsp.window.float({ action = "toggle" })`
  - `fullscreen` -> `hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })`
  - `togglespecialworkspace` -> `hl.dsp.workspace.toggle_special()`
  - `movewindow` / `resizewindow` (When used with `bindm` mouse interactions) -> `hl.dsp.window.drag()`
