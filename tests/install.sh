#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$project_dir" <<'PY'
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

project = Path(sys.argv[1])
installer = project / "scripts/install.sh"
uninstaller = project / "scripts/uninstall.sh"
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


with tempfile.TemporaryDirectory(prefix="hypraxis-install-test-") as temporary:
    root = Path(temporary)
    mock_bin = root / "bin"
    mock_bin.mkdir()
    mock_hyprctl = mock_bin / "hyprctl"
    mock_hyprctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$HYP_TEST_RELOAD_LOG"\n')
    mock_hyprctl.chmod(0o755)
    mock_mv = mock_bin / "mv"
    mock_mv.write_text('''#!/bin/sh
for destination do :; done
if [ "$destination" = "$HYP_TEST_CONFIG/hypraxis.lua" ]; then
    for module in core.lua hyprland.lua overview.lua; do
        [ -f "$HYP_TEST_CONFIG/hypraxis/$module" ] || exit 90
    done
    [ -L "$HYP_TEST_CONFIG/hypraxis_overview.so" ] || exit 91
fi
exec "$HYP_TEST_REAL_MV" "$@"
''')
    mock_mv.chmod(0o755)
    reload_log = root / "reloads.log"
    config = root / "hypr config"
    config.mkdir()
    target = root / "main config.lua"
    original = '-- existing user configuration\nhl.config({})\n'
    target.write_text(original)
    target.chmod(0o640)
    main = config / "hyprland.lua"
    main.symlink_to("../main config.lua")
    symlink_inode = main.lstat().st_ino
    modules = config / "hypraxis"
    modules.mkdir()
    sentinel = modules / "unrelated.lua"
    sentinel.write_text("-- retain unrelated module\n")
    plugin = root / "native plugin.so"
    plugin.write_bytes(b"first immutable plugin")
    env = dict(os.environ, PATH=str(mock_bin) + os.pathsep + os.environ["PATH"],
               XDG_CONFIG_HOME=str(root / "xdg"), HYP_TEST_RELOAD_LOG=str(reload_log),
               HYP_TEST_REAL_MV=shutil.which("mv"), HYP_TEST_CONFIG=str(config))

    def run(script, *arguments, succeeds=True):
        result = subprocess.run([str(script), *map(str, arguments)], env=env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        check((result.returncode == 0) == succeeds,
              f"unexpected result from {script.name}: {result.stdout}{result.stderr}")
        return result

    install_args = ("--config-dir", config, "--plugin", plugin, "--no-reload")
    uninstall_args = ("--config-dir", config, "--no-reload")
    run(installer, *install_args)
    check(main.is_symlink() and main.lstat().st_ino == symlink_inode,
          "installation preserves the main configuration symlink and inode")
    check(target.read_text() == original + '\nrequire("hypraxis")\n',
          "installation appends exactly one standalone require line")
    check(stat.S_IMODE(target.stat().st_mode) == 0o640, "configuration mode is preserved")
    backups = list(root.glob("main config.lua.hypraxis-backup-*"))
    check(len(backups) == 1 and backups[0].read_text() == original,
          "configuration backup preserves its original contents")
    for module in ("hypraxis.lua", "hypraxis/core.lua",
                   "hypraxis/hyprland.lua", "hypraxis/overview.lua"):
        check((config / module).read_bytes() == (project / module).read_bytes(),
              f"installed module matches source: {module}")
    loaded = subprocess.run(
        [*shlex.split(env.get("LUA", "lua")), "-", str(config)],
        cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        input='''
package.path = arg[1] .. "/?.lua"
local bindings, subscriptions, plugins = 0, 0, {}
hl = {
    get_current_submap = function() return "" end,
    get_active_workspace = function() return { id = 1 } end,
    get_active_special_workspace = function() end,
    get_active_window = function() end,
    unbind = function() end,
    bind = function() bindings = bindings + 1 end,
    on = function()
        subscriptions = subscriptions + 1
        return { remove = function() end }
    end,
    dsp = { focus = function() end, window = { move = function() end } },
    dispatch = function() return { ok = true } end,
    plugin = { load = function(path) plugins[#plugins + 1] = path end },
}
local grid = require("hypraxis")
local x, y = grid.position()
assert(x == 1 and y == 1, "installed module exposes the grid API")
assert(require("hypraxis.core").to_id(2, 5) == 42, "installed core is loadable")
assert(type(grid.overview) == "table", "installed overview is loadable")
assert(require("hypraxis") == grid, "cached require returns the same controller")
package.loaded.hypraxis = nil
assert(require("hypraxis") == grid, "cache clearing preserves the controller")
assert(bindings == 25 and subscriptions == 4, "loading remains idempotent")
assert(#plugins == 1 and plugins[1] == arg[1] .. "/hypraxis_overview.so",
    "native plugin is loaded beside the installed hypraxis module")
''')
    check(loaded.returncode == 0,
          f"installed hypraxis loads outside the checkout: {loaded.stdout}{loaded.stderr}")
    installed = config / "hypraxis_overview.so"
    check(installed.is_symlink() and installed.read_bytes() == plugin.read_bytes(),
          "native entrypoint resolves to the installed plugin")
    old_copy = installed.resolve()
    old_inode = old_copy.stat().st_ino
    check(old_copy.name == hashlib.sha256(plugin.read_bytes()).hexdigest() + ".so",
          "native copies use content-addressed filenames")
    run(installer, *install_args)
    check(target.read_text() == original + '\nrequire("hypraxis")\n'
          and len(list(root.glob("main config.lua.hypraxis-backup-*"))) == 1,
          "repeated installation leaves require and backups unchanged")
    check(old_copy.stat().st_ino == old_inode, "same-version installation reuses the native inode")
    plugin.write_bytes(b"second immutable plugin")
    run(installer, *install_args)
    check(installed.resolve() != old_copy and installed.read_bytes() == plugin.read_bytes(),
          "upgrade atomically points at a new native copy")
    check(old_copy.stat().st_ino == old_inode and old_copy.read_bytes() == b"first immutable plugin",
          "upgrade leaves a previously loaded native inode and contents intact")
    check(sentinel.read_text() == "-- retain unrelated module\n", "installation preserves unrelated files")
    native_sentinel = config / "hypraxis-overview" / "unrelated.so"
    native_sentinel.write_bytes(b"retain unrelated binary")
    run(uninstaller, *uninstall_args)
    check(main.is_symlink() and main.lstat().st_ino == symlink_inode
          and stat.S_IMODE(target.stat().st_mode) == 0o640,
          "uninstallation also preserves the configuration symlink and mode")
    check(target.read_text() == original + "\n", "uninstallation removes only the require line")
    check(sentinel.is_file() and native_sentinel.read_bytes() == b"retain unrelated binary",
          "uninstallation keeps unrelated Lua and native files")
    check(not (config / "hypraxis.lua").exists() and not installed.is_symlink()
          and not old_copy.exists(), "uninstallation removes owned entrypoints and native copies")
    run(uninstaller, *uninstall_args)
    check(target.read_text() == original + "\n", "repeated uninstallation leaves configuration unchanged")
    check(not reload_log.exists(), "--no-reload never invokes hyprctl")

    target.write_text('local grid = require("hypraxis")\n')
    run(installer, *install_args)
    check(target.read_text() == 'local grid = require("hypraxis")\n',
          "installation recognizes custom require expressions without duplication")
    result = run(uninstaller, *uninstall_args, succeeds=False)
    check("custom Hypraxis require" in result.stderr
          and (config / "hypraxis.lua").is_file()
          and target.read_text() == 'local grid = require("hypraxis")\n',
          "custom require expressions fail uninstallation before mutation")
    target.write_text('require("hypraxis")\n  require \'hypraxis\';\n'
                      'require("other")\n-- require("hypraxis")\n')
    run(uninstaller, *uninstall_args)
    check(target.read_text() == 'require("other")\n-- require("hypraxis")\n',
          "only exact standalone requires are removed; unrelated requires and comments remain")

    safe_config = root / "symlink safety"
    safe_config.mkdir()
    (safe_config / "hyprland.lua").write_text('-- unchanged\n')
    external = root / "external files"
    external.mkdir()
    external_sentinel = external / "core.lua"
    external_sentinel.write_text('-- external source\n')
    for directory in ("hypraxis", "hypraxis-overview"):
        link = safe_config / directory
        link.symlink_to(external, target_is_directory=True)
        result = run(installer, "--config-dir", safe_config, "--plugin", plugin,
                     "--no-reload", succeeds=False)
        check("directory symlink" in result.stderr and link.is_symlink()
              and not (safe_config / "hypraxis.lua").exists(),
              "external directory symlinks fail installation before publishing files")
        run(uninstaller, "--config-dir", safe_config, "--no-reload")
        check(not link.is_symlink() and external_sentinel.read_text() == '-- external source\n',
              "uninstallation unlinks external module directories without touching targets")

    default_config = root / "xdg" / "hypr"
    default_config.mkdir(parents=True)
    (default_config / "hyprland.lua").write_text('-- XDG default\n')
    env["HYP_TEST_CONFIG"] = str(default_config)
    run(installer, "--plugin", plugin)
    run(uninstaller)
    check(reload_log.read_text() == "reload\nreload\n",
          "default XDG installation and uninstallation use only the mocked reload")
    check((default_config / "hyprland.lua").read_text() == '-- XDG default\n\n'
          and not (default_config / "hypraxis").exists(),
          "default XDG configuration stays intact after removal")

print(f"install: {checks} checks passed")
PY
