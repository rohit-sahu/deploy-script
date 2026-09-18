#!/usr/bin/env bash
# Shared helpers for deploy.sh and deploy 2.sh: the 5-tier input-source
# resolution used for every overridable setting (NEXT_PUBLIC_SITE_URL,
# APP_DIR, DOMAIN, IMAGE), plus a couple of small utilities both scripts
# need identically. Sourced, not executed directly.
#
# Tiers, first match wins:
#   1. CLI flag / positional arg
#   2. Raw already-exported environment variable
#   3. This script's own persisted state file ($ENV_FILE, e.g. ./.env,
#      auto-written by set_env_var after a successful run)
#   4. Fallback dotenv-style file ($ENV_FILE_PATH, default .env.local)
#   5. Interactive prompt / hardcoded default (caller's responsibility —
#      the prompt text and default differ per setting)
#
# Callers must set ENV_FILE and ENV_FILE_PATH before using these functions.

# True (exit 0) iff FILE parses as JSON containing a non-empty array.
json_array_nonempty() {
	[ -f "$1" ] && node -e '
		try {
			const arr = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
			process.exit(Array.isArray(arr) && arr.length > 0 ? 0 : 1);
		} catch { process.exit(1); }
	' "$1" 2>/dev/null
}

# Reads KEY from this script's own persisted state file ($ENV_FILE) — tier 3.
get_env_var() {
	[ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

# Writes/updates KEY=VALUE in $ENV_FILE, creating it (mode 600 — it can hold
# the same kind of settings as .env.local) if it doesn't exist yet.
set_env_var() {
	touch "$ENV_FILE"
	chmod 600 "$ENV_FILE" 2>/dev/null || true
	if grep -qE "^$1=" "$ENV_FILE"; then
		sed -i.bak -E "s|^$1=.*|$1=$2|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
	else
		printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
	fi
}

# Reads KEY from the fallback dotenv-style file ($ENV_FILE_PATH, default
# .env.local) — tier 4, below this script's own $ENV_FILE state. A missing
# file is not an error, it's silently skipped.
env_file_var() {
	local key="$1"
	[ -f "$ENV_FILE_PATH" ] && grep -E "^${key}=" "$ENV_FILE_PATH" | tail -n1 | cut -d= -f2- || true
}

# Resolves ONE overridable setting through tiers 1-4 (tier 5 — prompt/
# default — stays with the caller, since text/default differ per setting).
#   $1 = CLI value (may be empty)
#   $2 = name of the raw environment variable to check (tier 2)
#   $3 = key to read from this script's own state file, $ENV_FILE (tier 3)
#   $4 = key to read from the fallback file, $ENV_FILE_PATH (tier 4)
resolve_setting() {
	local cli="$1" envname="$2" statekey="$3" filekey="$4" val
	val="$cli"
	[ -z "$val" ] && val="${!envname:-}"
	[ -z "$val" ] && val="$(get_env_var "$statekey")"
	[ -z "$val" ] && val="$(env_file_var "$filekey")"
	printf '%s' "$val"
}
