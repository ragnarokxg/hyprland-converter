---
description: Auto-correction and self-healing loop for Lua syntax errors.
---

# SELF-HEALING EMISSION LOOP

- Compilation Testing: Before writing any generated Lua string to the file system, the Emitter MUST test it using `loadstring(generated_string)`.
- Error Parsing: If `loadstring` returns `nil`, capture the error string. Use `string.match` to extract the line number from the error message (e.g., matching against `:(%d+):`).
- Auto-Correction: Split the generated Lua string by newlines. Locate the exact index matching the failed line number. Prefix that specific line with `-- FIXME: Auto-corrected syntax error -> `.
- Recursive Healing: Re-join the string and pass it back into `loadstring()`. The Emitter must loop this process (up to a safe maximum of 15 iterations) until `loadstring()` returns a valid function chunk.
- Warning Output: If a self-healing event occurs, print a warning to the CLI alerting the user that a line was commented out and requires manual review.
