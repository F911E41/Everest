#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Everest - Get Engine (PaperMC Fill API v3)
# ------------------------------------------------------------------------------
# Downloads the latest build for each engine defined in the resolved branch
# of config/update.json. Parallel downloads, atomic writes, safe cleanup.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)"
ROOT_PATH="$(realpath "${SCRIPT_DIR}/../")"

CONFIG_FILE="${ROOT_PATH}/config/update.json"
ENGINE_DIR="${ROOT_PATH}/libraries/engines"

FILL_API="https://fill.papermc.io/v3"

# shellcheck disable=SC2034
LOG_TAG="get-engine"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/modules/library"

# Pre-flight
check_deps jq curl

[[ -f "$CONFIG_FILE" ]] || {
  log_err "Config missing: $CONFIG_FILE"
  exit 1
}
mkdir -p "$ENGINE_DIR"

trap cleanup_jobs EXIT INT TERM

# Resolve branch (use pre-resolved if available)
if [[ -n "${EVEREST_RESOLVED_UPDATE:-}" ]]; then
  RESOLVED="$EVEREST_RESOLVED_UPDATE"
else
  CONFIG="$(cat "$CONFIG_FILE")"
  RESOLVED="$(resolve_branch "$CONFIG")"
fi

# ------------------------------------------------------------------------------
# Engine Processing
# ------------------------------------------------------------------------------

process_engine() {
  local engine="$1" version="$2"
  local project="${engine,,}"
  local tag="${project} (${version})"

  # 1. Fetch version metadata
  local version_url="${FILL_API}/projects/${project}/versions/${version}"
  local version_resp
  version_resp="$(curl_json "$version_url")" || {
    log_err "Failed to fetch version meta: ${tag}"
    return 1
  }

  if jq -e '.ok == false' >/dev/null 2>&1 <<<"$version_resp"; then
    log_err "API error for ${tag}: $(jq -r '.message // "Unknown"' <<<"$version_resp")"
    return 1
  fi

  # 2. Find latest build
  local latest_build
  latest_build="$(jq -r '.builds | max // empty' <<<"$version_resp")"

  if [[ -z "$latest_build" || "$latest_build" == "null" ]]; then
    log_warn "No builds found for ${tag}. Skipping."
    return 0
  fi

  # 3. Fetch build detail
  local build_url="${FILL_API}/projects/${project}/versions/${version}/builds/${latest_build}"
  local build_resp
  build_resp="$(curl_json "$build_url")" || {
    log_err "Failed to fetch build detail: ${tag} (#${latest_build})"
    return 1
  }

  if jq -e '.ok == false' >/dev/null 2>&1 <<<"$build_resp"; then
    log_err "API error for ${tag} (#${latest_build}): $(jq -r '.message // "Unknown"' <<<"$build_resp")"
    return 1
  fi

  local dl_url dl_name
  dl_url="$(jq -r '.downloads."server:default".url // empty' <<<"$build_resp")"
  dl_name="$(jq -r '.downloads."server:default".name // empty' <<<"$build_resp")"

  [[ -n "$dl_url" ]] || {
    log_warn "No download URL for ${tag}. Skipping."
    return 0
  }
  [[ -n "$dl_name" && "$dl_name" != "null" ]] || dl_name="${dl_url##*/}"

  # 4. Up-to-date check
  local target="${ENGINE_DIR}/${dl_name}"
  if [[ -f "$target" ]]; then
    log_info "Up-to-date: ${tag} (#${latest_build}, ${dl_name})"
    return 0
  fi

  # 5. Download (atomic)
  local tmp="${target}.tmp.$$"
  log_info "Downloading: ${dl_name} (#${latest_build})..."

  if curl_download "$dl_url" "$tmp"; then
    mv -f "$tmp" "$target"
    log_info "Downloaded: ${tag} → ${dl_name}"
  else
    rm -f "$tmp"
    log_err "Download failed: ${tag}"
    return 1
  fi

  # 6. Cleanup old builds for same engine+version
  local removed=0
  shopt -s nullglob
  for f in "${ENGINE_DIR}/${project}-${version}-"*.jar; do
    [[ "$(basename "$f")" == "$dl_name" ]] && continue
    rm -f "$f"
    ((removed++)) || true
  done
  shopt -u nullglob
  [[ $removed -gt 0 ]] && log_warn "Removed ${removed} old build(s) for ${tag}"

  return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

log_info "Starting engine updates (Fill API v3)..."

declare -a PIDS=()
failed=0
engine_count=0

# Iterate engines: keys in the resolved branch that have a .version field
while IFS=$'\t' read -r engine version; do
  [[ -n "$engine" && -n "$version" ]] || continue
  process_engine "$engine" "$version" &
  PIDS+=("$!")
  ((engine_count++)) || true
done < <(jq -r 'to_entries[] | select(.value | type == "object" and has("version")) | "\(.key)\t\(.value.version)"' <<<"$RESOLVED")

if [[ $engine_count -eq 0 ]]; then
  log_warn "No engine targets found in resolved update config."
  exit 0
fi

for pid in "${PIDS[@]}"; do
  wait "$pid" || ((failed++)) || true
done

if [[ $failed -gt 0 ]]; then
  log_warn "${failed} engine(s) failed to update."
  exit 1
fi

log_info "Engine updates complete."
exit 0
