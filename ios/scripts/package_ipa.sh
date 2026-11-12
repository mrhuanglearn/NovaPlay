#!/usr/bin/env bash
set -euo pipefail

# Builds NovaPlay (星映) for iOS 15.0+ and packages a 3-in-1 compatible .ipa:
#   1. TrollStore (巨魔) — ad-hoc / ldid pseudo-signed across Runner + all embedded Frameworks
#   2. Personal Apple ID Certificate (爱思助手 / Sideloadly / AltStore / SideStore / ESign) — zero restricted entitlements
#   3. Enterprise Certificate (企业签 / zsign / 轻松签 / 全能签) — standard Payload/Runner.app layout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_APP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${FLUTTER_APP_DIR}"

export NOVAPLAY_WITH_VLC="${NOVAPLAY_WITH_VLC:-1}"
export NOVAPLAY_WITH_MPV="${NOVAPLAY_WITH_MPV:-1}"
VERSION_STR="$(python3 -c '
import pathlib, re
txt = pathlib.Path("pubspec.yaml").read_text(encoding="utf-8")
m = re.search(r"^version:\s*([^\s+]+)", txt, re.M)
print(m.group(1) if m else "0.1.0")
')"

echo "[package_ipa] Step 1/6: Fetching NodeMobile.xcframework..."
bash "${SCRIPT_DIR}/fetch_nodemobile.sh"

echo "[package_ipa] Step 2/6: Preparing NovaMpv.xcframework (NOVAPLAY_WITH_MPV=${NOVAPLAY_WITH_MPV})..."
bash "${SCRIPT_DIR}/fetch_mpvkit.sh"

echo "[package_ipa] Step 3/6: Resolving Dart packages, l10n & iOS Flutter config..."
flutter pub get
flutter gen-l10n
flutter build ios --config-only --release --no-codesign

echo "[package_ipa] Step 4/6: Installing CocoaPods (VLC=${NOVAPLAY_WITH_VLC}, MPV=${NOVAPLAY_WITH_MPV})..."
pushd ios >/dev/null
pod install || pod install --repo-update
popd >/dev/null

echo "[package_ipa] Step 5/6: Building Release Runner.app (--no-codesign, iOS 15.0+)..."
flutter build ios --release --no-codesign

APP_BUNDLE="${FLUTTER_APP_DIR}/build/ios/iphoneos/Runner.app"
if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "[package_ipa] ERROR: Runner.app not found at ${APP_BUNDLE}" >&2
  exit 1
fi

echo "[package_ipa] Step 6/6: Embedding dlopen frameworks, stripping bitcode & signing for TrollStore + Sideload..."
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

mkdir -p "${STAGE_DIR}/Payload"
cp -R "${APP_BUNDLE}" "${STAGE_DIR}/Payload/Runner.app"
PAYLOAD_APP="${STAGE_DIR}/Payload/Runner.app"
mkdir -p "${PAYLOAD_APP}/Frameworks"

# Guarantee dlopen-loaded dynamic frameworks (such as NovaMpv.framework) are embedded in Runner.app/Frameworks
VENDOR_FW_ROOT="${FLUTTER_APP_DIR}/packages/novaplay_ios/ios/Frameworks"
if [[ -d "${VENDOR_FW_ROOT}" ]]; then
  for xcfw in "${VENDOR_FW_ROOT}"/*.xcframework; do
    [[ -d "${xcfw}" ]] || continue
    xcfw_base="$(basename "${xcfw}")"
    if [[ "${xcfw_base}" != "NodeMobile.xcframework" && "${NOVAPLAY_WITH_MPV}" == "0" ]]; then
      continue
    fi
    python3 - "${xcfw}" "${PAYLOAD_APP}/Frameworks" <<'PY'
import pathlib, plistlib, shutil, subprocess, sys

xcfw = pathlib.Path(sys.argv[1])
dest_root = pathlib.Path(sys.argv[2])
plist_path = xcfw / "Info.plist"
if not plist_path.exists():
    sys.exit(0)
with plist_path.open("rb") as fp:
    pl = plistlib.load(fp)
for lib in pl.get("AvailableLibraries", []):
    plat = str(lib.get("SupportedPlatform", "")).lower()
    variant = str(lib.get("SupportedPlatformVariant", "") or "").lower()
    archs = [str(a).lower() for a in lib.get("SupportedArchitectures", [])]
    if plat == "ios" and not variant and "arm64" in archs:
        rel = lib.get("LibraryPath", "")
        if not rel.endswith(".framework"):
            break
        fw_src = xcfw / lib["LibraryIdentifier"] / rel
        fw_bin = fw_src / pathlib.Path(rel).stem
        if not fw_bin.exists():
            break
        desc = subprocess.check_output(["file", "-b", str(fw_bin)], text=True).lower()
        if "dynamically linked shared library" in desc:
            fw_dst = dest_root / pathlib.Path(rel).name
            if not fw_dst.exists():
                shutil.copytree(fw_src, fw_dst, symlinks=True)
                print(f"[package_ipa] Embedded dlopen framework: {fw_dst.name}")
        break
PY
  done
fi

# Strip any bitcode segments in embedded dynamic frameworks so iOS 15-18+ & Xcode 16+ never complain
BITCODE_STRIP="$(xcrun --find bitcode_strip 2>/dev/null || true)"
if [[ -n "${BITCODE_STRIP}" && -d "${PAYLOAD_APP}/Frameworks" ]]; then
  find "${PAYLOAD_APP}/Frameworks" -maxdepth 2 -type f | while read -r bin; do
    if file "${bin}" | grep -q "dynamically linked shared library"; then
      "${BITCODE_STRIP}" "${bin}" -r -o "${bin}" 2>/dev/null || true
    fi
  done
fi

# Sign every embedded framework and dylib first, then sign Runner.app itself (no restricted entitlements)
sign_target() {
  local target="$1"
  if command -v ldid >/dev/null 2>&1; then
    ldid -S "${target}"
  else
    codesign --force --sign - --timestamp=none "${target}"
  fi
}

if [[ -d "${PAYLOAD_APP}/Frameworks" ]]; then
  for fw in "${PAYLOAD_APP}/Frameworks"/*.framework; do
    [[ -e "${fw}" ]] || continue
    sign_target "${fw}"
  done
  for dylib in "${PAYLOAD_APP}/Frameworks"/*.dylib; do
    [[ -e "${dylib}" ]] || continue
    sign_target "${dylib}"
  done
fi
sign_target "${PAYLOAD_APP}"

OUT_DIR="${FLUTTER_APP_DIR}/build/ios/ipa"
mkdir -p "${OUT_DIR}"
SUFFIX=""
if [[ "${NOVAPLAY_WITH_VLC}" == "0" && "${NOVAPLAY_WITH_MPV}" == "0" ]]; then
  SUFFIX="-slim"
fi
IPA_PATH="${OUT_DIR}/novaplay-${VERSION_STR}-ios15-arm64${SUFFIX}.ipa"
rm -f "${IPA_PATH}"

pushd "${STAGE_DIR}" >/dev/null
zip -qry -9 "${IPA_PATH}" Payload
popd >/dev/null

ls -lh "${IPA_PATH}"
echo "[package_ipa] Done: ${IPA_PATH}"
