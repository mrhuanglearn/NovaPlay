#!/usr/bin/env bash
set -euo pipefail

# Downloads Node.js for Mobile Apps (v18.20.4 iOS arm64 + simulator) and prepares
# packages/novaplay_ios/ios/Frameworks/NodeMobile.xcframework.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_APP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_FW_DIR="${FLUTTER_APP_DIR}/packages/novaplay_ios/ios/Frameworks"
TARGET_XCFW="${TARGET_FW_DIR}/NodeMobile.xcframework"
NODE_MOBILE_TAG="${NODE_MOBILE_TAG:-v18.20.4}"

if [[ -d "${TARGET_XCFW}" ]]; then
  echo "[fetch_nodemobile] NodeMobile.xcframework already present at ${TARGET_XCFW}"
  exit 0
fi

mkdir -p "${TARGET_FW_DIR}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "[fetch_nodemobile] Resolving nodejs-mobile ${NODE_MOBILE_TAG} iOS asset..."
API_URL="https://api.github.com/repos/nodejs-mobile/nodejs-mobile/releases/tags/${NODE_MOBILE_TAG}"

CURL_HEADERS=(-H "Accept: application/vnd.github+json")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CURL_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

DOWNLOAD_URL="$(
  curl -fsSL "${CURL_HEADERS[@]}" "${API_URL}" \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    name = asset.get("name", "").lower()
    if "ios" in name and name.endswith(".zip"):
        print(asset["browser_download_url"])
        sys.exit(0)
' || true
)"

if [[ -z "${DOWNLOAD_URL}" ]]; then
  DOWNLOAD_URL="https://github.com/nodejs-mobile/nodejs-mobile/releases/download/${NODE_MOBILE_TAG}/nodejs-mobile-${NODE_MOBILE_TAG}-ios.zip"
fi

echo "[fetch_nodemobile] Downloading ${DOWNLOAD_URL} ..."
ZIP_PATH="${WORK_DIR}/nodemobile-ios.zip"
curl -fL --retry 3 --retry-delay 2 -o "${ZIP_PATH}" "${DOWNLOAD_URL}"

EXTRACT_DIR="${WORK_DIR}/extracted"
mkdir -p "${EXTRACT_DIR}"
unzip -q "${ZIP_PATH}" -d "${EXTRACT_DIR}"

FOUND_XCFW="$(find "${EXTRACT_DIR}" -maxdepth 4 -type d -name "NodeMobile.xcframework" | head -n 1 || true)"
if [[ -n "${FOUND_XCFW}" ]]; then
  cp -R "${FOUND_XCFW}" "${TARGET_XCFW}"
  echo "[fetch_nodemobile] Installed ${TARGET_XCFW}"
  exit 0
fi

# Otherwise wrap discovered NodeMobile.framework slice(s) into an XCFramework (compatible with macOS Bash 3.2)
FOUND_FWS=()
while IFS= read -r fw; do
  [[ -n "${fw}" ]] && FOUND_FWS+=("${fw}")
done < <(find "${EXTRACT_DIR}" -maxdepth 5 -type d -name "NodeMobile.framework")
if [[ "${#FOUND_FWS[@]}" -eq 0 ]]; then
  echo "[fetch_nodemobile] ERROR: Neither NodeMobile.xcframework nor NodeMobile.framework found in archive." >&2
  exit 1
fi

XCFW_ARGS=()
for fw in "${FOUND_FWS[@]}"; do
  XCFW_ARGS+=(-framework "${fw}")
done

xcodebuild -create-xcframework "${XCFW_ARGS[@]}" -output "${TARGET_XCFW}"
echo "[fetch_nodemobile] Created XCFramework at ${TARGET_XCFW}"
