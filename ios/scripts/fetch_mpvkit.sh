#!/usr/bin/env bash
set -euo pipefail

# Resolves prebuilt iOS arm64 libmpv + FFmpeg + MoltenVK + libass + libplacebo XCFrameworks
# from mpvkit/MPVKit (via SwiftPM `swift package dump-package` manifest evaluation) and links
# an isolated dynamic framework `NovaMpv.xcframework` (`@rpath/NovaMpv.framework/NovaMpv`)
# exporting ONLY `_mpv_*` and `_vk*` symbols so zero FFmpeg/libass/crypto symbols collide with
# MobileVLCKit or NodeMobile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_APP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_FW_DIR="${FLUTTER_APP_DIR}/packages/novaplay_ios/ios/Frameworks"
TARGET_XCFW="${TARGET_FW_DIR}/NovaMpv.xcframework"
NOVAPLAY_WITH_MPV="${NOVAPLAY_WITH_MPV:-1}"

if [[ "${NOVAPLAY_WITH_MPV}" == "0" ]]; then
  echo "[fetch_mpvkit] NOVAPLAY_WITH_MPV=0; skipping NovaMpv.xcframework setup."
  exit 0
fi

if [[ -d "${TARGET_XCFW}" ]] && find "${TARGET_XCFW}" -name "NovaMpv" -type f | grep -q .; then
  echo "[fetch_mpvkit] NovaMpv.xcframework already present at ${TARGET_XCFW}"
  exit 0
fi
if [[ -d "${TARGET_FW_DIR}/Libmpv.xcframework" ]] && find "${TARGET_FW_DIR}/Libmpv.xcframework" -name "Libmpv" -type f | grep -q .; then
  echo "[fetch_mpvkit] Libmpv.xcframework already present at ${TARGET_FW_DIR}/Libmpv.xcframework"
  exit 0
fi

mkdir -p "${TARGET_FW_DIR}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

python3 - "${WORK_DIR}" "${TARGET_FW_DIR}" <<'PY'
import concurrent.futures
import json
import os
import pathlib
import plistlib
import re
import shutil
import struct
import subprocess
import sys

work_dir = pathlib.Path(sys.argv[1])
target_fw_dir = pathlib.Path(sys.argv[2])
mpvkit_repo = os.environ.get("MPVKIT_REPO", "https://github.com/mpvkit/MPVKit.git")
mpvkit_tag = os.environ.get("MPVKIT_TAG", "").strip()
use_gpl = os.environ.get("MPVKIT_GPL", "0").strip() == "1"
root_product = "MPVKit-GPL" if use_gpl else "MPVKit"


def run(cmd, cwd=None, check=True, capture=True):
    try:
        res = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            check=check,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
        return res.stdout if capture else ""
    except subprocess.CalledProcessError as exc:
        print(f"[fetch_mpvkit] Command failed (exit {exc.returncode}): {' '.join(cmd)}", file=sys.stderr, flush=True)
        if exc.stdout:
            print(f"[fetch_mpvkit] stdout:\n{exc.stdout}", file=sys.stderr, flush=True)
        if exc.stderr:
            print(f"[fetch_mpvkit] stderr:\n{exc.stderr}", file=sys.stderr, flush=True)
        raise


def parse_semver(tag_str):
    s = tag_str.lstrip("vV")
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", s)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), s)


def pick_remote_tag(url, lower_bound=None, upper_bound=None):
    try:
        out = run(["git", "ls-remote", "--tags", "--refs", url])
    except Exception:
        return None
    lo = parse_semver(lower_bound)[:3] if (lower_bound and parse_semver(lower_bound)) else None
    hi = parse_semver(upper_bound)[:3] if (upper_bound and parse_semver(upper_bound)) else None
    candidates = []
    for line in out.splitlines():
        parts = line.strip().split()
        if len(parts) < 2 or not parts[1].startswith("refs/tags/"):
            continue
        raw_tag = parts[1][len("refs/tags/"):]
        sv = parse_semver(raw_tag)
        if not sv:
            continue
        ver = sv[:3]
        if lo and ver < lo:
            continue
        if hi and ver >= hi:
            continue
        candidates.append((ver, raw_tag))
    if not candidates:
        return None
    candidates.sort()
    return candidates[-1][1]


def pkg_identity(url):
    tail = url.rstrip("/").split("/")[-1]
    if tail.endswith(".git"):
        tail = tail[:-4]
    return tail.lower()


packages = {}  # identity -> {"dir": Path, "manifest": dict}
repos_dir = work_dir / "repos"
repos_dir.mkdir(parents=True, exist_ok=True)


