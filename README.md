# Hypraxis

<img width="1920" height="1080" alt="Image" src="https://github.com/user-attachments/assets/6dcf8444-2ddd-4a90-b46d-d505547795ce" />

---

https://github.com/user-attachments/assets/1480f74b-0b6b-4b7a-b3ca-af09cb9e348d

Hypraxis is a Lua module that organizes existing Hyprland workspaces into project columns (X) and workspace rows (Y). There are 10 columns, with rows added as needed. With the native plugin installed, you can browse desktops in all four directions through an overview with a blurred background. Hyprland handles window tiling. Hypraxis does not launch a separate daemon or screen capture command.

## Requirements and compatibility

- Tested with the Lua configuration API in Hyprland **0.56.2**. Compatibility with 0.55 and other versions has not been verified.
- Operations target the currently active monitor. Initial support is limited to a single monitor.
- The overview is a C++ plugin that must be built against headers from the same Hyprland commit and with matching dependency ABIs. It refuses to load if the versions do not match.
- Building requires a C++23 compiler, CMake 3.25 or later, make, pkg-config, Hyprland development headers, and Lua and GLES development files. The standalone Lua tests run with a standard Lua interpreter.

## Installation

The project is named Hypraxis, and its Lua module is named `hypraxis`. Load it in your configuration with `require("hypraxis")`.

Clone this repository and run the following commands from its root:

```sh
make plugin
sh scripts/install.sh
```

The installer copies the module into the Hyprland configuration directory and adds `require("hypraxis")` to the existing `hyprland.lua` if it is missing. It backs up the configuration before modifying it, preserves configuration file symlinks, and reloads Hyprland when finished.

If you use a custom configuration directory, specify it with `sh scripts/install.sh --config-dir /path/to/config --no-reload`, then reload the Hyprland instance using that configuration. You can also specify a prebuilt plugin with `--plugin FILE`.

Native binaries are installed under filenames based on their content hashes, so a loaded `.so` is never overwritten. Updates to an already loaded native plugin take effect after restarting Hyprland.

To manually install only the Lua grid controls, first make sure no module with the same name exists, then run:

```sh
hypr_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
install -d "$hypr_dir/hypraxis"
install -m 644 hypraxis.lua "$hypr_dir/hypraxis.lua"
install -m 644 hypraxis/core.lua "$hypr_dir/hypraxis/core.lua"
install -m 644 hypraxis/hyprland.lua "$hypr_dir/hypraxis/hyprland.lua"
install -m 644 hypraxis/overview.lua "$hypr_dir/hypraxis/overview.lua"
```

Back up `hyprland.lua`, then add the following line **after** your existing keybinding definitions, in the default submap:

```lua
require("hypraxis")
```

Hyprland adds the configuration directory to Lua's search path, so you do not need to modify `package.path`. If you use a custom `--config`, place the module in the same directory as that configuration file.

```sh
hyprctl reload config-only
hyprctl configerrors
```

For manual updates, replace the same four files and reload. The grid controls remain available without the native plugin.

## Controls

| Key | Action |
|---|---|
| Super + 1–9 / 0 | Switch to column X=1–9 / 10 |
| Super + Alt + Up | Move up one row in the same column |
| Super + Alt + Down | Move down one row in the same column |
| Super + Shift + 1–9 / 0 | Move the active window to the corresponding column and follow it |
| Super + Alt + Shift + Up / Down | Move the active window up or down one row and follow it |
| Super + Space | Open or cancel the desktop overview |

Moving up at Y=1 does nothing. Unvisited columns start at Y=1; previously visited columns return to their last Y position. Switching to the current column also does nothing.

**The existing bindings for the 25 key combinations above are replaced.** Super + Shift + number also changes from moving a window to a fixed workspace ID to moving it to the column's remembered position. Other keys are unchanged. In 0.56.2, `hl.unbind()` also removes bindings in other submaps with the same key notation. If your configuration uses these keys in other submaps, adjust it before installing. Do not register the same keys again after loading the module.

Grid controls do nothing while a special workspace is visible. Existing special workspace bindings remain available. Window move operations do nothing when there is no active window or when the window is pinned.

## Desktop overview

Super + Space opens the overview over a blurred image of the current screen. The selected desktop appears in the center, with adjacent rows in the same column above and below, and the remembered positions of adjacent columns to the left and right. The center preview is larger than the surrounding previews. Selection changes and opening and closing transitions animate over approximately 210 ms.

| Key in the overview | Action |
|---|---|
| H / J / K / L (or arrow keys) | Bring the left / down / up / right candidate to the center |
| Enter | Switch to the center candidate and close the overview |
| Esc / Super + Space | Cancel and close the overview |

Browsing does not change the actual workspace or the columns' remembered positions. A temporary selection is kept for each column, and Enter commits only the final selected coordinates. Out-of-range candidates are hidden at the top row and the left and right edges. Unused rows can be selected as empty desktops.

Previews are still images of workspaces rendered on the GPU when the overview opens. Selection changes capture only new candidates, and previously captured candidates are limited to nine images. Stored preview images have a maximum long edge of 1600 px, and the blurred background is limited to 640 px. Images are never saved to disk. Closing the overview releases the images and input callbacks. The animation timer also stops while the overview is idle.

