#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Everest - Get Plugin (Strategy-Driven Plugin Downloader)
# ------------------------------------------------------------------------------
# Downloads plugins using strategy definitions from config/update.json.
# Supported strategies:
#   - Direct   (static)     : Direct URL download
#   - Jenkins  (api)        : Jenkins CI artifact resolution
#   - Github   (api)        : GitHub Releases latest artifact
#   - EngineHub (web-scrape): EngineHub TeamCity builds
#   - Zrips    (web-scrape) : Zrips.net file downloader
#   - Manual   (manual)     : Skip (requires manual download)
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)"
ROOT_PATH="$(realpath "${SCRIPT_DIR}/../")"

CONFIG_FILE="${ROOT_PATH}/config/update.json"
PLUGIN_LIB_ROOT="${ROOT_PATH}/libraries/plugins"

# shellcheck disable=SC2034
LOG_TAG="get-plugin"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/modules/library"

# Pre-flight
check_deps jq curl

[[ -f "$CONFIG_FILE" ]] || {
  log_err "Config missing: $CONFIG_FILE"
  exit 1
}
mkdir -p "$PLUGIN_LIB_ROOT"

# Cleanup tracking
declare -a TEMP_DIRS=()

# shellcheck disable=SC2329
cleanup() {
  local ec=$?
  local pids
  pids="$(jobs -pr 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
  for d in "${TEMP_DIRS[@]}"; do
    [[ -d "$d" ]] && rm -rf "$d"
  done
  exit "$ec"
}

trap cleanup EXIT INT TERM

# Resolve branch (use pre-resolved if available)
if [[ -n "${EVEREST_RESOLVED_UPDATE:-}" ]]; then
  RESOLVED="$EVEREST_RESOLVED_UPDATE"
else
  CONFIG="$(cat "$CONFIG_FILE")"
  RESOLVED="$(resolve_branch "$CONFIG")"
fi

if [[ -n "${EVEREST_STRATEGIES:-}" ]]; then
  STRATEGIES="$EVEREST_STRATEGIES"
else
  STRATEGIES="$(jq '.strategies' "$CONFIG_FILE")"
fi

# ==============================================================================
# Artifact Selection
# ==============================================================================
# Filters artifacts to .jar (excluding sources/javadoc/plain),
# then applies priority regex patterns to pick the best match.
# ==============================================================================

select_artifact() {
  local artifacts="$1" platform="$2"
  shift 2
  local priorities=("$@")

  # Filter: keep .jar, drop sources/javadoc/plain
  local jars
  jars="$(grep -Ei '\.jar$' <<<"$artifacts" |
    grep -viE '(-sources|-javadoc|-plain)\.jar$' || true)"
  [[ -n "$jars" ]] || jars="$artifacts"

  # Apply priority patterns
  for pattern in "${priorities[@]}"; do
    # Strip PCRE-style (?i) flags (not supported by grep -E / POSIX ERE)
    local stripped="${pattern#'(?i)'}"
    local p="${stripped//\{platform\}/$platform}"
    local match
    match="$(grep -Ei "$p" <<<"$jars" | head -n1 || true)"
    [[ -n "$match" ]] && {
      echo "$match"
      return 0
    }
  done

  # Fallback: first artifact
  head -n1 <<<"$jars"
}

# ==============================================================================
# Strategy Resolvers
# ==============================================================================

