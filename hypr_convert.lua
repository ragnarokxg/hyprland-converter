#!/usr/bin/env lua

-- =========================================================
-- HYPRLAND 0.55 LUA RECURSIVE MIGRATION TOOL
-- =========================================================

local lpeg = require("lpeg")
local P, V, C, Ct, S, R, Cc = lpeg.P, lpeg.V, lpeg.C, lpeg.Ct, lpeg.S, lpeg.R, lpeg.Cc

-- =========================================================
-- PARSER MODULE
-- =========================================================
local Parser = {}

local ws = S(" \t")^0
local nl = P("\r")^-1 * P("\n")
local inline_comment = P("#") * ws * C((1 - nl)^0)
local line_end = ws * (inline_comment + Cc(false)) * (nl + P(-1))
local function make_blank() return { type = "blank" } end
local empty_line = ws * nl / make_blank
local ident = (R("az", "AZ", "09") + S("_-"))^1
local prop_ident = (R("az", "AZ", "09") + S("_-.:"))^1

local var_name = P("$") * C(ident)
local prop_key = C(prop_ident)

local function make_var(name, val, comment) return { type = "variable", name = name, value = val, comment = comment } end
local function make_prop(key, val, comment) return { type = "property", key = key, value = val, comment = comment } end
local function make_cat(name, open_comment, children, close_comment) return { type = "category", name = name, children = children, comment = open_comment, close_comment = close_comment } end
local function make_unknown(text) return { type = "unknown", text = text } end
local function make_standalone_comment(text) return { type = "comment", text = text } end
local function make_submap(name, children) return { type = "submap", name = name, children = children } end
local function make_math(expr) return { type = "math", expr = expr } end
local function make_text(text) return { type = "text", text = text:gsub("%s+$", "") } end
local function resolve_path(filepath)
    local home = os.getenv("HOME") or ""
    local resolved = filepath:gsub("^~", home)
    resolved = resolved:gsub("%$HOME", home)
    return resolved
end

local function make_source(path, comment) 
    local clean_path = path:gsub("%s+$", "")
    return { type = "source", path = resolve_path(clean_path), comment = comment } 
end

local function make_bind(key, val_nodes, comment)
    local val_str = ""
    for _, node in ipairs(val_nodes) do
        if node.type == "text" then val_str = val_str .. node.text
        elseif node.type == "math" then val_str = val_str .. "{{" .. node.expr .. "}}" end
    end
    
    local flags = key:sub(5)
    local has_d = flags:match("d") ~= nil
    local parts = {}
    local current_pos = 1
    local n = has_d and 5 or 4
    for i = 1, n - 1 do
        local comma_pos = val_str:find(",", current_pos)
        if not comma_pos then break end
        local part = val_str:sub(current_pos, comma_pos - 1)
        table.insert(parts, part:match("^%s*(.-)%s*$") or "")
        current_pos = comma_pos + 1
    end
    local remainder = val_str:sub(current_pos):match("^%s*(.-)%s*$") or ""
    table.insert(parts, remainder)
    
    return { type = "bind", key = key, args = parts, comment = comment, raw_val = val_str }
end

if lpeg.setmaxstack then lpeg.setmaxstack(50000) end

local bind_keyword = C(P("bind") * R("az")^0)

local grammar = P {
    "Config",
    Config = Ct((V("Statement") + empty_line)^0) * ws * (inline_comment + Cc(false)) * P(-1),
    Statement = V("StandaloneComment") + V("Source") + V("Variable") + V("Category") + V("Bind") + V("Property") + V("Unknown"),
    StandaloneComment = ws * P("#") * ws * C((1 - nl)^0) * (nl + P(-1)) / make_standalone_comment,
    Source = ws * P("source") * ws * P("=") * ws * C((1 - S("\r\n#"))^1) * line_end / make_source,
    Variable = ws * var_name * ws * P("=") * ws * V("Value") * line_end / make_var,
    Bind = ws * bind_keyword * ws * P("=") * ws * V("Value") * line_end / make_bind,
    Property = ws * prop_key * ws * P("=") * ws * V("Value") * line_end / make_prop,
    Category = ws * C(ident) * ws * P("{") * line_end * Ct((V("Statement") + empty_line)^0) * ws * P("}") * line_end / make_cat,
    Unknown = ws * -P("}") * -P("#") * C((1 - nl)^1) * (nl + P(-1)) / make_unknown,
    Value = Ct((V("MathNode") + V("TextNode"))^1),
    MathNode = P("{{") * C((1 - P("}}"))^0) * P("}}") / make_math,
    TextNode = C((1 - S("\r\n#") - P("{{"))^1) / make_text,
}

function Parser.parse(input)
    local raw = grammar:match(input)
    if not raw then error("Parser failed to match input entirely. Syntax error.") end

    -- Post-processing pass: collapse submap = NAME ... submap = reset into submap nodes
    local ast = {}
    local i = 1
    while i <= #raw do
        local node = raw[i]
        if node.type == "property" and node.key == "submap" then
            local val_str = ""
            if node.value then
                for _, vn in ipairs(node.value) do
                    if vn.type == "text" then val_str = val_str .. vn.text end
                end
            end
            val_str = val_str:match("^%s*(.-)%s*$") or ""
            if val_str:lower() ~= "reset" then
                -- Start collecting children until submap = reset
                local children = {}
                i = i + 1
                while i <= #raw do
                    local child = raw[i]
                    local is_reset = false
                    if child.type == "property" and child.key == "submap" then
                        local cv = ""
                        if child.value then
                            for _, vn in ipairs(child.value) do
                                if vn.type == "text" then cv = cv .. vn.text end
                            end
                        end
                        if (cv:match("^%s*(.-)%s*$") or ""):lower() == "reset" then
                            is_reset = true
                        end
                    end
                    if is_reset then break end
                    table.insert(children, child)
                    i = i + 1
                end
                table.insert(ast, make_submap(val_str, children))
            end
            -- skip the reset node (i will be incremented below)
        else
            table.insert(ast, node)
        end
        i = i + 1
    end
    return ast
end

-- =========================================================
-- EMITTER MODULE
-- =========================================================
local Emitter = {}

local function escape_str(s)
    s = s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n")
    return '"' .. s .. '"'
end

local function coerce_type(val)
    -- Per 08_advanced_syntax.md: colors and hex values MUST be quoted strings
    if val:match("rgba%(") or val:match("rgb%(") or val:match("^0x") or val:match("^0X") then
        if val:match("%s") then
            local colors = {}
            local angle = nil
            for token in val:gmatch("%S+") do
                if token:match("deg$") then
                    angle = token:match("^(%-?%d+)deg$")
                else
                    table.insert(colors, escape_str(token))
                end
            end
            if #colors > 1 then
                local angle_str = angle and (", angle = " .. angle) or ""
                return "{ colors = { " .. table.concat(colors, ", ") .. " }" .. angle_str .. " }"
            end
        end
        return escape_str(val)
    end
    local lower = val:lower()
    if lower == "true" or lower == "yes" or lower == "on" then return "true" end
    if lower == "false" or lower == "no" or lower == "off" then return "false" end
    if tonumber(val) then return val end
    if val:match("^%$HOME/") then
        return 'os.getenv("HOME") .. ' .. escape_str(val:sub(6))
    elseif val:match("^~/") then
        return 'os.getenv("HOME") .. ' .. escape_str(val:sub(2))
    end
    return escape_str(val)