def load_package(url, exact_tag=None, lower=None, upper=None, branch=None):
    ident = pkg_identity(url)
    if ident in packages:
        return ident
    dest = repos_dir / ident
    ref = exact_tag or branch
    if not ref and (lower or upper):
        ref = pick_remote_tag(url, lower, upper)
    print(f"[fetch_mpvkit] Cloning manifest {url} (ref={ref or 'HEAD'})...", flush=True)
    clone_cmd = ["git", "clone", "--depth", "1"]
    if ref:
        clone_cmd += ["--branch", ref]
    clone_cmd += [url, str(dest)]
    res = subprocess.run(clone_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if res.returncode != 0 and ref:
        shutil.rmtree(dest, ignore_errors=True)
        run(["git", "clone", "--depth", "1", url, str(dest)])
    elif res.returncode != 0:
        raise RuntimeError(f"git clone failed for {url}: {res.stderr}")

    raw_json = run(["swift", "package", "dump-package"], cwd=dest)
    manifest = json.loads(raw_json)
    packages[ident] = {"dir": dest, "manifest": manifest}

    def unwrap_first_str(val):
        while isinstance(val, list) and val:
            val = val[0]
        if isinstance(val, dict):
            for k in ("_0", "version", "name", "identifier"):
                if isinstance(val.get(k), str):
                    return val[k]
        return val if isinstance(val, str) else None

    for dep in manifest.get("dependencies", []):
        sc_list = dep.get("sourceControl") or []
        if isinstance(sc_list, dict):
            sc_list = [sc_list]
        for sc in sc_list:
            loc = sc.get("location", {})
            dep_url = find_first_url(loc)
            if not dep_url:
                continue
            req = sc.get("requirement", {})
            ex = unwrap_first_str(req.get("exact"))
            br = unwrap_first_str(req.get("branch"))
            rng = req.get("range")
            while isinstance(rng, list) and rng:
                rng = rng[0]
            lo = rng.get("lowerBound") if isinstance(rng, dict) else None
            hi = rng.get("upperBound") if isinstance(rng, dict) else None
            dep_id = sc.get("identity", pkg_identity(dep_url)).lower()
            resolved_id = load_package(dep_url, exact_tag=ex, lower=lo, upper=hi, branch=br)
            if dep_id != resolved_id and dep_id not in packages:
                packages[dep_id] = packages[resolved_id]
    return ident


def find_first_url(node):
    if isinstance(node, str) and (node.startswith("https://") or node.startswith("http://") or node.startswith("git@")):
        return node
    if isinstance(node, dict):
        for v in node.values():
            found = find_first_url(v)
            if found:
                return found
    elif isinstance(node, list):
        for item in node:
            found = find_first_url(item)
            if found:
                return found
    return None


resolved_root_tag = mpvkit_tag or pick_remote_tag(mpvkit_repo)
root_ident = load_package(mpvkit_repo, exact_tag=resolved_root_tag or None)

binary_urls = []
seen_binary_urls = set()
linked_frameworks = set()
linked_libraries = set()
visited_targets = set()


def condition_allows_ios(cond):
    while isinstance(cond, list) and len(cond) == 1:
        cond = cond[0]
    while isinstance(cond, dict) and "condition" in cond:
        cond = cond["condition"]
        while isinstance(cond, list) and len(cond) == 1:
            cond = cond[0]
    if not cond or not isinstance(cond, dict):
        return True
    plats = cond.get("platforms") or cond.get("platformNames") or []
    if not plats:
        return True
    norm = [str(p).lower() for p in plats]
    return "ios" in norm


def collect_settings(target_obj):
    for st in target_obj.get("settings", []):
        if not condition_allows_ios(st.get("condition")):
            continue
        kind = st.get("kind", {})
        if "linkedFramework" in kind:
            vals = kind["linkedFramework"]
            if isinstance(vals, list) and vals:
                linked_frameworks.add(str(vals[0]))
            elif isinstance(vals, str):
                linked_frameworks.add(vals)
        elif "linkedLibrary" in kind:
            vals = kind["linkedLibrary"]
            if isinstance(vals, list) and vals:
                linked_libraries.add(str(vals[0]))
            elif isinstance(vals, str):
                linked_libraries.add(vals)


def walk_product(pkg_id, prod_name):
    pkg = packages.get(pkg_id.lower())
    if not pkg:
        return
    manifest = pkg["manifest"]
    for prod in manifest.get("products", []):
        if prod.get("name") == prod_name:
            for tname in prod.get("targets", []):
                walk_target(pkg_id.lower(), tname)
            return
    # Fallback: if product name matches a target directly
    walk_target(pkg_id.lower(), prod_name)


def walk_target(pkg_id, target_name):
    key = (pkg_id.lower(), target_name)
    if key in visited_targets:
        return
    visited_targets.add(key)
    pkg = packages.get(pkg_id.lower())
    if not pkg:
        return
    manifest = pkg["manifest"]
    target_obj = None
    for t in manifest.get("targets", []):
        if t.get("name") == target_name:
            target_obj = t
            break
    if not target_obj:
        return

    collect_settings(target_obj)

    if target_obj.get("type") == "binary":
        url = target_obj.get("url") or find_first_url(target_obj)
        if url and url not in seen_binary_urls:
            seen_binary_urls.add(url)
            binary_urls.append((target_name, url))
        return

    for dep in target_obj.get("dependencies", []):
        if "byName" in dep:
            arr = dep["byName"]
            name = arr[0]
            cond = arr[1] if len(arr) > 1 else None
            if not condition_allows_ios(cond):
                continue
            # Can be local target or a product in a dependency package with matching name
            local_names = {t.get("name") for t in manifest.get("targets", [])}
            if name in local_names:
                walk_target(pkg_id, name)
            else:
                for sub_id in list(packages.keys()):
                    walk_product(sub_id, name)
        elif "target" in dep:
            arr = dep["target"]
            name = arr[0]
            cond = arr[1] if len(arr) > 1 else None
            if condition_allows_ios(cond):
                walk_target(pkg_id, name)
        elif "product" in dep:
            arr = dep["product"]
            prod_name = arr[0]
            sub_pkg = (arr[1] or prod_name).lower()
            cond = arr[3] if len(arr) > 3 else (arr[2] if len(arr) > 2 and isinstance(arr[2], dict) else None)
            if condition_allows_ios(cond):
                if sub_pkg in packages:
                    walk_product(sub_pkg, prod_name)
                else:
                    for cand_id in list(packages.keys()):
                        if sub_pkg in cand_id or cand_id in sub_pkg:
                            walk_product(cand_id, prod_name)


def collect_fallback_binaries():
    for ident, pkg in packages.items():
        for t in pkg["manifest"].get("targets", []):
            if t.get("type") == "binary":
                t_url = t.get("url") or find_first_url(t)
                if not t_url:
                    continue
                tname = t.get("name", "")
                if not use_gpl and "gpl" in tname.lower():
                    continue
                if t_url not in seen_binary_urls:
                    seen_binary_urls.add(t_url)
                    binary_urls.append((tname, t_url))


walk_product(root_ident, root_product)
if not binary_urls:
    collect_fallback_binaries()

if not binary_urls and resolved_root_tag and not mpvkit_tag:
    shutil.rmtree(repos_dir, ignore_errors=True)
    repos_dir.mkdir(parents=True, exist_ok=True)
    packages.clear()
    visited_targets.clear()
    root_ident = load_package(mpvkit_repo, exact_tag=None)
    walk_product(root_ident, root_product)
    if not binary_urls:
        collect_fallback_binaries()

if not binary_urls:
    raise RuntimeError("No binaryTarget XCFramework URLs discovered in MPVKit manifest")

print(f"[fetch_mpvkit] Discovered {len(binary_urls)} binary XCFramework targets for {root_product}.", flush=True)

dl_dir = work_dir / "downloads"
ex_dir = work_dir / "extracted"
dl_dir.mkdir(parents=True, exist_ok=True)
ex_dir.mkdir(parents=True, exist_ok=True)


def download_and_extract(idx_item):
    idx, (name, url) = idx_item
    zip_path = dl_dir / f"{idx:02d}_{name}.zip"
    out_sub = ex_dir / f"{idx:02d}_{name}"
    out_sub.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["curl", "-fsSL", "--retry", "4", "--retry-delay", "2", "-o", str(zip_path), url],
        check=True,
    )
    subprocess.run(["unzip", "-q", str(zip_path), "-d", str(out_sub)], check=True)
    xcfws = sorted(out_sub.rglob("*.xcframework"))
    return (name, xcfws)


