---
description: File system safety and execution guardrails
---

# SAFETY & EXECUTION GUARDRAILS

- Non-Destructive Parsing: The converter MUST ONLY read from existing `.conf` files. It is strictly forbidden from deleting, overwriting, or modifying any `.conf` files.
- Output Generation: The emitted Lua code must be saved to a completely separate file (e.g., `hyprland.generated.lua`).
- Strict Mode: Always pause and request user confirmation before running the test suite if it interacts directly with the live Hyprland socket.