The overview closes on configuration reload, external workspace changes, monitor configuration changes, or session lock. Workspaces belonging to another monitor show placeholders. Capturing previews does not switch actual workspaces or move windows.

## Position memory and limitations

Coordinates are mapped internally with `id = x + 10 * (y - 1)`. For example, (1, 2) maps to 11, and (2, 5) maps to 42. Existing positive workspace IDs are included in this mapping, so existing workspaces with IDs of 11 or higher are also used.

There is no fixed maximum number of rows. Coordinate conversion validates that IDs fall within the exact integer range supported by both Lua and LuaJIT (1 to 2^53−1) and rejects values outside that range. Negative IDs and special workspaces are not remembered.

Position memory is synchronized on workspace changes, monitor focus changes, startup, and reload, and the current position is checked immediately before each operation. External switches made through gestures, the mouse, `hyprctl`, and other means are also remembered.

Memory lasts only for the current Lua session. **In 0.56.2, reloading the configuration destroys the Lua state and registered handlers, so other columns' remembered positions are reset and only the current workspace's position is recovered.** Loading the module again within the same Lua session does not duplicate registrations. Persistence across restarts is not implemented.

With multiple monitors, column memory is shared, and Hyprland's standard behavior brings the destination workspace to the active monitor. Independent grids per monitor, conflicts with workspaces displayed on other monitors, and hotplug behavior have not been verified.

## Lua API

```lua
local grid = require("hypraxis")
grid.switch_column(2)
grid.step(1)                     -- Move down
grid.move_to_column(3)           -- Move the window and follow it
grid.move_vertical(-1, false)    -- Move only the window up
grid.go_to(2, 5)                -- Switch to absolute coordinates
grid.toggle_overview()          -- Toggle the overview
local x, y = grid.position()
```

Operations return `true` on success, or `nil, reason` at a boundary, in an invalid state, or on failure. `position()` returns `x, y` or `nil, reason`. If a Hyprland move fails, the destination is not written to position memory.

Coordinate conversion can be used independently through `require("hypraxis.core").to_id(x, y)` and `from_id(id)`. The core accepts an optional third argument (the second argument for `from_id`) to specify the number of columns, but the default keybindings and Hyprland integration use 10 columns.

## Uninstallation

Run `sh scripts/uninstall.sh` to remove the installed files and the standalone `require("hypraxis")` line and reload the configuration. Configuration backups and unrelated files are preserved. Use `--config-dir DIR` for a custom installation directory.

To uninstall manually, remove the `require("hypraxis")` line from `hyprland.lua` and run `hyprctl reload config-only`. Then remove the files installed by Hypraxis: `hypraxis.lua`, its files under `hypraxis/`, `hypraxis_overview.so`, and its files under `hypraxis-overview/`. The keybindings in your original configuration are restored. The loaded native library remains in memory until Hyprland restarts. Uninstallation does not delete workspaces or windows.

## Development and testing

```sh
make test
make test LUA=luajit
make test-overview
```

The tests run with a standard Lua interpreter. They cover coordinates and boundaries, independent column memory, external events, consistency after failures, special workspaces, window moves, keybinding conflicts, and repeated registration. The Hyprland integration tests use API mocks.

All 10,334 checks have passed on both Lua 5.5.1 and LuaJIT 2.1. The grid controls have also been verified in a live Hyprland 0.56.2 session with a single monitor: no configuration errors, column and row switching, synchronization with external switches, moving test tiled windows with and without following them, preservation of unrelated keys, and prevention of duplicate registrations after reload.

All 45 installation and uninstallation regression tests have also passed. Mock tests verify that `require("hypraxis")` succeeds when Lua's search path contains only the installation directory and that the native plugin can be located in the same directory. In an isolated Hyprland instance, eight checks passed, covering Super + Space, HJKL, Enter, and Esc through a virtual keyboard, 64 consecutive operations, reload and unload while the overview is open, image resource cleanup, and prevention of input leaking to applications. The regular working environment has also been checked for coexistence with existing plugins, blur and previews, temporary selection and cancellation, timer suspension while idle, and preservation of existing windows and configuration.

`make test-overview` starts a separate Hyprland process and uses foot, wtype, and grim to verify actual rendering, input, confirmation, cancellation, reload, and unload. It does not control the parent Hyprland instance. Logs and images are saved to `.local/overview-test/`, which is excluded from Git.

Physical keyboard input, Hyprland restarts, multiple monitors, and other Hyprland versions have not been verified.

The API usage is based on the installed Lua stubs and the [Hyprland v0.56.2 source](https://github.com/hyprwm/Hyprland/tree/v0.56.2/src/config/lua). The [official keybinding documentation](https://wiki.hypr.land/configuring/core/binds/) and [official event list](https://wiki.hypr.land/configuring/core/advanced-configuration/events/) may describe the latest development version, so check them against the stubs for your installed version.

Do not add personal configuration, investigation logs, absolute paths, or credentials to the repository. The local-only `PROMPT.md` and `docs/` are treated as excluded from Git.

## License

A license has not yet been selected. A `LICENSE` file will be added once one is chosen.