extracted_items = []
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    futures = [pool.submit(download_and_extract, item) for item in enumerate(binary_urls)]
    for fut in futures:
        extracted_items.append(fut.result())

static_archives = []
libmpv_static = None
dynamic_xcfws = []  # (name, xcfw_path, slice_dir, fw_name, bin_path)

for tname, xcfws in extracted_items:
    for xcfw in xcfws:
        if "__MACOSX" in xcfw.parts:
            continue
        info_plist = xcfw / "Info.plist"
        if not info_plist.exists():
            continue
        with info_plist.open("rb") as fp:
            pl = plistlib.load(fp)
        selected_lib = None
        for lib in pl.get("AvailableLibraries", []):
            plat = str(lib.get("SupportedPlatform", "")).lower()
            variant = str(lib.get("SupportedPlatformVariant", "") or "").lower()
            archs = [str(a).lower() for a in lib.get("SupportedArchitectures", [])]
            if plat == "ios" and not variant and "arm64" in archs:
                selected_lib = lib
                break
        if not selected_lib:
            continue

        slice_dir = xcfw / selected_lib["LibraryIdentifier"]
        rel_path = selected_lib["LibraryPath"]
        lib_entry = slice_dir / rel_path
        if rel_path.endswith(".framework"):
            fw_name = pathlib.Path(rel_path).stem
            bin_path = lib_entry / fw_name
        else:
            fw_name = pathlib.Path(rel_path).stem
            bin_path = lib_entry

        if not bin_path.exists():
            continue

        file_desc = run(["file", "-b", str(bin_path)]).lower()
        if "ar archive" in file_desc or "mach-o 64-bit object" in file_desc or bin_path.suffix == ".a":
            # Ensure fat Mach-O static archives (including single-arch 0xcafebabe wrappers) are thinned to arm64
            with bin_path.open("rb") as mfp:
                head4 = mfp.read(4)
            is_fat = head4 in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
            try:
                archs_raw = run(["xcrun", "lipo", "-archs", str(bin_path)]).strip().split()
                if (len(archs_raw) > 1 or is_fat) and "arm64" in archs_raw:
                    thinned = work_dir / f"thin_{len(static_archives)}_{tname}_{bin_path.name}.a"
                    run(["xcrun", "lipo", str(bin_path), "-thin", "arm64", "-output", str(thinned)])
                    bin_path = thinned
            except Exception:
                pass
            if "libmpv" in tname.lower() or "libmpv" in xcfw.stem.lower() or tname.lower() == "mpv":
                libmpv_static = bin_path
            else:
                static_archives.append(bin_path)
        elif "dynamically linked shared library" in file_desc:
            dynamic_xcfws.append((tname, xcfw, slice_dir, fw_name, bin_path))
        else:
            raise RuntimeError(f"Unrecognized Mach-O binary type for {bin_path}: {file_desc}")

if libmpv_static is None:
    for idx, cand in enumerate(static_archives):
        if "mpv" in cand.name.lower() or "mpv" in str(cand).lower():
            libmpv_static = static_archives.pop(idx)
            break

# Copy any dynamic dependency XCFrameworks so CocoaPods & package_ipa.sh embed them
for _, xcfw, _, _, _ in dynamic_xcfws:
    dst = target_fw_dir / xcfw.name
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(xcfw, dst, symlinks=True)
    print(f"[fetch_mpvkit] Installed dynamic {dst.name}", flush=True)