end

local function format_key(key)
    key = key:match("^%s*(.-)%s*$")
    -- Plain identifiers pass through as-is
    if key:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
        return key
    end
    -- Dot-notation like "gestures.gesture" is NOT a valid Lua key;
    -- return it bracket-quoted so the self-healer can flag it.
    -- (Proper nesting is handled in emit_node_to_config for category children.)
    return string.format("[%s]", escape_str(key))
end

local function stringify_value(val_nodes)
    local parts = {}
    for _, node in ipairs(val_nodes) do
        if node.type == "text" then table.insert(parts, node.text)
        elseif node.type == "math" then table.insert(parts, "{{" .. node.expr .. "}}") end
    end
    return table.concat(parts, "")
end

local function split_by_comma(str)
    -- Must preserve empty fields (e.g. ",preferred,auto,1" -> {"","preferred","auto","1"})
    local t = {}
    local s = str .. ","
    for field in s:gmatch("(.-),") do
        table.insert(t, field:match("^%s*(.-)%s*$"))
    end
    if #t == 0 then return { str } end
    return t
end

-- Map bind flag letters to the corresponding hl.bind() options table.
-- Returns a Lua options-table literal string, or nil if no flags present.
local BIND_FLAG_MAP = {
    l = "locked",
    r = "release",
    c = "click",
    g = "drag",
    o = "long_press",
    e = "repeating",
    n = "non_consuming",
    m = "mouse",
    t = "transparent",
    i = "ignore_mods",
    s = "separate",
    p = "bypass",
    u = "submap_universal",
}

-- Lua 5.x reserved words that cannot appear as bare table keys.
local LUA_RESERVED = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
    ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

local function flags_to_options(flags_str)
    -- flags_str is everything after "bind" in the keyword, minus any 'd'
    local clean = flags_str:gsub("d", "")
    if clean == "" then return nil end
    local opts = {}
    for ch in clean:gmatch(".") do
        local opt_name = BIND_FLAG_MAP[ch]
        if opt_name then
            -- Reserved keywords must be bracket-quoted as table keys
            local key_str = LUA_RESERVED[opt_name]
                and string.format('["'.. opt_name ..'"]')
                or opt_name
            table.insert(opts, key_str .. " = true")
        end
    end
    if #opts == 0 then return nil end
    return "{ " .. table.concat(opts, ", ") .. " }"
end

-- Parse a legacy windowrule / windowrulev2 match string into a Lua match table.
-- Input examples:
--   "class:kitty"                       -> { class = "kitty" }
--   "class:firefox,title:^(Firefox)$"   -> { class = "firefox", title = "^(Firefox)$" }
--   "floating"                          -> { class = "floating" }  (fallback)
local function parse_legacy_match_string(str)
    local str_trimmed = str:match("^%s*(.-)%s*$")
    local pairs_list = split_by_comma(str_trimmed)
    local kv_parts = {}
    local bool_parts = {}
    for _, segment in ipairs(pairs_list) do
        local seg = segment:match("^%s*(.-)%s*$")
        -- New-style: "match:class ^(kitty)$" form emitted by Hyprland 0.45+
        if seg:match("^match:") then
            local rest = seg:sub(7)  -- strip "match:"
            local subkey, regex = rest:match("^(%S+)%s+(.-)%s*$")
            if subkey and regex then
                table.insert(kv_parts, format_key(subkey) .. " = " .. escape_str(regex))
            else
                table.insert(kv_parts, format_key(rest) .. " = true")
            end
        else
            local k, v = seg:match("^([^:]+):(.*)$")
            if k and v then
                local key_clean = k:match("^%s*(.-)%s*$")
                local val_clean = v:match("^%s*(.-)%s*$")
                table.insert(kv_parts, format_key(key_clean) .. " = " .. escape_str(val_clean))
            elseif seg ~= "" then
                table.insert(bool_parts, format_key(seg) .. " = true")
            end
        end
    end
    local match_str = ""
    if #kv_parts > 0 then
        match_str = "match = { " .. table.concat(kv_parts, ", ") .. " }"
    else
        match_str = "match = { class = " .. escape_str(str_trimmed) .. " }"
    end
    return match_str, bool_parts
end

local function format_comment(comment)
    return (comment and comment ~= false and comment ~= "") and (" -- " .. comment) or ""
end

-- Shell environment variables that must be translated to os.getenv() rather
-- than emitted as bare Lua locals (which would be nil and crash at runtime).
local SHELL_ENV_VARS = { HOME = true, USER = true, XDG_CONFIG_HOME = true }

local function format_var_ref(var_name)
    -- If the variable name is a known shell env var, emit os.getenv()
    if SHELL_ENV_VARS[var_name] then
        return string.format('os.getenv("%s")', var_name)
    end
    -- Otherwise it is a Lua local defined earlier in the file
    return var_name
end

local function format_dispatcher_arg(arg_str)
    if not arg_str or arg_str == "" then
        return "\"\""
    end

    -- Whole token is a single variable reference
    if arg_str:match("^%$[%w_]+$") then
        return format_var_ref(arg_str:sub(2))
    end

    -- No variable references at all
    if not arg_str:match("%$[%w_]+") then
        return coerce_type(arg_str)
    end

    -- Mixed string with one or more variable interpolations
    local parts = {}
    local current_pos = 1
    while current_pos <= #arg_str do
        local var_start, var_end = arg_str:find("%$[%w_]+", current_pos)
        if var_start then
            if var_start > current_pos then
                local text = arg_str:sub(current_pos, var_start - 1)
                table.insert(parts, escape_str(text))
            end
            local vname = arg_str:sub(var_start + 1, var_end)
            table.insert(parts, format_var_ref(vname))
            current_pos = var_end + 1
        else
            local text = arg_str:sub(current_pos)
            table.insert(parts, escape_str(text))
            break
        end
    end
    return table.concat(parts, " .. ")
end

-- Sanitize the KEY parameter per xkbcommon case rules:
--   * Single alphabetic character (A-Z) → lowercase
--   * Fully uppercase word (e.g. SLASH, SPACE, PRINT) → lowercase
--   * Mixed/CamelCase (Return, XF86AudioMute, Caps_Lock, mouse:272, code:60) → preserved
local function sanitize_key(key)
    if not key or key == "" then return key end
    if key:match("^mouse:") or key:match("^code:") then return key end
    if key:match("^XF86") or key:match("_") then
        return key
    end
    if key:match("^%w+$") then
        return key:upper()
    end
    return key
end



