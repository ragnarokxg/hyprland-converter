---
trigger: always_on
---

# TESTING & VALIDATION RULES

- Modular Testing Isolation: The test suite MUST NOT be bundled inside the primary execution compiler. It must reside strictly in an independent file named `test_suite.lua`.
- Test Suite Mechanics:
  - The `test_suite.lua` file will import modules from the main codebase or ingest sample `.conf` streams to validate parsing integrity.
  - It must execute standalone syntax confirmation by passing generated strings through `loadstring()` or `load()`.
- Edge Cases to Cover: The suite must strictly maintain assertions for:
  1. Inline comments attached to configuration lines.
  2. Deeply nested dictionary tables (e.g., `device`, `input`).
  3. Universal uppercase key structural transformations (ensuring single characters and named descriptors are forced to uppercase).
  4. Path transformations expanding `$HOME` or `~` safely using `os.getenv("HOME")`.
  5. Repeating bind option structures returning proper functional blocks.