if libmpv_static is None:
    if any("mpv" in item[0].lower() or "mpv" in item[1].stem.lower() for item in dynamic_xcfws):
        print("[fetch_mpvkit] Libmpv is distributed as a dynamic XCFramework; installation complete.", flush=True)
        sys.exit(0)
    raise RuntimeError("Could not locate iOS arm64 libmpv binary inside downloaded XCFrameworks")

print(
    f"[fetch_mpvkit] Linking static libmpv ({libmpv_static.name}) + {len(static_archives)} static archives into NovaMpv.xcframework...",
    flush=True,
)

iphoneos_sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()
iphonesim_sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).strip()


def parse_bsd_ar_members(ar_bytes):
    if ar_bytes[:8] != b"!<arch>\n":
        return []
    pos = 8
    n = len(ar_bytes)
    members = []
    while pos + 60 <= n:
        hdr = ar_bytes[pos:pos + 60]
        if hdr[58:60] != b"`\n":
            break
        raw_name = hdr[0:16].decode("latin1")
        raw_size = int(hdr[48:58].decode("ascii").strip())
        data_pos = pos + 60
        data_end = data_pos + raw_size
        if raw_name.startswith("#1/"):
            ext_len = int(raw_name[3:].strip())
            name = ar_bytes[data_pos:data_pos + ext_len].rstrip(b"\x00").decode("utf-8", errors="replace")
            payload_pos = data_pos + ext_len
        else:
            name = raw_name.rstrip(" /")
            payload_pos = data_pos
        members.append((name, payload_pos, data_end - payload_pos))
        pos = data_end + (data_end & 1)
    return members


def parse_macho64_obj(obj_bytes):
    magic, _, _, filetype, ncmds, _, _, _ = struct.unpack_from("<IIIIIIII", obj_bytes, 0)
    if magic != 0xFEEDFACF or filetype != 1:
        raise RuntimeError(f"Unexpected Mach-O object header: magic={hex(magic)} type={filetype}")
    sections = {}
    symoff = nsyms = stroff = strsize = None
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", obj_bytes, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", obj_bytes, off + 64)[0]
            sect_off = off + 72
            for _ in range(nsects):
                sectname = obj_bytes[sect_off:sect_off + 16].split(b"\x00", 1)[0]
                segname = obj_bytes[sect_off + 16:sect_off + 32].split(b"\x00", 1)[0]
                s_addr, s_size, s_offset, _, s_reloff, s_nreloc = struct.unpack_from("<QQIIII", obj_bytes, sect_off + 32)
                sections[(segname, sectname)] = (s_addr, s_size, s_offset, s_reloff, s_nreloc)
                sect_off += 80
        elif cmd == 0x02:  # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", obj_bytes, off + 8)
        off += cmdsize
    if symoff is None:
        raise RuntimeError("Missing LC_SYMTAB in Mach-O object")
    strtab = obj_bytes[stroff:stroff + strsize]
    sym_list = []
    syms = {}
    for i in range(nsyms):
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", obj_bytes, symoff + i * 16)
        end = strtab.find(b"\x00", n_strx)
        name = strtab[n_strx:end].decode("utf-8", errors="replace")
        sym_list.append(name)
        syms[name] = (n_type, n_sect, n_value, n_strx)
    return sections, sym_list, syms, stroff


