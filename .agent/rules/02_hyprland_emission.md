---
trigger: always_on
---

# HYPRLAND LUA EMISSION STANDARDS

- API Target: Hyprland 0.55 Lua configuration API.
- Root Structure: Standard variables, categories, and primitive window/input properties belong nested within an `hl.config({ ... })` table call.
- Functional Isolation (CRITICAL): Standing rule definitions, monitor declarations, layer rules, and keybindings MUST NOT be placed inside the `hl.config()` table block. They must be emitted as top-level standalone functional calls (e.g., `hl.window_rule()`, `hl.layer_rule()`, `hl.monitor()`, `hl.bind()`) to comply with the 0.55 syntax runtime.
- Variable Translation: Legacy variables (e.g., `$MOD = SUPER`) must be emitted as `local` Lua strings at the very top of the generated file, OUTSIDE the `hl.config` table. Convert variable names with hyphens to underscores (e.g., `$MY-VAR` becomes `local MY_VAR`).
- Type Coercion: Do not emit booleans or numbers as strings if they can be inferred.
  - `true`, `yes`, `on` -> true (boolean)
  - `false`, `no`, `off` -> false (boolean)
  - Pure numbers -> numeric types (no quotes).
- Array Handling: Legacy configurations often repeat keys (e.g., multiple `bind = ...` lines). The emitter MUST group repeated keys into individual standalone functional function calls rather than packing them as an un-executable array inside a flat configuration object.
- String Escaping: Any emitted string values must have internal quotes properly escaped to prevent Lua syntax errors.
