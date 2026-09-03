#!/usr/bin/env bash
set -euo pipefail

SNAPO_DIR=""
CANDIDATE=""
MAC_BASE=""
ANDROID_BASE=""
SOURCE_REF="HEAD"

usage() {
  printf '%s\n' \
    'Usage: release/preflight.sh --snapo-dir PATH [--ref REF] [--candidate VERSION] [--mac-base TAG] [--android-base TAG]' \
    '' \
    'Inspect Snap-O release state without modifying a checkout or triggering a workflow.'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapo-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SNAPO_DIR="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SOURCE_REF="$2"
      shift 2
      ;;
    --candidate)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      CANDIDATE="$2"
      shift 2
      ;;
    --mac-base)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      MAC_BASE="$2"
      shift 2
      ;;
    --android-base)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ANDROID_BASE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$SNAPO_DIR" ]] || {
  printf '%s\n' '--snapo-dir is required; pass the path to an openai/snap-o checkout.' >&2
  usage >&2
  exit 2
}

for command_name in git gh awk sed sort tr; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

gh auth status >/dev/null 2>&1 || {
  printf '%s\n' 'GitHub CLI is not authenticated. Run: gh auth login' >&2
  exit 1
}

resolved_snapo_dir="$(git -C "$SNAPO_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$resolved_snapo_dir" ]] || {
  printf 'Snap-O checkout not found: %s\n' "$SNAPO_DIR" >&2
  exit 1
}
SNAPO_DIR="$resolved_snapo_dir"

origin_url="$(git -C "$SNAPO_DIR" remote get-url origin 2>/dev/null || true)"
[[ "$origin_url" == *openai/snap-o* ]] || {
  printf 'Expected openai/snap-o origin, got: %s\n' "${origin_url:-<none>}" >&2
  exit 1
}

read_value() {
  local key="$1"
  local content="$2"
  awk -F '=' -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      gsub(/[[:space:]]/, "", $2)
      print $2
      exit
    }
  ' <<< "$content"
}

local_version_file=""
if [[ -f "$SNAPO_DIR/VERSION" ]]; then
  local_version_file="$(<"$SNAPO_DIR/VERSION")"