local function format_bind_args(mod_val, key_val)
    local tokens = {}
    if mod_val and mod_val ~= "" then
        for p in string.gmatch(mod_val, "([^%+%s]+)") do
            local trimmed = p:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                local upper = trimmed:upper()
                if upper == "CTRL" or upper == "SHIFT" or upper == "ALT" or upper == "SUPER" then
                    table.insert(tokens, upper)
                else
                    table.insert(tokens, trimmed)
                end
            end
        end
    end

    local sanitized_key = sanitize_key(key_val)
    if sanitized_key and sanitized_key ~= "" then
        table.insert(tokens, sanitized_key)
    end
    
    if #tokens == 0 then return "\"\"" end
    
    local exprs = {}
    local current_str = {}
    
    for _, t in ipairs(tokens) do
        if t:match("^%$[%w_]+$") then
            if #current_str > 0 then
                table.insert(exprs, '"' .. table.concat(current_str, " + ") .. ' + "')
                current_str = {}
            elseif #exprs > 0 then
                table.insert(exprs, '" + "')
            end
            table.insert(exprs, t:sub(2))
        else
            table.insert(current_str, t)
        end
    end
    
    if #current_str > 0 then
        if #exprs > 0 then
            table.insert(exprs, '" + ' .. table.concat(current_str, " + ") .. '"')
        else
            table.insert(exprs, '"' .. table.concat(current_str, " + ") .. '"')
        end
    end
    
    return table.concat(exprs, " .. ")
end

