#!/usr/bin/env bash
# Uploads a ZipTop release (Windows installer, Linux AppImage, macOS DMG) to
# the ZipStreams web app, where signed-in users can download it.
#
# For each base URL in ZIPSTREAMS_URL (one or more, separated by whitespace):
# 1. POST {base}/api/releases/ziptop/{version}/{windows,linux,macos}, one
#    file per request (nginx and Cloudflare cap a request body at 100 MB).
# 2. Compares the sha256 the server reports with the local file's.
# 3. POST {base}/api/releases/ziptop/{version}/publish. Publishing the same
#    version again is allowed, so a failed run can simply be re-run.
#
# Environment:
#   ZIPSTREAMS_URL           base URL(s), e.g. https://example.com
#   ZIPSTREAMS_UPLOAD_TOKEN  API token with the upload_release scope
#
# Usage: tool/upload_to_webapp.sh <version> <dist-dir>
# The version is plain X.Y.Z. The dist dir holds the files under the names
# the release job publishes. CI runs this from the webapp job in
# .github/workflows/build-installer.yml.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <version> <dist-dir>" >&2
  exit 2
fi
version="$1"
dist="$2"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Version must be plain X.Y.Z, got '$version'." >&2
  exit 2
fi

urls=()
read -r -d '' -a urls <<<"${ZIPSTREAMS_URL:-}" || true
if [[ ${#urls[@]} -eq 0 || -z "${ZIPSTREAMS_UPLOAD_TOKEN:-}" ]]; then
  echo "::error::ZIPSTREAMS_URL and ZIPSTREAMS_UPLOAD_TOKEN must both be set." >&2
  exit 2
fi

# platform -> file name, in upload order.
platforms=(windows linux macos)
declare -A files=(
  [windows]="ZipTop-Setup-$version.exe"
  [linux]="ZipTop-$version-x86_64.AppImage"
  [macos]="ZipTop-$version-macos-arm64.dmg"
)

declare -A local_sha=()
for platform in "${platforms[@]}"; do
  path="$dist/${files[$platform]}"
  if [[ ! -f "$path" ]]; then
    echo "::error::Missing $path." >&2
    exit 1
  fi
  local_sha[$platform]="$(sha256sum "$path" | cut -d' ' -f1)"
done

# The token goes to curl on stdin (-H @-), so it never shows in the process
# list or in this script's output.
auth_header="Authorization: Bearer $ZIPSTREAMS_UPLOAD_TOKEN"

# The response body goes to a file rather than stdout: curl starts a file
# afresh on each retry, while on stdout every attempt's body piles up.
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

# api <url> [curl args...]: POSTs and prints the response body. On an HTTP
# error, prints the body the server sent and fails.
api() {
  local url="$1"
  shift
  : >"$body_file"
  if ! curl --silent --show-error --fail-with-body \
      --retry 3 --retry-all-errors \
      --request POST -H @- --output "$body_file" "$@" "$url" \
      <<<"$auth_header"; then
    echo "::error::POST $url failed: $(cat "$body_file")" >&2
    return 1
  fi
  cat "$body_file"
}

for base in "${urls[@]}"; do
  base="${base%/}"
  echo "Uploading ZipTop $version to $base"

  for platform in "${platforms[@]}"; do
    name="${files[$platform]}"
    path="$dist/$name"
    response="$(api "$base/api/releases/ziptop/$version/$platform" \
      -F "file=@$path")"

    if ! remote_sha="$(jq -er '.sha256' <<<"$response")"; then
      echo "::error::$platform upload to $base returned no sha256: $response" >&2
      exit 1
    fi
    if [[ "$remote_sha" != "${local_sha[$platform]}" ]]; then
      echo "::error::$name on $base has sha256 $remote_sha, expected ${local_sha[$platform]}." >&2
      exit 1
    fi
    echo "  $platform: $name ($remote_sha)"
  done

  api "$base/api/releases/ziptop/$version/publish" >/dev/null
  echo "  published"
done
