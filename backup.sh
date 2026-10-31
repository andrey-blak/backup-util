#!/usr/bin/env bash

# ============================================================
# Configuration
# ============================================================

# Paths to back up.
# All paths are absolute or relative to USER_HOME.
# Single quotes allow the script to expand $HOME itself.
BACKUP_ITEMS=(
    '~/.bashrc'
    '~/.profile'
    '$HOME/.config/git/'
)

# Global exclusions (rsync patterns).
EXCLUDE_ITEMS=(
    '*.tmp'
    '*.log'
)

# Path-specific exclusions (absolute paths).
PATH_EXCLUDES=(
    '$HOME/.config/doublecmd/*.bak'
)

# ============================================================

# Determine the home directory of the invoking user.
if [[ -n "${SUDO_USER:-}" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
USER_HOME=${USER_HOME:-${HOME}}

# ============================================================
# Initialization
# ============================================================

set -o pipefail

SCRIPT_NAME=${0##*/}

DRY_RUN=0
VERBOSE=0
TIMESTAMP=0

SUCCESS_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -n, --dry-run       Show planned operations without copying
  -v, --verbose       Show detailed rsync output
  -t, --timestamp     Create a timestamped backup directory
  -h, --help          Show this help

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME -n
  ./$SCRIPT_NAME -v
  ./$SCRIPT_NAME --dry-run --verbose
  ./$SCRIPT_NAME -t
EOF
}

# Parse command-line options.
while (($#)); do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        --verbose)  VERBOSE=1 ;;
        --timestamp) TIMESTAMP=1 ;;
        --help)
            usage
            exit 0
            ;;
        --*)
            echo "Error: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        -*)
            # Parse short options, including combined ones.
            OPTIND=1
            while getopts ":nvth" opt "$1"; do
                case "$opt" in
                    n) DRY_RUN=1 ;;
                    v) VERBOSE=1 ;;
                    t) TIMESTAMP=1 ;;
                    h)
                        usage
                        exit 0
                        ;;
                    \?)
                        echo "Error: Unknown option: -$OPTARG" >&2
                        usage >&2
                        exit 2
                        ;;
                esac
            done
            ;;
        *)
            echo "Error: Unexpected argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

# Check dependencies.
if ! command -v rsync >/dev/null 2>&1; then
    echo "Error: rsync is required."
    echo "Install it with: sudo apt install rsync"
    exit 1
fi

if ! command -v realpath >/dev/null 2>&1; then
    echo "Error: realpath is required."
    exit 1
fi

# Determine the current working directory.
WORKDIR=$(pwd -P) || exit 1

# ============================================================
# Destination selection
# ============================================================

BACKUP_NAME="backup"

# If $BACKUP_NAME/ already exists, use a timestamped directory.
if ((TIMESTAMP)) || [[ -e "$WORKDIR/$BACKUP_NAME" || -L "$WORKDIR/$BACKUP_NAME" ]]; then
    BACKUP_NAME="$BACKUP_NAME-$(date '+%Y-%m-%d_%H%M%S')"
fi

DESTINATION="$WORKDIR/$BACKUP_NAME"

# Never overwrite an existing destination.
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    echo "Error: Backup destination already exists:"
    echo "  $DESTINATION"
    exit 1
fi

echo "Backup destination: $DESTINATION"

if ((DRY_RUN)); then
    echo "DRY RUN: No files will be copied."
fi

# ============================================================
# Path handling
# ============================================================

