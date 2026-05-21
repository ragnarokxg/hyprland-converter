---
description: Mandatory research, hallucination-prevention protocols, and whitelisted URLs.
---

# RESEARCH AND GROUNDING PROTOCOL

- Zero-Shot Prohibition: You are strictly forbidden from guessing or hallucinating Hyprland or Lua API functions. If you are translating a legacy directive that is not explicitly covered in `04_api_translation.md`, you MUST verify it first.
- Targeted Verification (Whitelisted Domains): Before implementing an unknown API call, you must use your browser tool to search and read the official documentation ONLY from these approved sources:
  1. For Hyprland 0.55+ API: Start your search strictly at `https://deepwiki.com/hyprwm/hyprland-wiki/3-configuration-system` and navigate through its specific sub-menus.
  2. For Lua/LuaJIT Syntax: Start your search strictly at `https://www.lua.org/docs.html` (prioritizing Lua 5.1 reference materials).
- The Verification Loop:
  1. Search the target concept using ONLY the whitelisted URLs.
  2. Read the page content.
  3. If the documentation confirms the API function, implement it.
  4. If the documentation is missing, DO NOT guess. Comment the line out with `-- FIXME: API documentation missing for: [Concept]` and alert the user.
- Context Preservation: Do not execute deep, untargeted web searches (e.g., Reddit, generic Google searches, or outdated GitHub repositories). Restrict your research to the whitelisted domains to prevent context poisoning.
