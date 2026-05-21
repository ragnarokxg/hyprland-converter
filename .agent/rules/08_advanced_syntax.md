---
trigger: always_on
description: Advanced Lua structural translations for stateful legacy configs
---

---

## description: Advanced Lua structural translations for stateful legacy configs

# ADVANCED SYNTAX & STATE MANAGEMENT

- Submaps (Mode Switching): Legacy config uses `submap = NAME` to start a block and `submap = reset` to end it.
  - The Emitter MUST translate this into a Lua closure block.
  - Target: Wrap all binds defined between the initial statement and the reset keyword inside: `hl.define_submap("NAME", function() ... end)`
- Colors: Any legacy value containing `rgba(...)`, `rgb(...)`, or `0x...` hex codes MUST be strictly wrapped in double quotes to prevent Lua from attempting to call undefined functions.
  - Target: `col.active_border = "rgba(33ccffee) rgba(00ff99ee) 45deg"`
- Animations & Beziers: Legacy `bezier = NAME, X, Y, A, B` must be converted to the unified `hl.curve("NAME", { type = "bezier", points = { {X, Y}, {A, B} } })` layout. Legacy animations must map to standalone `hl.animation({ leaf = "...", enabled = true, speed = N, bezier = "...", style = "..." })` functional calls.
- Global Variable Exporting: If a file consists primarily of legacy variable assignments (`$VAR = val`), the Emitter MUST format the generated `.lua` file to return those variables in a table at the bottom of the file (e.g., `return { VAR = val }`), so other files can `require()` them properly.
