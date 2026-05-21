---
description: Performance guidelines for the LPeg grammar
---

# LPEG PERFORMANCE & OPTIMIZATION

- Whitespace Handling: Do not recursively match whitespace at the end of every token. Handle whitespace uniformly at the ends of logical blocks to prevent backtracking stack overflow.
- Table Accumulation: When parsing repeated elements (like arrays of binds or workspace rules), use function-based object construction (accumulator captures like `lpeg.Cg` and `lpeg.Cf`) to incrementally build tables rather than capturing massive strings and parsing them later.
- Stack Limits: Explicitly set a generous backtrack limit for the parser to accommodate deeply nested categories.
