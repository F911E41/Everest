#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Everest - Link Plugin (Jar-only Dynamic Plugin Manager)
# ------------------------------------------------------------------------------
# Links *.jar files from libraries/plugins into server plugin directories.
# Supports two plugin config formats:
#   - Flat:    { "name": { "type": "managed|manual", "pattern": "..." } }
#   - Grouped: { "Managed": { "name": { "pattern": "..." } }, "Manual": {...} }
# Source paths resolved via definitions.paths in server.json.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)"
ROOT_PATH="$(realpath "${SCRIPT_DIR}/../")"

CONFIG_FILE="${ROOT_PATH}/config/server.json"
PLUGIN_LIB_ROOT="${ROOT_PATH}/libraries/plugins"
SERVERS_ROOT="${ROOT_PATH}/servers"

# shellcheck disable=SC2034
LOG_TAG="link-plugin"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/modules/library"

# Pre-flight
check_deps jq find ln mktemp mv

[[ -f "$CONFIG_FILE" ]] || {
  log_err "Config missing: $CONFIG_FILE"
  exit 1
}
mkdir -p "$PLUGIN_LIB_ROOT" "$SERVERS_ROOT"

# Resolve config (use pre-resolved if available)
if [[ -n "${EVEREST_RESOLVED_SERVER:-}" ]]; then
  RESOLVED="$EVEREST_RESOLVED_SERVER"
else
  CONFIG="$(cat "$CONFIG_FILE")"
  RESOLVED="$(resolve_branch "$CONFIG")"
fi

if [[ -n "${EVEREST_DEFINITIONS:-}" ]]; then
  DEFINITIONS="$EVEREST_DEFINITIONS"
else
  DEFINITIONS="$(jq '.definitions // {}' "$CONFIG_FILE")"
fi

# ------------------------------------------------------------------------------
# Detect plugin config format
# ------------------------------------------------------------------------------
# Returns "flat" if top-level values have "pattern", "grouped" otherwise.
# Flat:    proxy-style { name: { type, pattern } }
# Grouped: wildy-style { Managed: { name: { pattern } }, Manual: { ... } }
# ------------------------------------------------------------------------------

detect_format() {
  jq -r '
    if type != "object" or length == 0 then
      "grouped"
    elif (to_entries | first | .value | (type == "object" and has("pattern"))) then
      "flat"
    else
      "grouped"
    end
  ' <<<"$1"
}

# ------------------------------------------------------------------------------
# Resolve source directory for a category
# ------------------------------------------------------------------------------

resolve_src_dir() {
  local category="$1" engine="$2"
  local path_template
  path_template="$(jq -r --arg c "$category" '.paths[$c] // empty' <<<"$DEFINITIONS")"
  [[ -n "$path_template" ]] || return 1
  echo "${ROOT_PATH}/$(interpolate "$path_template" engine "$engine")"
}

# ------------------------------------------------------------------------------
# Link a single plugin jar (shared by both formats)
# ------------------------------------------------------------------------------

