#!/usr/bin/env luajit

local hypr = require("hypr_convert")
local App = hypr.App

local function run_test()
    print("--- RUNNING INTERNAL MOCK TEST ---")
    local home = os.getenv("HOME") or ""
    local mock_fs = {
        ["main.conf"] = [[
# ========================
# MY HYPRLAND CONFIG
# ========================

$MOD = SUPER
source = ~/.config/hypr/macchiato.conf # Loading theme

gaps_in = 5
gaps_out = 10
bad-property = 10 # INTENTIONAL BAD TOKEN FOR SELF-HEALING TEST

source = $HOME/keybinds.conf

# BUG 2: leading-comma monitor (empty output field)
monitor = ,preferred,auto,1
monitor = DP-1, 1920x1080@144, 0x0, 1
windowrule = float, class:kitty
windowrulev2 = size 100% 100%, class:firefox
workspace = 1, monitor:DP-1, default:true

# Bug 7: layerrule emission
layerrule = blur, waybar
layerrule = ignore_alpha 0.5, waybar

bezier = myBezier, 0.05, 0.9, 0.1, 1.05

# BUG 3: dot-notation nested keys inside a category
decoration {
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = 0xff444444
    rounding = 10
}

gestures {
    workspace_swipe = true
    workspace_swipe_fingers = 3
}

# BUG 1: exec-once with $HOME env var in path
exec-once = hotkeyhub --hyprland $HOME/.config/hypr.conf

submap = resize
bind = , right, resizeactive, 10 0
bind = , left, resizeactive, -10 0
bind = , escape, submap, reset
submap = reset

# End of config
]],
        [home .. "/.config/hypr/macchiato.conf"] = [[
# Macchiato Theme
$text = rgba(cad3f5ff)
$base = rgba(24273aff)
]],
        [home .. "/keybinds.conf"] = [[
# Keybinds
bind = $MOD, return, exec, kitty
bindd = $MOD, Q, Close the window, killactive, # Note the bindd!
bindm = $MOD, mouse:272, movewindow
bind = $MOD, SLASH, exec, fuzzel
bind = $MOD SHIFT, E, exec, dolphin
bind = , XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_SINK@ 5%+
binddel = , Print, Take a screenshot, exec, grim
bindln = , Caps_Lock, exec, dummy
bindmon = , Menu, exec, rofi
bind = $MOD, h, movefocus, l
bind = $MOD, l, movefocus, r
bind = $MOD SHIFT, h, movewindow, l
bind = $MOD, 1, workspace, 1
bind = $MOD SHIFT, 1, movetoworkspace, 1
bind = $MOD, f, togglefloating
bind = $MOD, m, fullscreen
]]
    }

    local mock_outputs = {}

    local function fs_read(path)
        return mock_fs[path]
    end

    local function fs_write(path, content)
        mock_outputs[path] = content
    end

    local processed = {}
    App.process_file("main.conf", processed, fs_read, fs_write)

    print("\n--- EMITTED OUTPUTS ---")
    local all_code = ""
    for path, code in pairs(mock_outputs) do
        print("--- " .. path .. " ---")
        print(code)
        all_code = all_code .. "\n" .. code
    end

    print("\n--- SYNTAX VALIDATION ---")
    local env_prefix = [[
local _dsp_fn = function(...) end
local _dsp_ns = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return _dsp_fn end }) end })
local hl = {
    config = function() end, bind = function() end, monitor = function() end,
    window_rule = function() end, workspace_rule = function() end, layer_rule = function() end,
    device = function() end, env = function() end, on = function() end,
    exec_cmd = function() end, define_submap = function() end,
    curve = function() end, animation = function() end,
    dsp = setmetatable({ exec_cmd = _dsp_fn, exit = _dsp_fn, submap = _dsp_fn, focus = _dsp_fn,
                          dpms = _dsp_fn, force_idle = _dsp_fn, exec_raw = _dsp_fn, workspace = _dsp_fn },
                        { __index = function(t, k)
                            return setmetatable({}, { __index = function() return _dsp_fn end })
                          end })
}
local function require(mod) return {} end
]]
    local load_func = loadstring or load
    local all_passed = true
    for path, code in pairs(mock_outputs) do
        local chunk, err = load_func(env_prefix .. code)
        if not chunk then
            print("Syntax Error in " .. path .. ":")
            print(err)
            all_passed = false
        end
    end
    if all_passed then
        print("Syntax Validation Passed.")
    else
        os.exit(1)
    end

    -- -------------------------------------------------------
    -- Targeted regression assertions (all three bug-fix groups)
    -- -------------------------------------------------------
    print("\n--- REGRESSION ASSERTIONS ---")
    local main_out = mock_outputs["main.lua"] or ""
    local keybinds_out = mock_outputs[home .. "/keybinds.lua"] or ""
    local assert_pass = true

    local function assert_contains(label, haystack, needle)
        if haystack:find(needle, 1, true) then
            print("  [PASS] " .. label)
        else
            print("  [FAIL] " .. label)
            print("         Expected to find: " .. needle)
            assert_pass = false
        end
    end
    local function assert_not_contains(label, haystack, needle)
        if not haystack:find(needle, 1, true) then
            print("  [PASS] " .. label)
        else
            print("  [FAIL] " .. label)
            print("         Must NOT contain: " .. needle)
            assert_pass = false
        end
    end

    -- Bug 1: $HOME in exec-once must become os.getenv("HOME"), NOT the bare word HOME
    assert_contains(
        "Bug1 – exec-once $HOME -> os.getenv()",
        main_out, 'os.getenv("HOME")')
    assert_not_contains(
        "Bug1 – bare 'HOME' variable not emitted without os.getenv",
        main_out, ".. HOME ..")

    -- Bug 2: leading-comma monitor -> output = ""
    assert_contains(
        "Bug2 – leading-comma monitor output field is empty string",
        main_out, 'output = ""')
    assert_contains(
        "Bug2 – leading-comma monitor mode = \"preferred\"",
        main_out, 'mode = "preferred"')

    -- Bug 3: col.active_border must NOT appear as a bare key
    assert_not_contains(
        "Bug3 – no raw dot-key [\"col.active_border\"] in output",
        main_out, '["col.active_border"]')
    assert_contains(
        "Bug3 – dot-key split: col = { active_border = ... }",
        main_out, "col = { active_border =")

    -- Bug 4: bind flag variants must use hl.bind() with options tables
    assert_not_contains(
        "Bug4 – no hl.bindm() call emitted",
        keybinds_out, "hl.bindm(")
    assert_not_contains(
        "Bug4 – no hl.bindr() call emitted",
        main_out .. keybinds_out, "hl.bindr(")
    assert_not_contains(
        "Bug4 – no hl.binde() call emitted",
        main_out .. keybinds_out, "hl.binde(")
    assert_not_contains(
        "Bug4 – no hl.bindl() call emitted",
        main_out .. keybinds_out, "hl.bindl(")
    assert_contains(
        "Bug4 – bindm -> hl.bind() with mouse = true option",
        keybinds_out, "{ mouse = true }")
    assert_contains(
        "Bug4 – binddel -> repeating = true, locked = true",
        keybinds_out, "{ repeating = true, locked = true }")
    assert_contains(
        "Bug4 – bindln -> locked = true, non_consuming = true",
        keybinds_out, "{ locked = true, non_consuming = true }")
    assert_contains(
        "Bug4 – bindmon -> mouse = true, long_press = true, non_consuming = true",
        keybinds_out, "{ mouse = true, long_press = true, non_consuming = true }")

    -- Bug 8: dispatcher namespace correctness
    assert_contains(
        "Bug8 – killactive -> hl.dsp.window.close()",
        keybinds_out, "hl.dsp.window.close()")
    assert_not_contains(
        "Bug8 – no legacy hl.dsp.killactive() emitted",
        keybinds_out, "hl.dsp.killactive(")
    assert_contains(
        "Bug8 – movewindow -> hl.dsp.window.move({ direction = ... })",
        keybinds_out, 'hl.dsp.window.move({ direction =')
    assert_not_contains(
        "Bug8 – no legacy hl.dsp.movewindow() emitted",
        keybinds_out, "hl.dsp.movewindow(")
    assert_contains(
        "Bug8 – exec -> hl.dsp.exec_cmd()",
        keybinds_out, "hl.dsp.exec_cmd(")

    -- Dispatcher table-argument assertions (04_api_translation.md §39-48)
    -- movefocus -> hl.dsp.focus({ direction = "..." })
    assert_contains(
        "Dsp – movefocus -> hl.dsp.focus({ direction = ... })",
        keybinds_out, 'hl.dsp.focus({ direction =')
    assert_not_contains(
        "Dsp – no legacy hl.dsp.window.focus() emitted",
        keybinds_out, "hl.dsp.window.focus(")
    -- movewindow direction value must be quoted
    assert_contains(
        "Dsp – movewindow direction value is quoted string",
        keybinds_out, 'direction = "l"')
    -- movefocus direction value must be quoted
    assert_contains(
        "Dsp – movefocus direction value is quoted string",
        keybinds_out, 'direction = "l"')
    -- workspace -> hl.dsp.focus({ workspace = "N" })
    assert_contains(
        "Dsp – workspace -> hl.dsp.focus({ workspace = ... })",
        keybinds_out, 'hl.dsp.focus({ workspace =')
    assert_not_contains(
        "Dsp – no legacy hl.dsp.workspace.switch() emitted",
        keybinds_out, 'hl.dsp.workspace.switch(')
    -- workspace value must be quoted
    assert_contains(
        "Dsp – workspace.switch workspace value is quoted string",
        keybinds_out, 'workspace = "1"')
    -- movetoworkspace -> hl.dsp.window.move({ workspace = "N" })
    assert_contains(
        "Dsp – movetoworkspace -> hl.dsp.window.move({ workspace = ... })",
        keybinds_out, 'hl.dsp.window.move({ workspace =')
    -- togglefloating -> hl.dsp.window.float({ action = "toggle" })
    assert_contains(
        "Dsp – togglefloating -> hl.dsp.window.float({ action = \"toggle\" })",
        keybinds_out, 'hl.dsp.window.float({ action = "toggle" })')
    assert_not_contains(
        "Dsp – no legacy hl.dsp.window.toggle_floating() for togglefloating",
        keybinds_out, 'hl.dsp.window.toggle_floating()')
    -- fullscreen -> hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })
    assert_contains(
        "Dsp – fullscreen -> hl.dsp.window.fullscreen({ mode = \"fullscreen\", action = \"toggle\" })",
        keybinds_out, 'hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })')
    assert_not_contains(
        "Dsp – no legacy hl.dsp.window.toggle_fullscreen() emitted",
        keybinds_out, 'hl.dsp.window.toggle_fullscreen()')
    -- resizeactive -> hl.dsp.window.resize({ x = ..., y = ..., relative = true }) (now verified)
    assert_contains(
        "Dsp – resizeactive -> hl.dsp.window.resize({ x = ..., y = ... })",
        main_out, 'hl.dsp.window.resize({ x =')
    assert_not_contains(
        "Dsp – resizeactive no longer emits FIXME",
        main_out, "-- FIXME: dispatcher 'resizeactive'")
    -- mouse bindm movewindow: no direction provided, call must be hl.dsp.window.drag()
    assert_contains(
        "Dsp – bindm movewindow (no dir) -> hl.dsp.window.drag()",
        keybinds_out, 'hl.dsp.window.drag()')

    -- Bug 6: key case sensitivity (xkbcommon)
    -- Single letter Q must be converted to uppercase Q
    assert_contains(
        "Bug6 – single letter q -> Q (uppercase)",
        keybinds_out, '" + Q"')
    assert_not_contains(
        "Bug6 – single letter q must NOT remain lowercase",
        keybinds_out, '" + q"')
    -- All-caps named key SLASH must be completely uppercased to SLASH
    assert_contains(
        "Bug6 – all-caps SLASH -> SLASH",
        keybinds_out, '" + SLASH"')
    assert_not_contains(
        "Bug6 – SLASH must NOT be lowercased",
        keybinds_out, '" + slash"')
    -- CamelCase XF86AudioRaiseVolume must be preserved exactly
    assert_contains(
        "Bug6 – XF86AudioRaiseVolume preserved (no case fold)",
        keybinds_out, 'XF86AudioRaiseVolume')
    -- mixed-case Print must be converted to UPPERCASE PRINT
    assert_contains(
        "Bug6 – Print -> PRINT (pure alphanumeric > 1 char)",
        keybinds_out, '"PRINT"')
    -- mouse:272 prefix must be preserved
    assert_contains(
        "Bug6 – mouse:272 preserved (no case fold)",
        keybinds_out, 'mouse:272')
    -- Caps_Lock (mixed: upper + underscore) must be preserved
    assert_contains(
        "Bug6 – Caps_Lock preserved exactly",
        keybinds_out, 'Caps_Lock')

    -- Bug 5: match table must NOT contain match = { match = ... } anti-pattern
    assert_not_contains(
        "Bug5 – no 'match = { match =' anti-pattern",
        main_out, "match = { match =")
    assert_contains(
        "Bug5 – windowrule class:kitty -> match = { class = \"kitty\" }",
        main_out, 'match = { class = "kitty" }')
    assert_contains(
        "Bug5 – windowrulev2 class:firefox -> match = { class = \"firefox\" }",
        main_out, 'match = { class = "firefox" }')

    -- Bug 7: layerrule must emit hl.layer_rule(), not a FIXME comment
    assert_contains(
        "Bug7 – layerrule blur -> hl.layer_rule() with blur = true",
        main_out, 'hl.layer_rule(')
    assert_not_contains(
        "Bug7 – no bare FIXME for layerrule",
        main_out, '-- FIXME: API documentation missing for: layerrule')
    assert_contains(
        "Bug7 – layerrule namespace waybar in match table",
        main_out, 'namespace = "waybar"')
    assert_contains(
        "Bug7 – layerrule blur effect emitted correctly",
        main_out, 'blur = true')
    assert_contains(
        "Bug7 – layerrule ignore_alpha with value emitted correctly",
        main_out, 'ignore_alpha = 0.5')

    -- Config consolidation: single hl.config() block (no fragmentation)
    local _, config_count = main_out:gsub("hl%.config%(", "")
    if config_count == 1 then
        print("  [PASS] Config – single hl.config() block emitted")
    else
        print("  [FAIL] Config – expected 1 hl.config() call, found " .. config_count)
        assert_pass = false
    end

    -- Source require path stripping
    assert_contains(
        "Source – require(\"keybinds\") not require(\"home/...\")",
        main_out, 'require("keybinds")')
    assert_not_contains(
        "Source – no expanded home path in require",
        main_out, 'require("home/')

    -- Window rule match field cleanup (no spurious class:kitty boolean)
    assert_not_contains(
        "WinRule – no spurious [\"class:kitty\"] field",
        main_out, '["class:kitty"]')
    assert_not_contains(
        "WinRule – no spurious [\"class:firefox\"] field",
        main_out, '["class:firefox"]')

    -- Bezier emits as standalone hl.curve(), not inside hl.config()
    assert_contains(
        "Anim – bezier emits as standalone hl.curve()",
        main_out, 'hl.curve("myBezier"')
    assert_not_contains(
        "Anim – no bezier inside hl.config()",
        main_out, 'bezier = ')

    -- Submap uses hl.define_submap not hl.submap
    assert_contains(
        "Submap – uses hl.define_submap()",
        main_out, 'hl.define_submap("resize"')
    assert_not_contains(
        "Submap – no legacy hl.submap() wrapper",
        main_out, 'hl.submap("resize"')

    if assert_pass then
        print("All regression assertions passed.")
    else
        print("One or more regression assertions FAILED.")
        os.exit(1)
    end
end

run_test()