def maybe_build_moltenvk_resize_shim(libmpv_archive, sdk_path):
    ar_bytes = libmpv_archive.read_bytes()
    by_name = {name: (off, sz) for name, off, sz in parse_bsd_ar_members(ar_bytes)}
    if "video_out_vulkan_context_moltenvk.m.o" not in by_name:
        print("[fetch_mpvkit] video_out_vulkan_context_moltenvk.m.o not found; skipping resize shim.", flush=True)
        return None
    m_off, m_sz = by_name["video_out_vulkan_context_moltenvk.m.o"]
    molten_bytes = ar_bytes[m_off:m_off + m_sz]
    sections, sym_list, syms, stroff = parse_macho64_obj(molten_bytes)
    if "_ra_ctx_vulkan_moltenvk" not in syms or "_moltenvk_control" not in syms or "_moltenvk_reconfig" not in syms:
        print("[fetch_mpvkit] Unexpected symbols in moltenvk object; skipping resize shim.", flush=True)
        return None

    text_addr, _, text_fileoff, _, _ = sections[(b"__TEXT", b"__text")]
    _, const_size, _, const_reloff, const_nreloc = sections[(b"__DATA", b"__const")]
    ctrl_off = text_fileoff + (syms["_moltenvk_control"][2] - text_addr)
    ctrl_insns = struct.unpack_from("<II", molten_bytes, ctrl_off)
    if ctrl_insns != (0x12800040, 0xD65F03C0):
        print("[fetch_mpvkit] _moltenvk_control already implemented upstream; skipping resize shim.", flush=True)
        return None

    reconfig_off = text_fileoff + (syms["_moltenvk_reconfig"][2] - text_addr)
    priv_offset = None
    layer_offset = None
    priv_reg = None
    for pos in range(reconfig_off, ctrl_off, 4):
        insn = struct.unpack_from("<I", molten_bytes, pos)[0]
        if (insn & 0xFFC00000) == 0xF9400000:
            imm_bytes = ((insn >> 10) & 0xFFF) * 8
            rn = (insn >> 5) & 0x1F
            rt = insn & 0x1F
            if priv_offset is None and rn in (0, 19):
                priv_offset = imm_bytes
                priv_reg = rt
            elif priv_offset is not None and rn == priv_reg and rt == 0:
                layer_offset = imm_bytes
                break
    if priv_offset is None or layer_offset is None:
        raise RuntimeError("Could not extract priv/layer offsets from _moltenvk_reconfig")

    vo_dwidth_offset = 248
    if "video_out_vulkan_context.c.o" in by_name:
        v_off, v_sz = by_name["video_out_vulkan_context.c.o"]
        vk_bytes = ar_bytes[v_off:v_off + v_sz]
        vk_sects, _, vk_syms, _ = parse_macho64_obj(vk_bytes)
        if "_ra_vk_ctx_resize" in vk_syms and (b"__TEXT", b"__text") in vk_sects:
            vt_addr, _, vt_off, _, _ = vk_sects[(b"__TEXT", b"__text")]
            r_off = vt_off + (vk_syms["_ra_vk_ctx_resize"][2] - vt_addr)
            for pos in range(r_off, min(len(vk_bytes), r_off + 128), 4):
                insn = struct.unpack_from("<I", vk_bytes, pos)[0]
                if (insn & 0xFFC00000) == 0x29000000:
                    imm7 = (insn >> 15) & 0x7F
                    if imm7 & 0x40:
                        imm7 -= 0x80
                    rn = (insn >> 5) & 0x1F
                    if rn != 31 and imm7 * 4 >= 64:
                        vo_dwidth_offset = imm7 * 4
                        break

    relocs = {}
    for i in range(const_nreloc):
        r_addr, r_info = struct.unpack_from("<II", molten_bytes, const_reloff + i * 8)
        r_sym = r_info & 0x00FFFFFF
        r_extern = (r_info >> 27) & 1
        if r_extern and r_sym < len(sym_list):
            relocs[sym_list[r_sym]] = r_addr

    if const_size % 8 != 0:
        raise RuntimeError(f"Unexpected _ra_ctx_vulkan_moltenvk size: {const_size}")
    ptr_count = const_size // 8
    type_idx = relocs.get("l_.str", 0) // 8
    name_idx = relocs.get("l_.str.1", 8) // 8
    reconfig_idx = relocs["_moltenvk_reconfig"] // 8
    control_idx = relocs["_moltenvk_control"] // 8
    init_idx = relocs["_moltenvk_init"] // 8
    uninit_idx = relocs["_moltenvk_uninit"] // 8

    old_sym = b"_ra_ctx_vulkan_moltenvk\x00"
    new_sym = b"_uzv_orig_moltenvk_fns_\x00"
    sym_pos = stroff + syms["_ra_ctx_vulkan_moltenvk"][3]
    if molten_bytes[sym_pos:sym_pos + len(old_sym)] != old_sym:
        raise RuntimeError("Symbol string mismatch in video_out_vulkan_context_moltenvk.m.o")

    patched_ar = bytearray(ar_bytes)
    patched_ar[m_off + sym_pos:m_off + sym_pos + len(new_sym)] = new_sym
    patched_path = work_dir / "libmpv_moltenvk_patched.a"
    patched_path.write_bytes(patched_ar)
    run(["xcrun", "ranlib", str(patched_path)])

    shim_m = work_dir / "uzv_moltenvk_resize_shim.m"
    shim_o = work_dir / "uzv_moltenvk_resize_shim.o"
    shim_m.write_text(
        """#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

struct ra_ctx;
struct vo;

extern const void * const uzv_orig_moltenvk_fns_[UZV_FNS_PTR_COUNT];
extern bool ra_vk_ctx_resize(struct ra_ctx *ctx, int width, int height);
extern void vo_wakeup(struct vo *vo);

#define UZV_VOCTRL_CHECK_EVENTS 2
#define UZV_VO_TRUE 1
#define UZV_VO_ERROR (-1)
#define UZV_VO_NOTIMPL (-3)
#define UZV_VO_EVENT_EXPOSE (1 << 0)
#define UZV_VO_EVENT_RESIZE (1 << 1)
#define UZV_MAX_SLOTS 16

typedef struct {
    struct ra_ctx *ctx;
    struct vo *vo;
    int64_t wid;
    int last_w;
    int last_h;
    int notified_w;
    int notified_h;
    bool force_resize;
} UzvMoltenvkSlot;

static pthread_mutex_t g_shim_lock = PTHREAD_MUTEX_INITIALIZER;
static UzvMoltenvkSlot g_slots[UZV_MAX_SLOTS];

static CAMetalLayer *uzv_ctx_layer(struct ra_ctx *ctx) {
    if (!ctx) return NULL;
    void *priv = *(void * const *)((const char *)ctx + UZV_RA_CTX_PRIV_OFFSET);
    if (!priv) return NULL;
    return *(CAMetalLayer * const *)((const char *)priv + UZV_PRIV_LAYER_OFFSET);
}

static struct vo *uzv_ctx_vo(struct ra_ctx *ctx) {
    if (!ctx) return NULL;
    return *(struct vo * const *)ctx;
}

static void uzv_read_layer_drawable_size(
    struct ra_ctx *ctx,
    int fallback_w,
    int fallback_h,
    int *out_w,
    int *out_h
) {
    int w = 0;
    int h = 0;
    CAMetalLayer *layer = uzv_ctx_layer(ctx);
    if (layer != NULL) {
        CGSize s = [layer drawableSize];
        if (isfinite(s.width) && isfinite(s.height)) {
            w = (int)llround(s.width);
            h = (int)llround(s.height);
        }
    }
    if ((w <= 1 || h <= 1) && fallback_w > 1 && fallback_h > 1) {
        w = fallback_w;
        h = fallback_h;
    }
    *out_w = w;
    *out_h = h;
}

static bool uzv_sync_ctx_size(struct ra_ctx *ctx, bool is_reconfig, bool *out_resized) {
    if (out_resized) *out_resized = false;
    if (!ctx) return false;

    int fallback_w = 0;
    int fallback_h = 0;
    int prev_w = 0;
    int prev_h = 0;
    bool forced = false;

    pthread_mutex_lock(&g_shim_lock);
    for (int i = 0; i < UZV_MAX_SLOTS; i++) {
        if (g_slots[i].ctx == ctx) {
            fallback_w = g_slots[i].notified_w;
            fallback_h = g_slots[i].notified_h;
            prev_w = g_slots[i].last_w;
            prev_h = g_slots[i].last_h;
            forced = g_slots[i].force_resize;
            break;
        }
    }
    pthread_mutex_unlock(&g_shim_lock);

    int w = 0;
    int h = 0;
    uzv_read_layer_drawable_size(ctx, fallback_w, fallback_h, &w, &h);
    if (w <= 1 || h <= 1) {
        return true;
    }

    struct vo *vo = uzv_ctx_vo(ctx);
    if (vo != NULL) {
        *(int *)((char *)vo + UZV_VO_DWIDTH_OFFSET) = w;
        *(int *)((char *)vo + UZV_VO_DWIDTH_OFFSET + 4) = h;
    }

    bool need_resize = is_reconfig || forced || (w != prev_w) || (h != prev_h);
    if (!need_resize) {
        return true;
    }

    bool ok = ra_vk_ctx_resize(ctx, w, h);
    if (vo != NULL) {
        int rw = *(const int *)((const char *)vo + UZV_VO_DWIDTH_OFFSET);
        int rh = *(const int *)((const char *)vo + UZV_VO_DWIDTH_OFFSET + 4);
        if (rw <= 1 || rh <= 1) {
            *(int *)((char *)vo + UZV_VO_DWIDTH_OFFSET) = w;
            *(int *)((char *)vo + UZV_VO_DWIDTH_OFFSET + 4) = h;
        }
    }

    if (ok) {
        pthread_mutex_lock(&g_shim_lock);
        for (int i = 0; i < UZV_MAX_SLOTS; i++) {
            if (g_slots[i].ctx == ctx) {
                g_slots[i].last_w = w;
                g_slots[i].last_h = h;
                g_slots[i].force_resize = false;
                break;
            }
        }
        pthread_mutex_unlock(&g_shim_lock);
    }

    if (out_resized) {
        *out_resized = ok && (forced || w != prev_w || h != prev_h);
    }
    return ok;
}

static bool uzv_shim_moltenvk_init(struct ra_ctx *ctx) {
    bool (*orig_init)(struct ra_ctx *) =
        (bool (*)(struct ra_ctx *))uzv_orig_moltenvk_fns_[UZV_FNS_INIT_IDX];
    if (!orig_init || !orig_init(ctx)) {
        return false;
    }

    CAMetalLayer *layer = uzv_ctx_layer(ctx);
    int64_t wid = (int64_t)(intptr_t)layer;
    struct vo *vo = uzv_ctx_vo(ctx);

    pthread_mutex_lock(&g_shim_lock);
    UzvMoltenvkSlot *slot = NULL;
    for (int i = 0; i < UZV_MAX_SLOTS; i++) {
        if (g_slots[i].ctx == ctx || (g_slots[i].ctx == NULL && wid != 0 && g_slots[i].wid == wid)) {
            slot = &g_slots[i];
            break;
        }
    }
    if (!slot) {
        for (int i = 0; i < UZV_MAX_SLOTS; i++) {
            if (g_slots[i].ctx == NULL && g_slots[i].wid == 0) {
                slot = &g_slots[i];
                break;
            }
        }
    }
    if (!slot) {
        slot = &g_slots[0];
        memset(slot, 0, sizeof(*slot));
    }
    slot->ctx = ctx;
    slot->vo = vo;
    slot->wid = wid;
    slot->last_w = 0;
    slot->last_h = 0;
    slot->force_resize = true;
    pthread_mutex_unlock(&g_shim_lock);

    (void)uzv_sync_ctx_size(ctx, true, NULL);
    return true;
}

static void uzv_shim_moltenvk_uninit(struct ra_ctx *ctx) {
    pthread_mutex_lock(&g_shim_lock);
    for (int i = 0; i < UZV_MAX_SLOTS; i++) {
        if (g_slots[i].ctx == ctx) {
            memset(&g_slots[i], 0, sizeof(g_slots[i]));
        }
    }
    pthread_mutex_unlock(&g_shim_lock);

    void (*orig_uninit)(struct ra_ctx *) =
        (void (*)(struct ra_ctx *))uzv_orig_moltenvk_fns_[UZV_FNS_UNINIT_IDX];
    if (orig_uninit) {
        orig_uninit(ctx);
    }
}

static bool uzv_shim_moltenvk_reconfig(struct ra_ctx *ctx) {
    (void)uzv_sync_ctx_size(ctx, true, NULL);
    return true;
}

static int uzv_shim_moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg) {
    if (request != UZV_VOCTRL_CHECK_EVENTS) {
        int (*orig_ctrl)(struct ra_ctx *, int *, int, void *) =
            (int (*)(struct ra_ctx *, int *, int, void *))uzv_orig_moltenvk_fns_[UZV_FNS_CONTROL_IDX];
        return orig_ctrl ? orig_ctrl(ctx, events, request, arg) : UZV_VO_NOTIMPL;
    }
    bool resized = false;
    if (!uzv_sync_ctx_size(ctx, false, &resized)) {
        return UZV_VO_ERROR;
    }
    if (resized && events != NULL) {
        *events |= (UZV_VO_EVENT_RESIZE | UZV_VO_EVENT_EXPOSE);
    }
    return UZV_VO_TRUE;
}

__attribute__((visibility("default")))
void mpv_novaplay_notify_layer_resized(int64_t wid, int32_t width, int32_t height) {
    if (wid == 0 || width <= 1 || height <= 1) {
        return;
    }
    pthread_mutex_lock(&g_shim_lock);
    UzvMoltenvkSlot *matched = NULL;
    for (int i = 0; i < UZV_MAX_SLOTS; i++) {
        if (g_slots[i].wid == wid) {
            matched = &g_slots[i];
            matched->notified_w = (int)width;
            matched->notified_h = (int)height;
            matched->force_resize = true;
            if (matched->vo != NULL) {
                vo_wakeup(matched->vo);
            }
        }
    }
    if (!matched) {
        for (int i = 0; i < UZV_MAX_SLOTS; i++) {
            if (g_slots[i].ctx == NULL && g_slots[i].wid == 0) {
                g_slots[i].wid = wid;
                g_slots[i].notified_w = (int)width;
                g_slots[i].notified_h = (int)height;
                g_slots[i].force_resize = true;
                break;
            }
        }
    }
    pthread_mutex_unlock(&g_shim_lock);
}

const void * const ra_ctx_vulkan_moltenvk[UZV_FNS_PTR_COUNT] = {
    [UZV_FNS_TYPE_IDX] = "vulkan",
    [UZV_FNS_NAME_IDX] = "moltenvk",
    [UZV_FNS_RECONFIG_IDX] = (const void *)uzv_shim_moltenvk_reconfig,
    [UZV_FNS_CONTROL_IDX] = (const void *)uzv_shim_moltenvk_control,
    [UZV_FNS_INIT_IDX] = (const void *)uzv_shim_moltenvk_init,
    [UZV_FNS_UNINIT_IDX] = (const void *)uzv_shim_moltenvk_uninit,
};
""",
        encoding="utf-8",
    )
    run([
        "xcrun",
        "--sdk",
        "iphoneos",
        "clang",
        "-c",
        "-x",
        "objective-c",
        "-arch",
        "arm64",
        "-isysroot",
        sdk_path,
        "-miphoneos-version-min=15.0",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        f"-DUZV_FNS_PTR_COUNT={ptr_count}",
        f"-DUZV_FNS_TYPE_IDX={type_idx}",
        f"-DUZV_FNS_NAME_IDX={name_idx}",
        f"-DUZV_FNS_RECONFIG_IDX={reconfig_idx}",
        f"-DUZV_FNS_CONTROL_IDX={control_idx}",
        f"-DUZV_FNS_INIT_IDX={init_idx}",
        f"-DUZV_FNS_UNINIT_IDX={uninit_idx}",
        f"-DUZV_RA_CTX_PRIV_OFFSET={priv_offset}",
        f"-DUZV_PRIV_LAYER_OFFSET={layer_offset}",
        f"-DUZV_VO_DWIDTH_OFFSET={vo_dwidth_offset}",
        str(shim_m),
        "-o",
        str(shim_o),
    ])
    print(
        f"[fetch_mpvkit] Applied MoltenVK resize shim (priv_off={priv_offset}, layer_off={layer_offset}, dwidth_off={vo_dwidth_offset}).",
        flush=True,
    )
    return (patched_path, shim_o)