# --- API-based strategies (Jenkins, GitHub) ---
resolve_api() {
  local platform="$1" name="$2" strategy_json="$3" plugin_json="$4"

  local api_template artifact_filter download_template
  api_template="$(jq -r '.api_template' <<<"$strategy_json")"
  artifact_filter="$(jq -r '.artifact_filter' <<<"$strategy_json")"
  download_template="$(jq -r '.download_template' <<<"$strategy_json")"

  # Extract plugin fields
  local host project owner repo url
  host="$(jq -r '.host // empty' <<<"$plugin_json")"
  project="$(jq -r '.project // empty' <<<"$plugin_json")"
  owner="$(jq -r '.owner // empty' <<<"$plugin_json")"
  repo="$(jq -r '.repo // empty' <<<"$plugin_json")"
  url="$(jq -r '.url // empty' <<<"$plugin_json")"

  # Jenkins path fix: projects with "/" are full paths, don't prefix /job/
  local tmpl_api="$api_template"
  local tmpl_dl="$download_template"
  if [[ -n "$project" && "$project" == */* ]]; then
    tmpl_api="${tmpl_api//\/job\/\{project\}/\/\{project\}}"
    tmpl_dl="${tmpl_dl//\/job\/\{project\}/\/\{project\}}"
  fi

  # Build API URL
  local api_url
  api_url="$(interpolate "$tmpl_api" \
    host "$host" project "$project" owner "$owner" repo "$repo" \
    url "$url" platform "$platform")"

  # Fetch API
  local response
  response="$(curl_json "$api_url")" || {
    log_err "API fetch failed for ${name}: ${api_url}"
    return 1
  }

  # Extract artifacts with jq filter
  local artifacts
  artifacts="$(jq -r "$artifact_filter" <<<"$response" || true)"
  [[ -n "$artifacts" ]] || {
    log_err "No artifacts for ${name}"
    return 1
  }

  # Read priority array
  local -a priorities=()
  while IFS= read -r p; do
    priorities+=("$p")
  done < <(jq -r '.priority[]? // empty' <<<"$strategy_json")

  # Select best artifact
  local selected
  selected="$(select_artifact "$artifacts" "$platform" "${priorities[@]}")"
  [[ -n "$selected" ]] || {
    log_err "No matching artifact for ${name}"
    return 1
  }

  # Build download URL
  interpolate "$tmpl_dl" \
    artifact "$selected" host "$host" project "$project" \
    owner "$owner" repo "$repo" url "$url" platform "$platform"
}

# --- EngineHub: TeamCity HTML scrape at builds.enginehub.org ---
resolve_enginehub() {
  local platform="$1" name="$2" plugin_json="$3"

  local project
  project="$(jq -r '.project // empty' <<<"$plugin_json")"
  [[ -n "$project" ]] || {
    log_err "No project for EngineHub: ${name}"
    return 1
  }

  # Build page URL; use optional branch from config, otherwise let
  # EngineHub resolve the project's default branch automatically.
  local branch
  branch="$(jq -r '.branch // empty' <<<"$plugin_json")"
  local page_url="https://builds.enginehub.org/job/${project,,}/last-successful"
  [[ -n "$branch" ]] && page_url+="?branch=${branch}"

  local html
  html="$(curl_html "$page_url")" || {
    log_err "EngineHub fetch failed: ${name}"
    return 1
  }

  # Extract jar download URLs from TeamCity CI links
  local jars
  jars="$(echo "$html" |
    grep -Eo 'https://ci\.enginehub\.org/repository/download/[^"]+\.jar[^"]*' || true)"
  [[ -n "$jars" ]] || {
    log_err "No jars found on EngineHub for ${name}"
    return 1
  }

  # Platform-aware selection
  local selected=""
  if [[ "$platform" == "velocity" ]]; then
    selected="$(grep -Ei 'velocity' <<<"$jars" | head -n1 || true)"
  else
    selected="$(grep -Ei 'bukkit' <<<"$jars" | head -n1 || true)"
    [[ -z "$selected" ]] && selected="$(grep -Ei 'paper' <<<"$jars" | head -n1 || true)"
  fi
  [[ -z "$selected" ]] && selected="$(head -n1 <<<"$jars")"

  # Decode HTML entities (bash ${//} cannot match literal ';' in patterns)
  echo "$selected" | sed 's/&amp;/\&/g'
}

# --- Zrips: scrape zrips.net download page ---
# Supports two link patterns found on zrips.net:
#   A) download.php?file=XXX.jar  — relative links (cmiv, cmivault)
#   B) Direct absolute/relative .jar URLs (cmilib)
# Plugin config may specify either 'project' (slug) or 'url' (full page URL).
resolve_zrips() {
  local name="$1" plugin_json="$2"

  # Derive page URL from 'url' or 'project' field
  local page_url=""
  local url project
  url="$(jq -r '.url // empty' <<<"$plugin_json")"
  project="$(jq -r '.project // empty' <<<"$plugin_json")"

  if [[ -n "$url" ]]; then
    page_url="$url"
    # Ensure trailing slash
    [[ "$page_url" == */ ]] || page_url="${page_url}/"
  elif [[ -n "$project" ]]; then
    page_url="https://www.zrips.net/${project}/"
  else
    log_err "No url or project for Zrips: ${name}"
    return 1
  fi

  local html
  html="$(curl_html "$page_url")" || {
    log_err "Zrips fetch failed: ${name}"
    return 1
  }

  # Pattern A: download.php?file=XXX.jar (cmiv, cmivault)
  local jar_link
  jar_link="$(echo "$html" |
    grep -oEi 'href="download\.php[?]file=[^"]*\.jar"' |
    head -n1 | sed 's/href="//;s/"$//' || true)"
  if [[ -n "$jar_link" ]]; then
    echo "${page_url}${jar_link}"
    return 0
  fi

  # Pattern B: direct .jar links — absolute or relative (cmilib)
  jar_link="$(echo "$html" |
    grep -oEi 'href="[^"]*\.jar"' |
    head -n1 | sed 's/href="//;s/"$//' || true)"
  if [[ -n "$jar_link" ]]; then
    if [[ "$jar_link" == http* ]]; then
      echo "$jar_link"
    elif [[ "$jar_link" == /* ]]; then
      echo "https://www.zrips.net${jar_link}"
    else
      echo "${page_url}${jar_link}"
    fi
    return 0
  fi

  log_err "No jar found on Zrips for ${name}"
  return 1
}

# ==============================================================================
# Main Download Logic
# ==============================================================================

download_plugin() {
  local platform="$1" name="$2" plugin_json="$3" dest_dir="$4" fallback_dir="$5"
  local tag="${name} (${platform})"

  # Determine strategy
  local strategy_name
  strategy_name="$(jq -r '.strategy' <<<"$plugin_json")"
  [[ -n "$strategy_name" && "$strategy_name" != "null" ]] || {
    log_warn "No strategy defined for ${tag}. Skipping."
    return 0
  }

  local strategy_json
  strategy_json="$(jq --arg s "$strategy_name" '.[$s]' <<<"$STRATEGIES")"
  if [[ -z "$strategy_json" || "$strategy_json" == "null" ]]; then
    log_err "Unknown strategy '${strategy_name}' for ${tag}"
    return 1
  fi

  local strategy_type
  strategy_type="$(jq -r '.type' <<<"$strategy_json")"

  # Manual: preserve existing, log update URL
  if [[ "$strategy_type" == "manual" ]]; then
    local manual_url
    manual_url="$(jq -r '.url // empty' <<<"$plugin_json")"
    log_warn "Manual download required: ${tag}"
    [[ -n "$manual_url" ]] && log_warn "  → ${manual_url}"

    try_fallback "$name" "$tag" "$fallback_dir" "$dest_dir" || true
    return 0
  fi

  # Resolve download URL based on strategy type
  local resolved_url=""

  case "$strategy_type" in
  static)
    resolved_url="$(interpolate "$(jq -r '.download_template' <<<"$strategy_json")" \
      url "$(jq -r '.url // empty' <<<"$plugin_json")" \
      platform "$platform")"
    ;;
  api)
    resolved_url="$(resolve_api "$platform" "$name" "$strategy_json" "$plugin_json")" || resolved_url=""
    ;;
  web-scrape)
    case "$strategy_name" in
    EngineHub) resolved_url="$(resolve_enginehub "$platform" "$name" "$plugin_json")" || resolved_url="" ;;
    Zrips) resolved_url="$(resolve_zrips "$name" "$plugin_json")" || resolved_url="" ;;
    *)
      log_err "Unsupported web-scrape strategy: ${strategy_name}"
      return 1
      ;;
    esac
    ;;
  *)
    log_err "Unknown strategy type '${strategy_type}' for ${tag}"
    return 1
    ;;
  esac

  # Resolution failure → fallback
  if [[ -z "$resolved_url" ]]; then
    log_err "Failed to resolve URL for ${tag}"
    try_fallback "$name" "$tag" "$fallback_dir" "$dest_dir" && return 0
    return 1
  fi

  # Determine filename
  local filename
  filename="$(basename "${resolved_url%%\?*}")"
  [[ "$filename" == *.jar ]] || filename="${name}.jar"

  local target="${dest_dir}/${filename}"
  local tmp="${target}.tmp.$$"

  log_info "Downloading: ${tag} → ${filename}..."

  if curl_download "$resolved_url" "$tmp"; then
    mv -f "$tmp" "$target"
    log_info "Downloaded: ${tag} → ${filename}"
    return 0
  fi

  rm -f "$tmp"
  log_warn "Download failed for ${tag}. Trying fallback..."

  # Download failure → fallback
  try_fallback "$name" "$tag" "$fallback_dir" "$dest_dir" && return 0

  log_err "No fallback available for ${tag}"
  return 1
}

# ==============================================================================
# Main
# ==============================================================================

log_info "Starting plugin updates..."
overall_failed=0

# Iterate platforms (keys in resolved branch that have .plugins)
mapfile -t PLATFORMS < <(jq -r '
    to_entries[]
    | select(.value | type == "object" and has("plugins"))
    | .key
' <<<"$RESOLVED")

if [[ ${#PLATFORMS[@]} -eq 0 ]]; then
  log_warn "No plugin targets found in resolved update config."
  exit 0
fi

for platform in "${PLATFORMS[@]}"; do
  log_info "Processing platform: ${CYAN}${platform}${NC}"

  PLATFORM_ROOT="${PLUGIN_LIB_ROOT}/${platform}"
  TARGET_DIR="${PLATFORM_ROOT}/Managed"
  mkdir -p "$PLATFORM_ROOT"

  # Create temp dir for atomic swap
  TEMP_DIR="$(mktemp -d -p "$PLATFORM_ROOT" ".tmp_managed_XXXXXX")"
  TEMP_DIRS+=("$TEMP_DIR")

  declare -a pids=()

  # Iterate plugins for this platform
  while IFS=$'\t' read -r name plugin_json; do
    [[ -n "$name" ]] || continue
    download_plugin "$platform" "$name" "$plugin_json" "$TEMP_DIR" "$TARGET_DIR" &
    pids+=("$!")
  done < <(jq -r --arg p "$platform" '
        .[$p].plugins // {}
        | to_entries[]
        | "\(.key)\t\(.value | tostring)"
    ' <<<"$RESOLVED")

  # Wait for all downloads
  failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || ((failed++)) || true
  done

  # Check results
  if [[ -z "$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    [[ $failed -gt 0 ]] && ((overall_failed++)) || true
    log_warn "No plugins downloaded for ${platform}. Preserving existing Managed dir."
    rm -rf "$TEMP_DIR"
    continue
  fi

  if [[ $failed -gt 0 ]]; then
    ((overall_failed++)) || true
    log_err "${platform}: ${failed} plugin(s) failed. Preserving existing Managed dir."
    rm -rf "$TEMP_DIR"
    continue
  fi

  # Atomic swap: temp → Managed
  log_info "Swapping Managed directory for ${platform}..."
  if ! atomic_swap "$TEMP_DIR" "$TARGET_DIR"; then
    ((overall_failed++)) || true
    log_err "Failed to swap Managed directory for ${platform}. Preserving existing."
    rm -rf "$TEMP_DIR"
    continue
  fi

  # Remove from cleanup tracking (already moved)
  declare -a new_tmp=()
  for d in "${TEMP_DIRS[@]}"; do
    [[ "$d" == "$TEMP_DIR" ]] && continue
    new_tmp+=("$d")
  done
  TEMP_DIRS=("${new_tmp[@]}")

  log_info "All plugins updated for ${platform}."
done

if [[ $overall_failed -gt 0 ]]; then
  log_err "Plugin updates completed with ${overall_failed} platform failure(s)."
  exit 1
fi

log_info "Plugin updates complete."
exit 0
