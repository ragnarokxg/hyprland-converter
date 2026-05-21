# CORE ARCHITECTURE RULES

- Language: Strict Lua 5.1 / LuaJIT (to ensure maximum compatibility without external dependencies).
- Parsing Engine: You MUST use the `lpeg` library for all parsing operations. Do not use standard string.match or regular expressions for syntax parsing.
- Paradigm: The script must act as a recursive two-pass transpiler.
  1. Pass 1: Parse the legacy `.conf` into an Abstract Syntax Tree (AST) using LPeg.
  2. Pass 2: Traverse the AST and emit formatted Lua tables.
- Monolithic Design: The entire application (CLI, Parser, Emitter, and FileSystem handlers) MUST be encapsulated within a single executable file. Use `local` module tables to separate logic internally.
- Scoping: All Lua variables must be declared as `local`. Zero global state pollution is permitted.
- Error Handling: The parser must fail gracefully. If an unrecognized block occurs, log a warning as a Lua comment in the emitted output rather than crashing.