resolve_path() {
    local path=$1

    # Expand ~/...
    if [[ "$path" == "~/"* ]]; then
        path="$USER_HOME/${path:2}"
    elif [[ "$path" == "~" ]]; then
        path="$USER_HOME"
    fi

    # Expand $HOME and ${HOME}.
    path=${path//\$\{HOME\}/$USER_HOME}
    path=${path//\$HOME/$USER_HOME}

    # Relative paths are relative to home.
    if [[ "$path" != /* ]]; then
        path="$USER_HOME/$path"
    fi

    realpath -m -s -- "$path"
}

# Check whether one path is equal to or inside another.
is_within() {
    local child=$1
    local parent=$2

    [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

# Convert source path into a destination path.
destination_path() {
    local source=$1
    local relative

    if is_within "$source" "$USER_HOME"; then
        relative="home/user/${source#"$USER_HOME"/}"

        if [[ "$source" == "$USER_HOME" ]]; then
            relative="home/user"
        fi
    else
        relative=${source#/}
    fi

    printf '%s/%s\n' "$DESTINATION" "$relative"
}

# ============================================================
# Backup function
# ============================================================

backup_item() {
    local raw_path=$1
    local source
    local target
    local target_parent
    local exclusion
    local relative
    local skip_item=0

    local -a rsync_args

    source=$(resolve_path "$raw_path") || {
        echo "FAILED: Cannot resolve path: $raw_path"
        ((FAILED_COUNT++))
        return
    }

    # Reject filesystem root.
    if [[ "$source" == "/" ]]; then
        echo "REJECTED: Filesystem root cannot be backed up."
        ((FAILED_COUNT++))
        return
    fi

    # Check source existence, including dangling symlinks.
    if [[ ! -e "$source" && ! -L "$source" ]]; then
        echo "SKIPPED: $source (not found)"
        ((SKIPPED_COUNT++))
        return
    fi

    target=$(destination_path "$source")

    # Prevent source/destination overlap.
    if is_within "$DESTINATION" "$source" ||
       is_within "$source" "$DESTINATION"; then
        echo "REJECTED: Source overlaps backup destination: $source"
        ((FAILED_COUNT++))
        return
    fi

    # Build rsync arguments.
    rsync_args=(-a)

    if ((VERBOSE)); then
        rsync_args+=(-v --itemize-changes)
    fi

    # Global exclusions.
    for exclusion in "${EXCLUDE_ITEMS[@]}"; do
        rsync_args+=("--exclude=$exclusion")
    done

    # Path-specific exclusions.
    for exclusion in "${PATH_EXCLUDES[@]}"; do
        exclusion=$(resolve_path "$exclusion") || continue

        # Exclusion covers the entire source.
        if [[ "$exclusion" == "$source" ]]; then
            skip_item=1
            break
        fi

        # Exclusion is inside the source directory.
        if is_within "$exclusion" "$source" &&
           [[ "$exclusion" != "$source" ]] &&
           [[ -d "$source" ]]; then

            relative=${exclusion#"$source"/}
            rsync_args+=("--exclude=/$relative")
        fi
    done

    if ((skip_item)); then
        echo "SKIPPED: $source (excluded)"
        ((SKIPPED_COUNT++))
        return
    fi

    if ((DRY_RUN)); then
        printf 'WOULD BACK UP: %s\n' "$source"
        printf '          TO: %s\n' "$target"
        ((SUCCESS_COUNT++))
        return
    fi

    # Create destination parent directory.
    target_parent=${target%/*}

    if ! mkdir -p -- "$target_parent"; then
        echo "FAILED: Cannot create destination: $target_parent"
        ((FAILED_COUNT++))
        return
    fi

    # Copy directory contents or preserve a file/symlink.
    if [[ -d "$source" && ! -L "$source" ]]; then

        if ! mkdir -p -- "$target"; then
            echo "FAILED: Cannot create destination: $target"
            ((FAILED_COUNT++))
            return
        fi

        source="${source%/}/"
        target="${target%/}/"
    fi

    if rsync "${rsync_args[@]}" -- "$source" "$target"; then
        echo "OK: $raw_path"
        ((SUCCESS_COUNT++))
    else
        echo "FAILED: $raw_path"
        ((FAILED_COUNT++))
    fi
}

# ============================================================
# Main
# ============================================================

echo
echo "Starting backup..."
echo

for item in "${BACKUP_ITEMS[@]}"; do
    backup_item "$item"
done

# ============================================================
# Summary
# ============================================================

echo
echo "================================"
echo "Backup summary"
echo "================================"
echo "Destination: $DESTINATION"
echo "Successful:  $SUCCESS_COUNT"
echo "Skipped:     $SKIPPED_COUNT"
echo "Failed:      $FAILED_COUNT"
echo "================================"

if ((FAILED_COUNT > 0)); then
    exit 1
fi

exit 0
