#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Everest - Link Mounts (Static Asset Manager)
# ------------------------------------------------------------------------------
# Symlinks resources from libraries/common into server instances
# based on the "mounts" config in each server definition.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)"
ROOT_PATH="$(realpath "${SCRIPT_DIR}/../")"

CONFIG_FILE="${ROOT_PATH}/config/server.json"
COMMON_ROOT="${ROOT_PATH}/libraries/common"
SERVERS_ROOT="${ROOT_PATH}/servers"

# shellcheck disable=SC2034
LOG_TAG="link-library"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/modules/library"

# Pre-flight
check_deps jq ln

[[ -f "$CONFIG_FILE" ]] || {
  log_err "Config missing: $CONFIG_FILE"
  exit 1
}
mkdir -p "$SERVERS_ROOT"

# Resolve branch (use pre-resolved if available)
if [[ -n "${EVEREST_RESOLVED_SERVER:-}" ]]; then
  RESOLVED="$EVEREST_RESOLVED_SERVER"
else
  CONFIG="$(cat "$CONFIG_FILE")"
  RESOLVED="$(resolve_branch "$CONFIG")"
fi

# ------------------------------------------------------------------------------
# Core: Symlink a resource
# ------------------------------------------------------------------------------

link_resource() {
  local source_path="$1" dest_path="$2" name="$3" tag="$4"

  if [[ ! -e "$source_path" ]]; then
    log_err "Source missing for ${tag}/${name}: $source_path"
    return 1
  fi

  mkdir -p "$(dirname "$dest_path")"

  # Preserve non-symlink targets instead of deleting them.
  if [[ -L "$dest_path" ]]; then
    rm -f "$dest_path"
  elif [[ -e "$dest_path" ]]; then
    local backup_path="${dest_path}.bak.$(date +%s)"
    mv "$dest_path" "$backup_path"
    log_warn "Moved existing path to backup: ${backup_path}"
  fi

  ln -sfn "$source_path" "$dest_path"
  log_info "${tag}: ${name} → ${dest_path}"
  return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

# Iterate servers in resolved branch (keys with .engine field)
mapfile -t SERVERS < <(jq -r '
    to_entries[]
    | select(.value | type == "object" and has("engine"))
    | .key
' <<<"$RESOLVED")

failures=0

for server in "${SERVERS[@]}"; do
  SERVER_DIR="${SERVERS_ROOT}/${server}"

  if [[ ! -d "$SERVER_DIR" ]]; then
    log_warn "Server directory missing: ${server}. Creating..."
    mkdir -p "$SERVER_DIR"
  fi

  # Check for mounts
  has_mounts="$(jq -r --arg s "$server" '.[$s].mounts // null | type' <<<"$RESOLVED")"

  if [[ "$has_mounts" != "object" ]]; then
    log_info "No mounts for ${server}. Skipping."
    continue
  fi

  log_info "Processing mounts: ${GREEN}${server}${NC}"

  while IFS=$'\t' read -r name src dest; do
    [[ -n "$name" && -n "$src" && -n "$dest" ]] || {
      log_warn "Invalid mount entry in ${server}: name=${name}"
      continue
    }
    if ! link_resource "${COMMON_ROOT}/${src}" "${SERVER_DIR}/${dest}" "$name" "$server"; then
      ((failures++)) || true
    fi
  done < <(jq -r --arg s "$server" '
        .[$s].mounts
        | to_entries[]
        | "\(.key)\t\(.value.src)\t\(.value.dest)"
    ' <<<"$RESOLVED")
done

if [[ $failures -gt 0 ]]; then
  log_err "Mount linking completed with ${failures} failure(s)."
  exit 1
fi

log_info "Mount linking complete."
exit 0