link_one_plugin() {
  local name="$1" pattern="$2" src_dir="$3" temp_dir="$4"
  local src_file
  src_file="$(pick_latest "$src_dir" "$pattern")"

  if [[ -n "$src_file" && -f "$src_file" ]]; then
    ln -sfn "$src_file" "${temp_dir}/${name}.jar"
    log_info "Linked: ${name}.jar → $(basename "$src_file")"
    return 0
  else
    log_warn "Not found: ${name} (${pattern}) in ${src_dir}"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Link plugins for a server
# ------------------------------------------------------------------------------

link_server_plugins() {
  local server="$1" engine="$2" server_dir="$3"
  local dest_dir="${server_dir}/plugins"
  mkdir -p "$dest_dir"

  # Get plugins config
  local plugins_json
  plugins_json="$(jq -r --arg s "$server" '.[$s].plugins // null' <<<"$RESOLVED")"
  if [[ -z "$plugins_json" || "$plugins_json" == "null" ]]; then
    log_warn "No plugins configured for ${server}. Skipping."
    return 0
  fi

  # Build in temp dir
  local temp_dir
  temp_dir="$(mktemp -d -p "$server_dir" ".plugins_build_XXXXXX")"

  local linked=0 missing=0
  local format
  format="$(detect_format "$plugins_json")"

  if [[ "$format" == "flat" ]]; then
    # Flat: { "name": { "type": "managed|manual", "pattern": "glob" } }
    while IFS=$'\t' read -r name type pattern; do
      [[ -n "$name" ]] || continue

      local category
      case "$type" in
      managed) category="Managed" ;;
      manual) category="Manual" ;;
      *)
        log_warn "Unknown type '${type}' for ${name} in ${server}. Skipping."
        continue
        ;;
      esac

      local src_dir
      src_dir="$(resolve_src_dir "$category" "$engine")" || {
        log_warn "No path definition for category '${category}'"
        continue
      }

      if link_one_plugin "$name" "$pattern" "$src_dir" "$temp_dir"; then
        ((linked++)) || true
      else
        ((missing++)) || true
      fi
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value.type)\t\(.value.pattern)"' <<<"$plugins_json")
  else
    # Grouped: { "Managed": { "name": { "pattern": "..." } }, "Manual": {...} }
    mapfile -t CATEGORIES < <(jq -r 'keys[]' <<<"$plugins_json")

    for category in "${CATEGORIES[@]}"; do
      local src_dir
      src_dir="$(resolve_src_dir "$category" "$engine")" || {
        log_warn "No path definition for category '${category}'. Skipping."
        continue
      }

      while IFS=$'\t' read -r name pattern; do
        [[ -n "$name" ]] || continue
        if link_one_plugin "$name" "$pattern" "$src_dir" "$temp_dir"; then
          ((linked++)) || true
        else
          ((missing++)) || true
        fi
      done < <(jq -r --arg c "$category" '.[$c] | to_entries[] | "\(.key)\t\(.value.pattern)"' <<<"$plugins_json")
    done
  fi

  # Nothing linked → preserve existing
  if [[ $linked -eq 0 ]]; then
    log_warn "No plugins linked for ${server}. Preserving existing."
    rm -rf "$temp_dir" 2>/dev/null || true
    return 0
  fi

  # -------------------------------------------------------------------------
  # Safe apply: only touch jars we manage
  # -------------------------------------------------------------------------
  local backup_dir="${server_dir}/.plugins_backup_$$"
  mkdir -p "$backup_dir"

  # Backup existing managed jars
  shopt -s nullglob
  for f in "${temp_dir}"/*.jar; do
    local jar_name
    jar_name="$(basename "$f")"
    local target="${dest_dir}/${jar_name}"
    [[ -e "$target" || -L "$target" ]] && mv -f "$target" "$backup_dir/" 2>/dev/null || true
  done

  # Apply new jars
  local failed_apply=0
  for f in "${temp_dir}"/*.jar; do
    if ! mv -f "$f" "$dest_dir/"; then
      failed_apply=1
      break
    fi
  done
  shopt -u nullglob

  # Rollback on failure
  if [[ $failed_apply -ne 0 ]]; then
    log_warn "Apply failed for ${server}. Rolling back..."
    shopt -s nullglob
    for b in "$backup_dir"/*.jar; do
      mv -f "$b" "$dest_dir/" 2>/dev/null || true
    done
    shopt -u nullglob
    rm -rf "$backup_dir" 2>/dev/null || true
    rm -rf "$temp_dir" 2>/dev/null || true
    log_err "Failed to apply plugins for ${server}."
    return 1
  fi

  rm -rf "$backup_dir" 2>/dev/null || true
  rm -rf "$temp_dir" 2>/dev/null || true

  if [[ $missing -gt 0 ]]; then
    log_warn "Linked for ${server}, but ${missing} plugin(s) missing."
  else
    log_info "All plugins linked for ${server}."
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

mapfile -t SERVERS < <(jq -r '
    to_entries[]
    | select(.value | type == "object" and has("engine"))
    | .key
' <<<"$RESOLVED")

failures=0

for server in "${SERVERS[@]}"; do
  engine="$(jq -r --arg s "$server" '.[$s].engine' <<<"$RESOLVED")"
  server_dir="${SERVERS_ROOT}/${server}"

  [[ -n "$engine" ]] || {
    log_warn "No engine for ${server}. Skipping."
    continue
  }
  [[ -d "$server_dir" ]] || {
    log_warn "Server dir missing: ${server}. Skipping."
    continue
  }

  log_info "Linking plugins: ${BLUE}${server}${NC} (${engine})"
  if ! link_server_plugins "$server" "$engine" "$server_dir"; then
    ((failures++)) || true
  fi
done

if [[ $failures -gt 0 ]]; then
  log_err "Plugin linking completed with ${failures} server failure(s)."
  exit 1
fi

log_info "Plugin linking complete."
exit 0