shim_result = maybe_build_moltenvk_resize_shim(libmpv_static, iphoneos_sdk)
moltenvk_shim_obj = None
if shim_result is not None:
    libmpv_static, moltenvk_shim_obj = shim_result

# Build exported symbol list: ONLY `_mpv_*` (and `_vk*` if MoltenVK is static so libplacebo dlsym finds Vulkan)
exp_syms = set()
if moltenvk_shim_obj is not None:
    exp_syms.add("_mpv_novaplay_notify_layer_resized")
nm_mpv = run(["xcrun", "nm", "-arch", "arm64", "-gU", str(libmpv_static)])
for line in nm_mpv.splitlines():
    toks = line.strip().split()
    if toks and toks[-1].startswith("_mpv_"):
        exp_syms.add(toks[-1])

has_static_vulkan = False
moltenvk_archives = set()
for arch_path in static_archives:
    if "moltenvk" in str(arch_path).lower():
        moltenvk_archives.add(arch_path)
        nm_vk = run(["xcrun", "nm", "-arch", "arm64", "-gU", str(arch_path)])
        for line in nm_vk.splitlines():
            toks = line.strip().split()
            if toks and (toks[-1].startswith("_vk") or toks[-1].startswith("_vk_icd")):
                exp_syms.add(toks[-1])
                if toks[-1] == "_vkGetInstanceProcAddr":
                    has_static_vulkan = True

