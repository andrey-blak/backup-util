# Backup

Creates a backup of the paths specified in BACKUP_ITEMS.

Usage: backup.sh [OPTIONS]

### Options:
	-n, --dry-run       Show planned operations without copying
	-v, --verbose       Show detailed rsync output
	-t, --timestamp     Create a timestamped backup directory
	-h, --help          Show this help

### Examples:
	./backup.sh
	./backup.sh -n
	./backup.sh -v
	./backup.sh --dry-run --verbose
	./backup.sh -t