function Emitter.emit(ast)
    local out = {}
    local exec_once_cmds = {}
    local exec_cmds = {}
    local animation_cmds = {}
    local gesture_props = {}
    local rule_counter = 1

    -- Verified dispatcher translation map (source: 3.7-dispatchers + 04_api_translation.md).
    -- Maps legacy hyprlang dispatcher names to their 0.55 hl.dsp.* call strings.
    -- Unverified dispatchers resolve to nil and emit a -- FIXME comment.
    local DISPATCHER_MAP = {
        -- General (hl.dsp.*)
        exec_cmd              = "hl.dsp.exec_cmd",
        exec_raw              = "hl.dsp.exec_raw",
        submap                = "hl.dsp.submap",
        exit                  = "hl.dsp.exit",
        dpms                  = "hl.dsp.dpms",
        force_idle            = "hl.dsp.force_idle",
        -- Window state (no-arg dispatchers)
        close                 = "hl.dsp.window.close",
        killactive            = "hl.dsp.window.close",        -- legacy alias
        kill                  = "hl.dsp.window.kill",
        forcekillactive       = "hl.dsp.window.kill",
        togglefloating        = "hl.dsp.window.float",  -- 0.55 namespaced
        float                 = "hl.dsp.window.float",  -- alias
        fullscreen            = "hl.dsp.window.fullscreen", -- 0.55 namespaced
        fakefullscreen        = "hl.dsp.window.fullscreen", -- legacy alias
        swap                  = "hl.dsp.window.swap",
        swapwindow            = "hl.dsp.window.swap",             -- legacy alias
        pin                   = "hl.dsp.window.pin",
        set_prop              = "hl.dsp.window.set_prop",
        -- Window focus/navigation: hl.dsp.focus({ direction = "..." })
        focus                 = "hl.dsp.focus",
        movefocus             = "hl.dsp.focus",            -- legacy alias
        -- Window move with direction: hl.dsp.window.move({ direction = "..." })
        movewindow            = "hl.dsp.window.move",
        move                  = "hl.dsp.window.move",
        -- Window resize: hl.dsp.window.resize({ x = X, y = Y, relative = true })
        resizeactive          = "hl.dsp.window.resize",
        resizewindow          = "hl.dsp.window.resize",
        -- Move window to workspace: hl.dsp.window.move({ workspace = "..." })
        movetoworkspace       = "hl.dsp.window.move",
        movetoworkspacesilent = "hl.dsp.window.move", -- silent variant
        -- Workspace switch: hl.dsp.focus({ workspace = "..." })
        workspace             = "hl.dsp.focus",
        -- Special workspace
        togglespecialworkspace= "hl.dsp.workspace.toggle_special",
        -- Group (hl.dsp.group.*)
        togglegroup           = "hl.dsp.group.toggle",
        moveintogroup         = "hl.dsp.group.move",
        moveoutofgroup        = "hl.dsp.group.move",
        groupnext             = "hl.dsp.group.next",
        groupprev             = "hl.dsp.group.prev",
        lockgroups            = "hl.dsp.group.lock",
        -- Cursor (hl.dsp.cursor.*)
        cursor_move           = "hl.dsp.cursor.move",
        cursor_move_to_corner = "hl.dsp.cursor.move_to_corner",
    }

    -- Dispatchers whose arguments MUST be wrapped in a named Lua table.
    -- Each entry is a function(prefix, raw_arg_str, is_mouse_bind) -> lua_call_string.
    -- Per spec (04_api_translation.md §39-48): ALL inner table values MUST be quoted strings.
    local function make_direction_call(prefix, arg, is_mouse)
        if arg == "" then return prefix .. "()" end
        return string.format("%s({ direction = %s })", prefix, escape_str(arg))
    end
    local function make_workspace_switch_call(prefix, arg)
        if arg == "" then return prefix .. "()" end
        return string.format("%s({ workspace = %s })", prefix, escape_str(arg))
    end
    local function make_workspace_move_call(prefix, arg, silent)
        if arg == "" then return prefix .. "()" end
        if silent then
            return string.format("%s({ workspace = %s, silent = true })", prefix, escape_str(arg))
        end
        return string.format("%s({ workspace = %s })", prefix, escape_str(arg))
    end
    local function make_resize_call(prefix, arg)
        if arg == "" then return prefix .. "()" end
        local x, y = arg:match("^(%S+)%s+(%S+)$")
        if x and y then
            return string.format("%s({ x = %s, y = %s, relative = true })", prefix, tonumber(x) or x, tonumber(y) or y)
        end
        return string.format("%s({ delta = %s })", prefix, escape_str(arg))
    end
    local function make_movewindow_call(prefix, arg, is_mouse)
        if is_mouse then return "hl.dsp.window.drag()" end
        return make_direction_call(prefix, arg, is_mouse)
    end
    local function make_resizewindow_call(prefix, arg, is_mouse)
        if is_mouse then return "hl.dsp.window.drag()" end
        return make_resize_call(prefix, arg)
    end
    local function make_toggle_floating(prefix, arg)
        return prefix .. '({ action = "toggle" })'
    end
    local function make_toggle_fullscreen(prefix, arg)
        return prefix .. '({ mode = "fullscreen", action = "toggle" })'
    end

    local DSP_ARG_FORMATTER = {
        focus                 = make_direction_call,
        movefocus             = make_direction_call,
        movewindow            = make_movewindow_call,
        move                  = make_movewindow_call,
        workspace             = make_workspace_switch_call,
        movetoworkspace       = make_workspace_move_call,
        movetoworkspacesilent = function(prefix, arg) return make_workspace_move_call(prefix, arg, true) end,
        resizeactive          = make_resize_call,
        resizewindow          = make_resizewindow_call,
        togglefloating        = make_toggle_floating,
        float                 = make_toggle_floating,
        fullscreen            = make_toggle_fullscreen,
        fakefullscreen        = make_toggle_fullscreen,
    }



    -- Emit a property key that may contain dots (e.g. "col.active_border").
    -- Dot-notation is split into nested table access so the output is always
    -- valid Lua:  col.active_border  =>  col = { active_border = ... }
    -- We group consecutive sibling properties that share the same first
    -- segment so the table is opened/closed exactly once per segment group.
    local function emit_dotkey_property(node, indent)
        local ind = string.rep("    ", indent)
        local key = node.key:match("^%s*(.-)%s*$")
        local val_str = stringify_value(node.value)
        -- Split on the FIRST dot or colon only; deeper nesting is unusual and handled
        -- by the inner emit call.
        local prefix, suffix = key:match("^([^.:]+)[.:](.+)$")
        if prefix and suffix then
            -- e.g. col.active_border -> col = { active_border = <val> },
            table.insert(out, ind .. format_key(prefix) .. " = { " ..
                format_key(suffix) .. " = " .. coerce_type(val_str) ..
                " }," .. format_comment(node.comment))
        else
            table.insert(out, ind .. format_key(key) .. " = " ..
                coerce_type(val_str) .. "," .. format_comment(node.comment))
        end
    end

    local function emit_node_to_config(node, indent, parent_name)
        local ind = string.rep("    ", indent)
        if node.type == "blank" then
            table.insert(out, "")
        elseif node.type == "unknown" then
            table.insert(out, ind .. "-- FIXME: Unrecognized line: " .. node.text)
        elseif node.type == "comment" then
            table.insert(out, ind .. "-- " .. node.text)
        elseif node.type == "property" then
            if node.key == "bezier" or node.key == "animation" then
                table.insert(animation_cmds, { key = node.key, val_str = stringify_value(node.value), comment = node.comment })
            elseif parent_name == "gestures" and (node.key == "workspace_swipe" or node.key == "workspace_swipe_fingers" or node.key == "workspace_swipe_min_fingers") then
                gesture_props[node.key] = { val_str = stringify_value(node.value), comment = node.comment }
            -- Bug A: gestures.gesture is not a valid 0.55 hl.config() key
            elseif parent_name == "gestures" and node.key == "gesture" then
                local ind = string.rep("    ", indent)
                table.insert(out, ind .. "-- FIXME: 'gestures.gesture' is not a valid Hyprland 0.55 config key. Original: gesture = " .. stringify_value(node.value))
            else
                emit_dotkey_property(node, indent)
            end
        elseif node.type == "category" then
            -- Sanitize duplicate/dot-notation category keys.
            -- If the raw name is "gestures.gesture" inside a "gestures" block,
            -- strip the leading "<parent>." prefix so the key becomes "gesture".
            local cat_key = node.name:match("^%s*(.-)%s*$")
            if parent_name and cat_key:sub(1, #parent_name + 1) == parent_name .. "." then
                cat_key = cat_key:sub(#parent_name + 2)
            end
            -- Also strip any remaining dot-notation entirely (keep only last segment)
            -- to avoid emitting bracket-quoted keys like ["gestures.gesture"]
            local last_seg = cat_key:match("([^.]+)$") or cat_key
            if last_seg ~= cat_key then
                cat_key = last_seg
            end
            table.insert(out, ind .. format_key(cat_key) .. " = {" ..
                (node.comment and node.comment ~= false and (" -- " .. node.comment) or ""))
            for _, child in ipairs(node.children) do emit_node_to_config(child, indent + 1, cat_key) end
            table.insert(out, ind .. "}," ..
                (node.close_comment and node.close_comment ~= false and (" -- " .. node.close_comment) or ""))
        end
    end

    local function emit_device(node)
        local lines = {}
        table.insert(lines, "hl.device({" .. (node.comment and node.comment ~= false and (" -- " .. node.comment) or ""))
        for _, child in ipairs(node.children) do
            if child.type == "blank" then
                table.insert(lines, "")
            elseif child.type == "property" then
                if child.key == "force_no_accel" or child.key == "follow_mouse" or child.key == "mouse_refocus" or child.key == "float_switch_override_focus" then
                    table.insert(lines, "    -- FIXME: Unsupported global setting in hl.device(): " .. child.key .. " = " .. stringify_value(child.value))
                else
                    table.insert(lines, "    " .. child.key .. " = " .. coerce_type(stringify_value(child.value)) .. "," .. format_comment(child.comment))
                end
            elseif child.type == "comment" then
                table.insert(lines, "    -- " .. child.text)
            elseif child.type == "unknown" then
                table.insert(lines, "    -- FIXME: Unrecognized line: " .. child.text)
            end
        end
        table.insert(lines, "})" .. (node.close_comment and node.close_comment ~= false and (" -- " .. node.close_comment) or ""))
        table.insert(out, table.concat(lines, "\n"))
    end

    -- -------------------------------------------------------
    -- TWO-PHASE EMISSION: classify each AST node as either
    -- config-eligible (goes inside a single hl.config()) or
    -- standalone (emitted outside hl.config()).
    -- -------------------------------------------------------

    -- Property keys that MUST be standalone (never inside hl.config)
    local STANDALONE_PROP_KEYS = {
        ["exec-once"] = true, ["exec"] = true, ["env"] = true,
        ["windowrule"] = true, ["windowrulev2"] = true,
        ["monitor"] = true, ["workspace"] = true, ["layerrule"] = true,
        ["bezier"] = true, ["animation"] = true,
    }
    -- Category names that MUST be standalone (never inside hl.config)
    local STANDALONE_CAT_NAMES = {
        device = true, plugin = true, monitorv2 = true,
        windowrule = true, windowrulev2 = true, animations = true,
    }

    local function is_config_eligible(node)
        if node.type == "property" then
            return not STANDALONE_PROP_KEYS[node.key]
        elseif node.type == "category" then
            return not STANDALONE_CAT_NAMES[node.name]
        end
        return false
    end

    -- Collect config-eligible node indices
    local config_indices = {}
    for idx, node in ipairs(ast) do
        if is_config_eligible(node) then
            config_indices[idx] = true
        end
    end

    -- Pre-render config content into a buffer using emit_node_to_config
    local config_buf = {}
    local saved_out = out
    out = config_buf
    for idx, node in ipairs(ast) do
        if config_indices[idx] then
            emit_node_to_config(node, 1)
        end
    end
    out = saved_out

    local config_block_emitted = false
    local function emit_config_block()
        if config_block_emitted or #config_buf == 0 then return end
        config_block_emitted = true
        table.insert(out, "hl.config({")
        for _, line in ipairs(config_buf) do
            table.insert(out, line)
        end
        table.insert(out, "})")
    end

    for _, node in ipairs(ast) do
        if node.type == "blank" then
            table.insert(out, "")
        elseif node.type == "variable" then
            local name = node.name:gsub("-", "_")
            local val_str = stringify_value(node.value)

            -- Shell env-vars ($HOME etc.) referenced as the entire RHS should
            -- NOT be emitted as a modifier string – they are path/string values.
            local is_shell_env = val_str:match("^%$([%w_]+)$") and SHELL_ENV_VARS[val_str:sub(2)] ~= nil

            local is_modifier_str = false
            if not is_shell_env then
                local upper_val = val_str:upper()
                if val_str:match("%+") and not val_str:match("{{") then
                    is_modifier_str = true
                elseif upper_val == "CTRL" or upper_val == "SHIFT" or upper_val == "ALT" or upper_val == "SUPER" then
                    is_modifier_str = true
                elseif val_str:match("^%$[%w_]+$") then
                    is_modifier_str = true
                end
            end

            local emitted_val
            if is_modifier_str then
                emitted_val = format_bind_args(val_str, nil)
            else
                emitted_val = format_dispatcher_arg(val_str)
            end

            table.insert(out, string.format("local %s = %s%s", name, emitted_val, format_comment(node.comment)))
        elseif node.type == "source" then
            emit_config_block()
            --table.insert(out, "-- FIXME: Variables in required Lua files do not auto-share globally like legacy hyprlang. Ensure variables are returned or passed explicitly.")
            local req_path = node.path:gsub("%.conf$", "")
            req_path = req_path:gsub("^%$HOME/%.config/hypr/", "")
            req_path = req_path:gsub("^~/%.config/hypr/", "")
            req_path = req_path:gsub("^/home/[^/]+/%.config/hypr/", "")
            -- Catch-all: strip expanded $HOME/ prefix for files outside .config/hypr/
            req_path = req_path:gsub("^/home/[^/]+/", "")
            req_path = req_path:gsub("^/", "")
            table.insert(out, string.format("require(%s)%s", escape_str(req_path), format_comment(node.comment)))
        elseif node.type == "comment" then
            table.insert(out, "-- " .. node.text)
        elseif node.type == "unknown" then
            table.insert(out, "-- FIXME: Unrecognized line: " .. node.text)
        elseif node.type == "submap" then
            emit_config_block()
            -- Per 08_advanced_syntax.md: emit as hl.define_submap("NAME", function() ... end)
            local submap_lines = {}
            table.insert(submap_lines, string.format("hl.define_submap(%s, function()", escape_str(node.name)))
            for _, child in ipairs(node.children) do
                if child.type == "bind" then
                    local key = child.key
                    local args = child.args
                    local flags = key:sub(5)
                    local has_d = flags:match("d") ~= nil
                    local desc = ""
                    local dispatcher = ""
                    local cmd_raw = ""
                    if has_d then
                        desc = args[3] or ""
                        dispatcher = args[4] or ""
                        cmd_raw = args[5] or ""
                    else
                        dispatcher = args[3] or ""
                        cmd_raw = args[4] or ""
                    end
                    if dispatcher ~= "" then
                        local bind_str = format_bind_args(args[1], args[2])
                        local formatted_arg = format_dispatcher_arg(cmd_raw)
                        -- Normalise legacy aliases (exec -> exec_cmd)
                        local dsp_key = (dispatcher == "exec") and "exec_cmd" or dispatcher
                        local dsp_prefix = DISPATCHER_MAP[dsp_key]
                        local cmd_call = ""
                        if not dsp_prefix then
                            -- Unverified dispatcher: emit FIXME and skip bind
                            table.insert(submap_lines, string.format(
                                "    -- FIXME: dispatcher '%s' not found in Hyprland 0.55 hl.dsp API. Original bind: %s",
                                dsp_key, child.raw_val))
                            goto continue_submap_bind
                        end
                        local clean_flags_sub = flags:gsub("d", "")
                        local is_mouse_bind_sub = clean_flags_sub:match("m") ~= nil
                        local custom_fmt_sub = DSP_ARG_FORMATTER[dsp_key]
                        if custom_fmt_sub then
                            cmd_call = custom_fmt_sub(dsp_prefix, cmd_raw, is_mouse_bind_sub)
                        elseif cmd_raw == "" then
                            cmd_call = string.format("%s()", dsp_prefix)
                        else
                            cmd_call = string.format("%s(%s)", dsp_prefix, formatted_arg)
                        end
                        local final_comment = child.comment
                        if desc ~= "" then
                            if final_comment and final_comment ~= false and final_comment ~= "" then
                                final_comment = desc .. " | " .. final_comment
                            else
                                final_comment = desc
                            end
                        end
                        -- Map flag letters to hl.bind() options table; never emit hl.bindr/e/l/m
                        local clean_flags = flags:gsub("d", "")
                        local opts_table = flags_to_options(clean_flags)
                        if opts_table then
                            table.insert(submap_lines, string.format("    hl.bind(%s, %s, %s)%s", bind_str, cmd_call, opts_table, format_comment(final_comment)))
                        else
                            table.insert(submap_lines, string.format("    hl.bind(%s, %s)%s", bind_str, cmd_call, format_comment(final_comment)))
                        end
                        ::continue_submap_bind::
                    else
                        table.insert(submap_lines, "    -- FIXME: Unable to parse legacy bind: " .. child.raw_val)
                    end
                elseif child.type == "comment" then
                    table.insert(submap_lines, "    -- " .. child.text)
                elseif child.type == "blank" then
                    table.insert(submap_lines, "")
                end
            end
            table.insert(submap_lines, "end)")
            table.insert(out, table.concat(submap_lines, "\n"))
        elseif node.type == "bind" then
            emit_config_block()
            local key = node.key
            local args = node.args
            
            local flags = key:sub(5)
            local has_d = flags:match("d") ~= nil
            
            local desc = ""
            local dispatcher = ""
            local cmd_raw = ""
            
            if has_d then
                desc = args[3] or ""
                dispatcher = args[4] or ""
                cmd_raw = args[5] or ""
            else
                dispatcher = args[3] or ""
                cmd_raw = args[4] or ""
            end
            
            if dispatcher ~= "" then
                local bind_str = format_bind_args(args[1], args[2])
                local formatted_arg = format_dispatcher_arg(cmd_raw)
                -- Normalise legacy aliases (exec -> exec_cmd)
                local dsp_key = (dispatcher == "exec") and "exec_cmd" or dispatcher
                local dsp_prefix = DISPATCHER_MAP[dsp_key]

                if not dsp_prefix then
                    -- Unverified dispatcher: emit FIXME and skip bind
                    table.insert(out, string.format(
                        "-- FIXME: dispatcher '%s' not found in Hyprland 0.55 hl.dsp API. Original bind: %s",
                        dsp_key, node.raw_val))
                    goto continue_bind
                end

                local cmd_call = ""
                local clean_flags_pre = flags:gsub("d", "")
                local is_mouse_bind = clean_flags_pre:match("m") ~= nil
                local custom_fmt = DSP_ARG_FORMATTER[dsp_key]
                if custom_fmt then
                    -- Dispatcher needs a structured table arg (e.g. { direction = "r" })
                    -- Pass is_mouse_bind so direction-dispatchers can omit the table for mouse binds with no arg.
                    cmd_call = custom_fmt(dsp_prefix, cmd_raw, is_mouse_bind)
                elseif cmd_raw == "" then
                    cmd_call = string.format("%s()", dsp_prefix)
                else
                    cmd_call = string.format("%s(%s)", dsp_prefix, formatted_arg)
                end
                
                local final_comment = node.comment
                if desc ~= "" then
                    if final_comment and final_comment ~= false and final_comment ~= "" then
                        final_comment = desc .. " | " .. final_comment
                    else
                        final_comment = desc
                    end
                end
                
                -- Map flag letters to hl.bind() options table; never emit hl.bindr/e/l/m
                local clean_flags = flags:gsub("d", "")
                local opts_table = flags_to_options(clean_flags)
                if opts_table then
                    table.insert(out, string.format("hl.bind(%s, %s, %s)%s", bind_str, cmd_call, opts_table, format_comment(final_comment)))
                else
                    table.insert(out, string.format("hl.bind(%s, %s)%s", bind_str, cmd_call, format_comment(final_comment)))
                end
                ::continue_bind::
            else
                table.insert(out, "-- FIXME: Unable to parse legacy bind: " .. node.raw_val)
            end
        elseif node.type == "property" then
            local key = node.key
            local val_str = stringify_value(node.value)
            if key == "exec-once" then
                emit_config_block()
                table.insert(exec_once_cmds, { cmd = val_str, comment = node.comment })
            elseif key == "exec" then
                emit_config_block()
                table.insert(exec_cmds, { cmd = val_str, comment = node.comment })
            elseif key == "env" then
                emit_config_block()
                local parts = split_by_comma(val_str)
                if #parts >= 2 then
                    table.insert(out, string.format("hl.env(%s, %s)%s", escape_str(parts[1]), escape_str(table.concat(parts, ",", 2)), format_comment(node.comment)))
                else
                    table.insert(out, "-- FIXME: Unrecognized env format: " .. val_str)
                end
            elseif key == "windowrule" or key == "windowrulev2" then
                emit_config_block()
                local parts = split_by_comma(val_str)
                if #parts >= 2 then
                    local rule_name = string.format("rule_%d", rule_counter)
                    rule_counter = rule_counter + 1
                    -- Partition parts[2..N] into match: segments vs extra action segments
                    local match_segs, action_segs = {}, {}
                    local has_new_style_match = false
                    for i = 2, #parts do
                        local seg = parts[i]:match("^%s*(.-)%s*$")
                        if seg:match("^match:") then
                            has_new_style_match = true
                            table.insert(match_segs, seg)
                        else
                            table.insert(action_segs, seg)
                        end
                    end
                    local match_table_str
                    if has_new_style_match then
                        -- New-style: extract subkey + regex from each match: segment
                        local kv = {}
                        for _, seg in ipairs(match_segs) do
                            local rest = seg:sub(7)
                            local subkey, regex = rest:match("^(%S+)%s+(.-)%s*$")
                            if subkey and regex then
                                table.insert(kv, format_key(subkey) .. " = " .. escape_str(regex))
                            else
                                table.insert(kv, format_key(rest) .. " = true")
                            end
                        end
                        match_table_str = "match = { " .. table.concat(kv, ", ") .. " }"
                    else
                        -- Old-style: entire remainder is the match string.
                        -- Clear action_segs since parse_legacy_match_string consumes all
                        -- match segments; only extra_bool parts should survive.
                        action_segs = {}
                        local old_match_str, extra_bool = parse_legacy_match_string(table.concat(parts, ",", 2))
                        match_table_str = old_match_str
                        for _, b in ipairs(extra_bool) do table.insert(action_segs, b) end
                    end
                    -- Parse all action parts (primary + extras) into key=val entries
                    local function parse_action_field(s)
                        s = s:match("^%s*(.-)%s*$")
                        -- Already-formatted boolean from old-style bool_parts
                        if s:match(" = ") then return s end
                        local sp = s:find("%s")
                        if not sp then return format_key(s) .. " = true" end
                        local k = s:sub(1, sp - 1)
                        local v = s:sub(sp + 1):match("^%s*(.-)%s*$")
                        if v == "on" then return format_key(k) .. " = true"
                        elseif v == "off" then return format_key(k) .. " = false"
                        else return format_key(k) .. " = " .. escape_str(v) end
                    end
                    local action_entries = { parse_action_field(parts[1]) }
                    for _, a in ipairs(action_segs) do
                        table.insert(action_entries, parse_action_field(a))
                    end
                    local all_fields = { "name = " .. escape_str(rule_name), match_table_str }
                    for _, ae in ipairs(action_entries) do table.insert(all_fields, ae) end
                    table.insert(out, string.format("hl.window_rule({ %s })%s", table.concat(all_fields, ", "), format_comment(node.comment)))
                else
                    table.insert(out, "-- FIXME: Unrecognized windowrule format: " .. val_str)
                end
            elseif key == "monitor" then
                emit_config_block()
                local parts = split_by_comma(val_str)
                local m_out = parts[1] and format_dispatcher_arg(parts[1]) or "\"\""
                local m_mode = parts[2] and format_dispatcher_arg(parts[2]) or "\"\""
                local m_pos = parts[3] and format_dispatcher_arg(parts[3]) or "\"\""
                local m_scale = parts[4] and format_dispatcher_arg(parts[4]) or "1"
                table.insert(out, string.format("hl.monitor({ output = %s, mode = %s, position = %s, scale = %s })%s", m_out, m_mode, m_pos, m_scale, format_comment(node.comment)))
            elseif key == "workspace" then
                emit_config_block()
                local parts = split_by_comma(val_str)
                if #parts >= 1 then
                    local rule_name = string.format("rule_%d", rule_counter)
                    rule_counter = rule_counter + 1
                    local rule_parts = {}
                    table.insert(rule_parts, "name = " .. escape_str(rule_name))
                    table.insert(rule_parts, "workspace = " .. escape_str(parts[1]))
                    for i = 2, #parts do
                        local r_key, r_val = parts[i]:match("^([^:]+):(.*)$")
                        if r_key and r_val then table.insert(rule_parts, format_key(r_key) .. " = " .. coerce_type(r_val)) else table.insert(rule_parts, format_key(parts[i]) .. " = true") end
                    end
                    local rule_str = table.concat(rule_parts, ", ")
                    table.insert(out, string.format("hl.workspace_rule({ %s })%s", rule_str, format_comment(node.comment)))
                else
                    table.insert(out, "-- FIXME: Unable to parse legacy workspace rule: " .. val_str)
                end
            elseif key == "layerrule" then
                emit_config_block()
                -- New-style: layerrule = EFFECT [VAL], [EFFECT2 [VAL2],] match:namespace REGEX
                -- Old-style: layerrule = EFFECT [VAL], NAMESPACE_REGEX
                local lr_parts = split_by_comma(val_str)
                if #lr_parts >= 2 then
                    -- Partition: collect match:namespace parts and effect parts
                    local ns_str = nil
                    local effect_parts = {}
                    for _, lp in ipairs(lr_parts) do
                        local seg = lp:match("^%s*(.-)%s*$")
                        if seg:match("^match:namespace%s") then
                            ns_str = seg:match("^match:namespace%s+(.-)%s*$")
                        elseif seg:match("^match:") then
                            -- ignore other match: types for layer rules
                        else
                            table.insert(effect_parts, seg)
                        end
                    end
                    -- Fallback: if no match:namespace found, last non-effect part is namespace
                    if not ns_str and #effect_parts >= 2 then
                        ns_str = table.remove(effect_parts)
                    elseif not ns_str and #effect_parts == 1 then
                        -- Only one part, can't determine namespace
                        table.insert(out, "-- FIXME: Unable to parse legacy layerrule format: " .. val_str)
                        goto continue_layerrule
                    end
                    local function parse_effect(s)
                        s = s:match("^%s*(.-)%s*$")
                        local sp = s:find("%s")
                        if not sp then
                            if s == "on" or s == "true" then return nil end  -- bare "on" is not an effect name
                            return string.format("%s = true", format_key(s))
                        end
                        local ek = s:sub(1, sp - 1)
                        local ev = s:sub(sp + 1):match("^%s*(.-)%s*$")
                        if ev == "on" or ev == "true" then return string.format("%s = true", format_key(ek))
                        elseif ev == "off" or ev == "false" then return string.format("%s = false", format_key(ek))
                        else return string.format("%s = %s", format_key(ek), coerce_type(ev)) end
                    end
                    for ei, eff_str in ipairs(effect_parts) do
                        local rule_name = string.format("rule_%d", rule_counter)
                        rule_counter = rule_counter + 1
                        local eff_field = parse_effect(eff_str)
                        if eff_field then
                            table.insert(out, string.format(
                                "hl.layer_rule({ name = %s, match = { namespace = %s }, %s })%s",
                                escape_str(rule_name), escape_str(ns_str or ""), eff_field,
                                ei == #effect_parts and format_comment(node.comment) or ""
                            ))
                        end
                    end
                    ::continue_layerrule::
                else
                    table.insert(out, "-- FIXME: Unable to parse legacy layerrule format: " .. val_str)
                end
            elseif key == "bezier" or key == "animation" then
                -- Standalone: deferred to animation_cmds for emission after hl.config()
                emit_config_block()
                table.insert(animation_cmds, { key = key, val_str = val_str, comment = node.comment })
            else
                -- Config-eligible property: already pre-rendered in config_buf.
                -- Emit the config block if not yet emitted.
                emit_config_block()
            end
        elseif node.type == "category" then
            if node.name == "device" then
                emit_config_block()
                emit_device(node)
            elseif node.name == "plugin" then
                emit_config_block()
                table.insert(out, "-- FIXME: API documentation missing for: plugin")
            elseif node.name == "animations" then
                -- Per 08_advanced_syntax.md: animation category blocks emit standalone
                emit_config_block()
                for _, child in ipairs(node.children) do
                    if child.type == "property" then
                        if child.key == "bezier" or child.key == "animation" then
                            table.insert(animation_cmds, { key = child.key, val_str = stringify_value(child.value), comment = child.comment })
                        elseif child.type == "property" then
                            table.insert(out, "-- FIXME: Unrecognized animations property: " .. child.key .. " = " .. stringify_value(child.value))
                        end
                    end
                end
            elseif node.name == "monitorv2" then
                -- Bug G: monitorv2 {} block → hl.monitor()
                emit_config_block()
                local mv2 = { output="\"auto\"", mode="\"preferred\"", position="\"auto\"", scale="1" }
                for _, child in ipairs(node.children) do
                    if child.type == "property" then
                        local v = coerce_type(stringify_value(child.value))
                        if child.key == "output" then mv2.output = v
                        elseif child.key == "mode" then mv2.mode = v
                        elseif child.key == "position" then mv2.position = v
                        elseif child.key == "scale" then mv2.scale = v
                        else table.insert(out, string.format("-- FIXME: Unknown monitorv2 field: %s", child.key)) end
                    end
                end
                table.insert(out, string.format("hl.monitor({ output = %s, mode = %s, position = %s, scale = %s })%s",
                    mv2.output, mv2.mode, mv2.position, mv2.scale,
                    node.comment and node.comment ~= false and (" -- " .. node.comment) or ""))
            elseif node.name == "windowrule" or node.name == "windowrulev2" then
                -- Bug E: windowrule {} block → hl.window_rule()
                emit_config_block()
                local rule_name = string.format("rule_%d", rule_counter)
                rule_counter = rule_counter + 1
                local fields = { "name = " .. escape_str(rule_name) }
                local match_kv = {}
                for _, child in ipairs(node.children) do
                    if child.type == "property" then
                        local ck = child.key:match("^%s*(.-)%s*$")
                        local cv = stringify_value(child.value)
                        if ck == "name" then
                            fields[1] = "name = " .. escape_str(cv)
                        elseif ck:match("^match:") then
                            local subkey = ck:sub(7)
                            table.insert(match_kv, format_key(subkey) .. " = " .. escape_str(cv))
                        else
                            table.insert(fields, format_key(ck) .. " = " .. coerce_type(cv))
                        end
                    end
                end
                if #match_kv > 0 then
                    table.insert(fields, 2, "match = { " .. table.concat(match_kv, ", ") .. " }")
                end
                table.insert(out, string.format("hl.window_rule({ %s })%s",
                    table.concat(fields, ", "),
                    node.comment and node.comment ~= false and (" -- " .. node.comment) or ""))
            else
                -- Config-eligible category: already pre-rendered in config_buf.
                emit_config_block()
            end
        end
    end

    -- Flush any remaining config block
    emit_config_block()
    
    if #animation_cmds > 0 then
        for _, cmd in ipairs(animation_cmds) do
            if cmd.key == "bezier" then
                local parts = split_by_comma(cmd.val_str)
                if #parts >= 2 then
                    local bname = escape_str(parts[1])
                    local bargs = {}
                    for i = 2, #parts do table.insert(bargs, parts[i]) end
                    local pts = {}
                    for i = 1, #bargs, 2 do
                        if bargs[i+1] then
                            table.insert(pts, string.format("{%s, %s}", bargs[i], bargs[i+1]))
                        end
                    end
                    table.insert(out, string.format("hl.curve(%s, { type = \"bezier\", points = { %s } })%s", bname, table.concat(pts, ", "), format_comment(cmd.comment)))
                else
                    table.insert(out, "-- FIXME: Unrecognized bezier format: " .. cmd.val_str)
                end
            elseif cmd.key == "animation" then
                local parts = split_by_comma(cmd.val_str)
                if #parts >= 2 then
                    local leaf = parts[1]
                    local enabled = (parts[2] == "1" or parts[2] == "true" or parts[2] == "yes") and "true" or "false"
                    local speed = parts[3] or "1"
                    local bezier = parts[4] or "\"\""
                    local style = parts[5] or "\"\""
                    
                    local anim_str = string.format("leaf = %s, enabled = %s, speed = %s", escape_str(leaf), enabled, speed)
                    if bezier ~= "\"\"" and bezier ~= "" then
                        anim_str = anim_str .. string.format(", curve = %s", escape_str(bezier))
                    end
                    if style ~= "\"\"" and style ~= "" then
                        anim_str = anim_str .. string.format(", style = %s", escape_str(style))
                    end
                    
                    table.insert(out, string.format("hl.animation({ %s })%s", anim_str, format_comment(cmd.comment)))
                else
                    table.insert(out, "-- FIXME: Unrecognized animation format: " .. cmd.val_str)
                end
            end
        end
    end

    if gesture_props["workspace_swipe"] then
        local swipe_val = coerce_type(gesture_props["workspace_swipe"].val_str)
        if swipe_val == "true" then
            local fingers = gesture_props["workspace_swipe_fingers"] and coerce_type(gesture_props["workspace_swipe_fingers"].val_str) or "3"
            table.insert(out, string.format("hl.gesture({ fingers = %s, direction = \"horizontal\", action = \"workspace\" })", fingers))
        end
    end

    if #exec_once_cmds > 0 then
        table.insert(out, "hl.on(\"hyprland.start\", function()")
        for _, cmd in ipairs(exec_once_cmds) do
            table.insert(out, string.format("    hl.exec_cmd(%s)%s",
                format_dispatcher_arg(cmd.cmd), format_comment(cmd.comment)))
        end
        table.insert(out, "end)")
    end

    if #exec_cmds > 0 then
        for _, cmd in ipairs(exec_cmds) do
            table.insert(out, string.format("hl.exec_cmd(%s)%s",
                format_dispatcher_arg(cmd.cmd), format_comment(cmd.comment)))
        end
    end

    -- Per 08_advanced_syntax.md: If the file is primarily variable assignments,
    -- emit a return table so require() can access them cross-file.
    local var_nodes = {}
    local non_var_count = 0
    for _, node in ipairs(ast) do
        if node.type == "variable" then
            table.insert(var_nodes, node)
        elseif node.type ~= "blank" and node.type ~= "comment" then
            non_var_count = non_var_count + 1
        end
    end
    if #var_nodes > 0 and non_var_count == 0 then
        local ret_parts = {}
        for _, vn in ipairs(var_nodes) do
            local lua_name = vn.name:gsub("-", "_")
            table.insert(ret_parts, string.format("    %s = %s", lua_name, lua_name))
        end
        table.insert(out, "")
        table.insert(out, "return {")
        for _, rp in ipairs(ret_parts) do table.insert(out, rp .. ",") end
        table.insert(out, "}")
    end

    return table.concat(out, "\n")
end

-- =========================================================
-- APP / CLI MODULE
-- =========================================================
local App = {}

function App.get_lua_filename(conf_path)
    return conf_path:gsub("%.conf$", ".lua")
end

function App.process_file(file_path, processed, fs_read, fs_write)
    if processed[file_path] then return end
    processed[file_path] = true

    print("Processing: " .. file_path)
    local content = fs_read(file_path)
    if not content then
        print("Warning: Could not read file " .. file_path)
        return
    end

    local success, ast = pcall(Parser.parse, content)
    if not success then
        print("Error: Parser failed for " .. file_path)
        print(ast)
        return
    end

    local emit_success, lua_code = pcall(Emitter.emit, ast)
    if not emit_success then
        print("Error: Emitter failed for " .. file_path)
        print(lua_code)
        return
    end

    local max_attempts = 15
    local attempts = 0
    local load_func = loadstring or load
    -- Single-line prefix so error line N maps to lua_code line (N - 1)
    local env_prefix = "local hl = { config = function() end, bind = function() end, bindm = function() end, submap = function() end, bezier = function() end, windowrule = function() end, monitor = function() end, workspacerule = function() end, device = function() end, env = function() end, exec_cmd = function() end, on = function() end, dsp = setmetatable({}, { __index = function() return function(...) end end }) }; local function require(mod) return {} end; "
    local prefix_lines = 1  -- env_prefix is exactly 1 line (no newlines)

    while attempts < max_attempts do
        local chunk, err = load_func(env_prefix .. lua_code)
        if chunk then
            if attempts > 0 then
                print("Successfully healed " .. file_path .. " after " .. attempts .. " attempts.")
            end
            break
        end

        print("Syntax error in " .. file_path .. ": " .. err)
        local line_num_str = err:match(":(%d+):")
        if not line_num_str then
            print("Self-healing failed: could not parse line number from error: " .. tostring(err))
            os.exit(1)
        end

        local line_num = tonumber(line_num_str) - prefix_lines
        local lines = {}
        for line in string.gmatch(lua_code .. "\n", "(.-)\n") do
            table.insert(lines, line)
        end
        table.remove(lines)

        if line_num > 0 and line_num <= #lines then
            lines[line_num] = "-- FIXME: " .. lines[line_num]
            lua_code = table.concat(lines, "\n")
        else
            print("Self-healing failed: line number " .. line_num .. " out of range.")
            os.exit(1)
        end

        attempts = attempts + 1
    end

    if attempts >= max_attempts then
        print("Self-healing failed: exceeded maximum attempts (" .. max_attempts .. ") for " .. file_path)
        os.exit(1)
    end

    local out_path = App.get_lua_filename(file_path)
    fs_write(out_path, lua_code)
    print(" -> Generated: " .. out_path)

    -- Detect dependent sources and add to queue
    for _, node in ipairs(ast) do
        if node.type == "source" then
            -- Realpath resolution logic could go here; for now, we just enqueue the raw path
            local dep_path = node.path
            if not processed[dep_path] then
                App.process_file(dep_path, processed, fs_read, fs_write)
            end
        end
    end
end

function App.main(args)
    local root_file = args and args[1]
    if not root_file then
        print("Usage: luajit hypr_convert.lua <path/to/hyprland.conf>")
        os.exit(1)
    end

    local function fs_read(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local c = f:read("*a")
        f:close()
        return c
    end

    local function fs_write(path, content)
        -- Safety block
        local f_check = io.open(path, "r")
        if f_check then
            f_check:close()
            io.write("File " .. path .. " already exists. Overwrite? (y/N): ")
            local ans = io.read()
            if ans:lower() ~= "y" then
                print("Skipping " .. path)
                return
            end
        end

        local f = io.open(path, "w")
        if f then
            f:write(content)
            f:close()
        else
            print("Error writing to " .. path)
        end
    end

    local processed = {}
    App.process_file(root_file, processed, fs_read, fs_write)
end

-- If executed as a standalone script, run App.main()
-- Otherwise, export modules for test_suite.lua or other integrations
local is_main = false
if arg and arg[0] then
    if arg[0]:match("hypr_convert%.lua$") or arg[0] == "hypr_convert.lua" then
        is_main = true
    end
end

if is_main then
    App.main(arg)
else
    return {
        Parser = Parser,
        Emitter = Emitter,
        App = App
    }
end