if not exp_syms:
    raise RuntimeError(f"No _mpv_* symbols found in {libmpv_static}")

sym_file = work_dir / "exported_mpv.sym"
sym_file.write_text("\n".join(sorted(exp_syms)) + "\n", encoding="utf-8")

base_frameworks = [
    "Foundation",
    "CoreFoundation",
    "CoreVideo",
    "CoreMedia",
    "CoreAudio",
    "AudioToolbox",
    "VideoToolbox",
    "AVFoundation",
    "Metal",
    "QuartzCore",
    "IOSurface",
    "UIKit",
    "CoreGraphics",
    "CoreText",
    "ImageIO",
    "Security",
    "SystemConfiguration",
    "Network",
    "UniformTypeIdentifiers",
]
optional_sdk_frameworks = [
    "Accelerate",
    "CFNetwork",
    "CoreImage",
    "CoreServices",
    "GameController",
    "IOKit",
    "MediaPlayer",
    "MetalPerformanceShaders",
    "MobileCoreServices",
    "OpenGLES",
]
for fw in sorted(set(linked_frameworks) | set(optional_sdk_frameworks)):
    if fw not in base_frameworks:
        fw_sdk_dir = pathlib.Path(iphoneos_sdk) / "System" / "Library" / "Frameworks" / f"{fw}.framework"
        if fw_sdk_dir.exists():
            base_frameworks.append(fw)

