-- Used only by scripts/test-overview.py in a separate compositor process.
hl.permission({ binary = "^/usr/bin/grim$", type = "screencopy", mode = "allow" })
hl.monitor({ output = "", mode = "preferred", position = "0x0", scale = 1 })
hl.config({
    general = { gaps_in = 8, gaps_out = 18, border_size = 2, layout = "dwindle" },
    decoration = { rounding = 14, blur = { enabled = true, size = 8, passes = 3 } },
    animations = { enabled = false },
    -- wtype supplies its own virtual keymap instead of physical keycodes.
    input = { follow_mouse = 0, resolve_binds_by_sym = true },
    misc = { disable_hyprland_logo = true, force_default_wallpaper = 0,
        background_color = "rgb(162439)", enable_anr_dialog = false },
    debug = { disable_logs = false },
})
require("workspace_grid")
