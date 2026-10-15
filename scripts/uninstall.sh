#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Usage: scripts/uninstall.sh [--config-dir DIR] [--no-reload]

Remove Hypraxis files and standalone require("workspace_grid") lines.
The default configuration directory is $XDG_CONFIG_HOME/hypr, or ~/.config/hypr.
Configuration backups and unrelated files are retained.
EOF
}

die() { printf '%s\n' "hypraxis: $*" >&2; exit 1; }

config_dir=${XDG_CONFIG_HOME:-${HOME:?HOME is required}/.config}/hypr
reload=yes
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config-dir)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            config_dir=$2; shift 2 ;;
        --no-reload) reload=no; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

for command in readlink mktemp awk; do
    command -v "$command" >/dev/null 2>&1 || die "required command unavailable: $command"
done
if [ "$reload" = yes ]; then
    command -v hyprctl >/dev/null 2>&1 || die "hyprctl is unavailable; use --no-reload"
fi
[ -d "$config_dir" ] || die "configuration directory does not exist: $config_dir"
config_dir=$(CDPATH= cd -- "$config_dir" && pwd -P)
for file in workspace_grid.lua hypraxis_overview.so; do
    [ ! -d "$config_dir/$file" ] || die "expected an installed file, found a directory: $file"
done
if [ ! -L "$config_dir/workspace_grid" ]; then
    for file in core.lua hyprland.lua overview.lua; do
        [ ! -d "$config_dir/workspace_grid/$file" ] || die "expected an installed module, found a directory: $file"
    done
fi

requires() {
    awk -v mode="$1" '
        BEGIN {
            quote = "[\"" sprintf("%c", 39) "]"
            module = quote "workspace_grid" quote
            expression = "require[ \t]*(\\([ \t]*" module "[ \t]*\\)|[ \t]+" module ")"
            standalone = "^[ \t]*" expression "[ \t]*;?[ \t]*$"
        }
        {
            exact = $0 ~ standalone
            if (exact) found = 1
            line = $0; sub(/--.*/, "", line)
            if (!exact && line ~ expression) custom = 1
            if (mode == "remove" && !exact) print
        }
        END {
            if (mode == "custom") exit !custom
            if (mode == "present") exit !found
        }
    ' "$2"
}

temporary=
trap '[ -z "$temporary" ] || rm -f -- "$temporary"' EXIT
trap 'exit 1' HUP INT TERM
umask 077
config_file=$config_dir/hyprland.lua
if [ -f "$config_file" ]; then
    config_target=$(readlink -f -- "$config_file") || die "cannot resolve hyprland.lua"
    if requires custom "$config_target"; then
        die 'hyprland.lua contains a custom workspace_grid require expression; remove that expression before uninstalling (standalone require lines are removed automatically)'
    fi
    if requires present "$config_target"; then
        backup=$config_target.hypraxis-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$
        cp -p -- "$config_target" "$backup"
        temporary=$(mktemp "$config_target.hypraxis.XXXXXX")
        cp -p -- "$config_target" "$temporary"
        requires remove "$config_target" > "$temporary"
        mv -f -- "$temporary" "$config_target"
        temporary=
        printf '%s\n' "Saved configuration backup: $backup"
    fi
fi

rm -f -- "$config_dir/workspace_grid.lua" "$config_dir/hypraxis_overview.so"
if [ -L "$config_dir/workspace_grid" ]; then
    rm -f -- "$config_dir/workspace_grid"
else
    for file in core.lua hyprland.lua overview.lua; do
        rm -f -- "$config_dir/workspace_grid/$file"
    done
    rmdir -- "$config_dir/workspace_grid" 2>/dev/null || :
fi
if [ -L "$config_dir/hypraxis-overview" ]; then
    rm -f -- "$config_dir/hypraxis-overview"
elif [ -d "$config_dir/hypraxis-overview" ]; then
    for file in "$config_dir/hypraxis-overview/"*.so; do
        name=${file##*/}
        hash=${name%.so}
        [ "${#hash}" -eq 64 ] || continue
        case "$hash" in *[!0-9a-f]*) continue ;; esac
        if [ -f "$file" ] || [ -L "$file" ]; then rm -f -- "$file"; fi
    done
    rmdir -- "$config_dir/hypraxis-overview" 2>/dev/null || :
fi

printf '%s\n' 'Hypraxis removed. Workspaces and windows are preserved.'
printf '%s\n' 'An already loaded native plugin remains in memory until Hyprland restarts.'
if [ "$reload" = yes ]; then
    hyprctl reload || die "files are removed, but Hyprland reload failed"
fi