base_libs = ["objc", "iconv", "z", "bz2", "xml2", "resolv", "c++"]
optional_sdk_libs = ["compression", "expat", "lzma", "sqlite3"]
for lib in sorted(set(linked_libraries) | set(optional_sdk_libs)):
    if lib not in base_libs:
        tbd_path = pathlib.Path(iphoneos_sdk) / "usr" / "lib" / f"lib{lib}.tbd"
        if tbd_path.exists():
            base_libs.append(lib)

dev_fw_dir = work_dir / "device" / "NovaMpv.framework"
dev_fw_dir.mkdir(parents=True, exist_ok=True)
dev_bin = dev_fw_dir / "NovaMpv"

link_cmd = [
    "xcrun",
    "--sdk",
    "iphoneos",
    "clang++",
    "-dynamiclib",
    "-arch",
    "arm64",
    "-isysroot",
    iphoneos_sdk,
    "-miphoneos-version-min=15.0",
    "-install_name",
    "@rpath/NovaMpv.framework/NovaMpv",
    f"-Wl,-exported_symbols_list,{sym_file}",
]
if moltenvk_shim_obj is not None:
    link_cmd.append(str(moltenvk_shim_obj))
link_cmd.append(f"-Wl,-force_load,{libmpv_static}")
if has_static_vulkan:
    link_cmd.append("-Wl,-u,_vkGetInstanceProcAddr")

for arch_path in static_archives:
    if arch_path in moltenvk_archives:
        link_cmd.append(f"-Wl,-force_load,{arch_path}")
    else:
        link_cmd.append(str(arch_path))

seen_dyn_dirs = set()
for _, _, slice_dir, fw_name, bin_path in dynamic_xcfws:
    if bin_path.parent.name.endswith(".framework"):
        fdir = str(slice_dir)
        if fdir not in seen_dyn_dirs:
            seen_dyn_dirs.add(fdir)
            link_cmd += ["-F", fdir]
        link_cmd += ["-framework", fw_name]

for fw in base_frameworks:
    link_cmd += ["-framework", fw]
for lib in base_libs:
    link_cmd.append(f"-l{lib}")

link_cmd += ["-o", str(dev_bin)]
run(link_cmd)
run(["xcrun", "strip", "-x", str(dev_bin)], check=False)

dev_plist = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "NovaMpv",
    "CFBundleIdentifier": "app.novaplay.NovaMpv",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "NovaMpv",
    "CFBundlePackageType": "FMWK",
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "1",
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "MinimumOSVersion": "15.0",
}
with (dev_fw_dir / "Info.plist").open("wb") as fp:
    plistlib.dump(dev_plist, fp)

# Build lightweight iOS Simulator slice (arm64 + x86_64) so simulator builds also succeed cleanly
sim_c = work_dir / "sim_stub.c"
sim_c.write_text(
    "int uzv_novampv_simulator_stub(void) { return 0; }\n"
    "void mpv_novaplay_notify_layer_resized(long long wid, int w, int h) { (void)wid; (void)w; (void)h; }\n",
    encoding="utf-8",
)
sim_arm64 = work_dir / "sim_arm64.dylib"
sim_x86 = work_dir / "sim_x86_64.dylib"
for arch, out_p in [("arm64", sim_arm64), ("x86_64", sim_x86)]:
    run([
        "xcrun",
        "--sdk",
        "iphonesimulator",
        "clang",
        "-dynamiclib",
        "-target",
        f"{arch}-apple-ios15.0-simulator",
        "-isysroot",
        iphonesim_sdk,
        "-install_name",
        "@rpath/NovaMpv.framework/NovaMpv",
        str(sim_c),
        "-o",
        str(out_p),
    ])

sim_fw_dir = work_dir / "simulator" / "NovaMpv.framework"
sim_fw_dir.mkdir(parents=True, exist_ok=True)
run(["xcrun", "lipo", "-create", str(sim_arm64), str(sim_x86), "-output", str(sim_fw_dir / "NovaMpv")])
sim_plist = dict(dev_plist)
sim_plist["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
with (sim_fw_dir / "Info.plist").open("wb") as fp:
    plistlib.dump(sim_plist, fp)

target_xcfw = target_fw_dir / "NovaMpv.xcframework"
if target_xcfw.exists():
    shutil.rmtree(target_xcfw)
run([
    "xcodebuild",
    "-create-xcframework",
    "-framework",
    str(dev_fw_dir),
    "-framework",
    str(sim_fw_dir),
    "-output",
    str(target_xcfw),
])
print(f"[fetch_mpvkit] Successfully built {target_xcfw}", flush=True)
PY

chmod -R u+rwX "${TARGET_FW_DIR}"
echo "[fetch_mpvkit] Done."
