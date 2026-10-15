#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Usage: scripts/install.sh [--config-dir DIR] [--plugin FILE] [--no-reload]

Install Hypraxis into an existing Hyprland Lua configuration.
The default configuration directory is $XDG_CONFIG_HOME/hypr, or ~/.config/hypr.
The default plugin is .local/build/hypraxis_overview.so in this checkout.
EOF
}

die() { printf '%s\n' "hypraxis: $*" >&2; exit 1; }

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
config_dir=${XDG_CONFIG_HOME:-${HOME:?HOME is required}/.config}/hypr
plugin_file=$project_dir/.local/build/hypraxis_overview.so
reload=yes
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config-dir|--plugin)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            case "$1" in
                --config-dir) config_dir=$2 ;;
                --plugin) plugin_file=$2 ;;
            esac
            shift 2 ;;
        --no-reload) reload=no; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

for command in sha256sum readlink mktemp awk; do
    command -v "$command" >/dev/null 2>&1 || die "required command unavailable: $command"
done
if [ "$reload" = yes ]; then
    command -v hyprctl >/dev/null 2>&1 || die "hyprctl is unavailable; use --no-reload"
fi
[ -d "$config_dir" ] || die "configuration directory does not exist: $config_dir"
config_dir=$(CDPATH= cd -- "$config_dir" && pwd -P)
config_file=$config_dir/hyprland.lua
[ -f "$config_file" ] || die "expected an existing hyprland.lua in $config_dir"
config_target=$(readlink -f -- "$config_file") || die "cannot resolve hyprland.lua"
[ -f "$plugin_file" ] && [ -r "$plugin_file" ] || die "build the native plugin first, or pass --plugin FILE"
for directory in workspace_grid hypraxis-overview; do
    [ ! -L "$config_dir/$directory" ] || die "$directory is a directory symlink; replace that link with a local directory before installing"
done
for module in workspace_grid.lua workspace_grid/core.lua workspace_grid/hyprland.lua workspace_grid/overview.lua; do
    [ -f "$project_dir/$module" ] || die "missing source module: $module"
    [ ! -d "$config_dir/$module" ] || die "installation path is a directory: $module"
done
[ ! -d "$config_dir/hypraxis_overview.so" ] || die "plugin installation path is a directory"

temporary=
trap '[ -z "$temporary" ] || rm -f -- "$temporary"' EXIT
trap 'exit 1' HUP INT TERM
umask 077
mkdir -p -- "$config_dir/workspace_grid" "$config_dir/hypraxis-overview"

atomic_copy() {
    temporary=$(mktemp "$2.hypraxis.XXXXXX")
    cp -- "$1" "$temporary"
    chmod 644 "$temporary"
    mv -f -- "$temporary" "$2"
    temporary=
}

# New native binaries get new inodes and paths. A loaded .so is never truncated.
plugin_hash=$(sha256sum < "$plugin_file")
plugin_hash=${plugin_hash%% *}
immutable_plugin=$config_dir/hypraxis-overview/$plugin_hash.so
if [ -e "$immutable_plugin" ] || [ -L "$immutable_plugin" ]; then
    [ -f "$immutable_plugin" ] || die "immutable plugin path is not a regular file"
    existing_hash=$(sha256sum < "$immutable_plugin")
    existing_hash=${existing_hash%% *}
    [ "$existing_hash" = "$plugin_hash" ] || die "immutable plugin copy has unexpected contents"
else
    atomic_copy "$plugin_file" "$immutable_plugin"
fi
for module in workspace_grid/core.lua workspace_grid/hyprland.lua workspace_grid/overview.lua; do
    atomic_copy "$project_dir/$module" "$config_dir/$module"
done
temporary=$(mktemp "$config_dir/.hypraxis-link.XXXXXX")
rm -f -- "$temporary"
ln -s -- "hypraxis-overview/$plugin_hash.so" "$temporary"
mv -f -- "$temporary" "$config_dir/hypraxis_overview.so"
temporary=
# Publish the watched entrypoint only after every dependency is available.
atomic_copy "$project_dir/workspace_grid.lua" "$config_dir/workspace_grid.lua"

# Preserve the user's symlink and edit its resolved target atomically.
if ! awk '
    BEGIN {
        quote = "[\"" sprintf("%c", 39) "]"
        module = quote "workspace_grid" quote
        pattern = "require[ \t]*(\\([ \t]*" module "[ \t]*\\)|[ \t]+" module ")"
    }
    { line = $0; sub(/--.*/, "", line); if (line ~ pattern) found = 1 }
    END { exit !found }
' "$config_target"; then
    backup=$config_target.hypraxis-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$
    cp -p -- "$config_target" "$backup"
    temporary=$(mktemp "$config_target.hypraxis.XXXXXX")
    cp -p -- "$config_target" "$temporary"
    printf '\nrequire("workspace_grid")\n' >> "$temporary"
    mv -f -- "$temporary" "$config_target"
    temporary=
    printf '%s\n' "Saved configuration backup: $backup"
fi

printf '%s\n' 'Hypraxis installed. Super + Space opens the workspace overview.'
printf '%s\n' 'An already loaded native plugin keeps its current binary until Hyprland restarts.'
if [ "$reload" = yes ]; then
    hyprctl reload || die "files are installed, but Hyprland reload failed"
fi