fi
local_version="$(read_value VERSION "$local_version_file")"
local_build="$(read_value BUILD_NUMBER "$local_version_file")"
source_sha="$(git -C "$SNAPO_DIR" rev-parse --verify --end-of-options "$SOURCE_REF^{commit}")"
source_version_file="$(git -C "$SNAPO_DIR" show "$source_sha:VERSION")"
source_version="$(read_value VERSION "$source_version_file")"
source_build="$(read_value BUILD_NUMBER "$source_version_file")"
[[ "$source_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'VERSION at %s must use MAJOR.MINOR.PATCH.\n' "$source_sha" >&2
  exit 1
}
[[ "$source_build" =~ ^[0-9]{8}\.[0-9]{2}$ ]] || {
  printf 'BUILD_NUMBER at %s must use YYYYMMDD.NN.\n' "$source_sha" >&2
  exit 1
}

if [[ -z "$CANDIDATE" ]]; then
  CANDIDATE="$source_version"
fi
[[ "$CANDIDATE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Candidate must use MAJOR.MINOR.PATCH: %s\n' "$CANDIDATE" >&2
  exit 2
}

remote_tags="$(git ls-remote --tags "$origin_url" 'refs/tags/*')"
latest_tag="$(awk '
  {
    tag = $2
    sub("refs/tags/", "", tag)
    if (tag ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print tag
  }
' <<< "$remote_tags" | sort -V | tail -n 1)"
candidate_tag_sha="$(awk -v tag="refs/tags/$CANDIDATE" '
  $2 == tag { direct = $1 }
  $2 == tag "^{}" { peeled = $1 }
  END { print peeled ? peeled : direct }
' <<< "$remote_tags")"

mac_metadata="$(gh api repos/openai/snap-o/releases/latest \
  --jq '[.tag_name, .published_at, .html_url] | @tsv')"
IFS=$'\t' read -r latest_mac_tag latest_mac_published latest_mac_url <<< "$mac_metadata"
if [[ -z "$MAC_BASE" ]]; then
  MAC_BASE="$latest_mac_tag"
fi

appcast="$(gh api -H 'Accept: application/vnd.github.raw+json' \
  '/repos/openai/snap-o/contents/appcast.xml?ref=gh-pages')"
appcast_version="$(sed -n 's#.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*#\1#p' <<< "$appcast" | sed -n '1p')"
appcast_build="$(sed -n 's#.*<sparkle:version>\([^<]*\)</sparkle:version>.*#\1#p' <<< "$appcast" | sed -n '1p')"

printf '%s\n' 'Snap-O release preflight'
printf '%s\n' '========================'
printf 'Checkout:             %s\n' "$SNAPO_DIR"
printf 'Checkout branch:      %s\n' "$(git -C "$SNAPO_DIR" branch --show-current)"
printf 'Checkout HEAD:        %s\n' "$(git -C "$SNAPO_DIR" rev-parse HEAD)"
printf 'Compared source:      %s (%s)\n' "$source_sha" "$SOURCE_REF"
printf 'Local VERSION/build:  %s / %s\n' "${local_version:-<missing>}" "${local_build:-<missing>}"
printf 'Source VERSION/build: %s / %s\n' "$source_version" "$source_build"
printf 'Latest stable tag:    %s\n' "${latest_tag:-<none>}"
printf 'Candidate:            %s\n' "$CANDIDATE"
if [[ -n "$candidate_tag_sha" ]]; then
  printf 'Candidate tag:        exists at %s\n' "$candidate_tag_sha"
else
  printf '%s\n' 'Candidate tag:        does not exist'
fi
printf 'Latest mac release:   %s (%s)\n' "$latest_mac_tag" "$latest_mac_published"
printf 'Mac release URL:      %s\n' "$latest_mac_url"
printf 'Appcast top item:     %s / %s\n' "${appcast_version:-<missing>}" "${appcast_build:-<missing>}"
printf 'Mac notes base:       %s\n' "$MAC_BASE"
if [[ -n "$ANDROID_BASE" ]]; then
  printf 'Android public base:    %s\n' "$ANDROID_BASE"
else
  printf '%s\n' 'Android public base:    <required; verify public Maven versions and pass --android-base>'
fi
printf '%s\n' ''
printf '%s\n' 'Checkout status:'
checkout_status="$(git -C "$SNAPO_DIR" status --short --branch)"
printf '%s\n' "$checkout_status"

printf '%s\n' ''
printf '%s\n' 'Latest macOS release assets:'
gh api repos/openai/snap-o/releases/latest \
  --jq '.assets[] | "  \(.name)  \(.size) bytes  \(.browser_download_url)"'

print_source_changes() {
  local label="$1"
  local base="$2"
  local changed_files

  [[ -n "$base" ]] || return 0
  printf '\nChanged files since %s base %s:\n' "$label" "$base"
  if ! git -C "$SNAPO_DIR" cat-file -e "$base^{commit}" 2>/dev/null; then
    printf '%s\n' '  Base is not available locally; fetch the missing ref first.'
    return
  fi
  changed_files="$(git -C "$SNAPO_DIR" diff --name-status "$base" "$source_sha")"
  if [[ -n "$changed_files" ]]; then
    sed 's/^/  /' <<< "$changed_files"
  else
    printf '%s\n' '  none'
  fi
}

print_source_changes 'macOS' "$MAC_BASE"
print_source_changes 'Android' "$ANDROID_BASE"

printf '%s\n' ''
printf '%s\n' 'Protocol review evidence (source: selected commit, not working-tree edits):'
printf '%s\n' 'Verify --android-base against public Maven metadata and artifacts; a tag alone does not prove publication.'

print_protocol_declaration() {
  local ref="$1"
  local label="$2"
  local pattern="$3"
  local path="$4"
  local declarations

  printf '    %s:\n' "$label"
  if declarations="$(git -C "$SNAPO_DIR" grep -n -E "$pattern" "$ref" -- "$path")"; then
    sed 's/^/      /' <<< "$declarations"
  else
    printf '      UNRESOLVED: %s not found in %s; locate the missing or changed definition.\n' "$label" "$path"
  fi
}

print_android_protocol_declarations() {
  print_protocol_declaration "$1" 'Android Network protocol version' \
    'const val NetworkProtocolVersion[[:space:]:=]' \
    'snapo-link-android/network/src/main/java/com/openai/snapo/network/SnapOProtocol.kt'
  print_protocol_declaration "$1" 'Android Tweaks protocol version' \
    'const val TweaksProtocolVersion[[:space:]:=]' \
    'snapo-link-android/tweaks/src/main/java/com/openai/snapo/tweaks/internal/TweakHttpServer.kt'
}

print_client_protocol_declarations() {
  print_protocol_declaration "$1" 'Swift Network supported version' \
    'static let supportedVersion[[:space:]:=]' \
    'snapo-app-mac/SnapODeviceClient/Sources/SnapODeviceClient/NetworkProtocol.swift'
  print_protocol_declaration "$1" 'Web Network supported version' \
    'const supportedProtocolVersion[[:space:]:=]' \
    'snapo-network-inspector-web/src/features/network-inspector/lib/protocol.ts'
  print_protocol_declaration "$1" 'Web Tweaks modified-state/reset feature threshold' \
    'const modifiedTweakProtocolVersion[[:space:]:=]' \
    'snapo-network-inspector-web/src/features/tweaks-inspector/TweaksInspectorApp.tsx'
  print_protocol_declaration "$1" 'CLI Tweaks minimum-version checks' \
    'protocol_version[[:space:]]*<[[:space:]]*[0-9]+' \
    'scripts/snapo'
  print_protocol_declaration "$1" 'CLI Tweaks explicit-reset feature threshold' \
    'explicit_resets[[:space:]]*=[[:space:]]*protocol_version[[:space:]]*>=[[:space:]]*[0-9]+' \
    'scripts/snapo'
}

print_protocol_evidence() {
  local label="$1"
  local base="$2"
  local report_declarations="$3"
  shift 3
  local ref
  local changed_files

  printf '\n%s protocol comparison: %s -> %s\n' "$label" "${base:-<missing>}" "$source_sha"
  if [[ -z "$base" ]] || ! git -C "$SNAPO_DIR" cat-file -e "$base^{commit}" 2>/dev/null || \
    ! git -C "$SNAPO_DIR" cat-file -e "$source_sha^{commit}" 2>/dev/null; then
    printf '%s\n' '  UNRESOLVED: supply the public base and fetch missing refs before review.'
    return
  fi

  for ref in "$base" "$source_sha"; do
    printf '  Protocol versions and feature thresholds at %s:\n' "$ref"
    "$report_declarations" "$ref"
  done

  changed_files="$(git -C "$SNAPO_DIR" diff --name-status "$base" "$source_sha" -- "$@")"
  if [[ -n "$changed_files" ]]; then
    printf '%s\n' '  Paths to review for wire API or compatibility changes:'
    sed 's/^/    /' <<< "$changed_files"
    printf '%s\n' '  REVIEW REQUIRED: classify changes and justify the protocol version decision.'
  else
    printf '%s\n' '  No changes in these paths; confirm public baselines and check for moved protocol code.'
  fi
}

print_protocol_evidence 'Android servers' "$ANDROID_BASE" \
  print_android_protocol_declarations \
  contracts snapo-link-android
print_protocol_evidence 'Mac/web/CLI clients' "$MAC_BASE" \
  print_client_protocol_declarations \
  contracts snapo-app-mac/SnapODeviceClient snapo-app-mac/Snap-O/NetworkInspector \
  snapo-network-inspector-web scripts
printf '%s\n' 'Protocol review must be recorded for this source SHA before the version bump; this report does not approve compatibility.'

printf '%s\n' ''
printf '%s\n' 'Recent source CI runs (confirm results cover the selected commit):'
gh run list --repo openai/snap-o --branch main --limit 12 \
  --json createdAt,workflowName,displayTitle,status,conclusion,headSha,url \
  --jq '.[] | "  \(.workflowName)  \(.status)/\(.conclusion)  \(.headSha[0:12])  \(.displayTitle)"'

printf '%s\n' ''
if [[ "$latest_mac_tag" != "$appcast_version" ]]; then
  printf 'Warning: latest macOS release (%s) and appcast top item (%s) differ.\n' \
    "$latest_mac_tag" "${appcast_version:-<missing>}"
fi
if [[ -n "$appcast_build" ]] && \
  [[ "$(printf '%s\n%s\n' "$appcast_build" "$source_build" | sort -V | tail -n 1)" != "$source_build" || "$appcast_build" == "$source_build" ]]; then
  printf 'Warning: source BUILD_NUMBER (%s) is not newer than the appcast build (%s).\n' \
    "$source_build" "$appcast_build"
fi
if [[ -n "$candidate_tag_sha" && "$candidate_tag_sha" != "$source_sha" ]]; then
  printf 'Warning: candidate tag %s already exists and does not point at the selected source. Do not move it.\n' "$CANDIDATE"
fi
printf '%s\n' 'Preflight complete. No files, tags, releases, or workflows were modified.'
