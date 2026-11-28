import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fetch_mpvkit.sh BSD ar + Mach-O 64 MoltenVK parser handles stub, non-stub, and edge cases', () async {
    final res = await Process.run('python3', [
      '-c',
      r'''
import pathlib, re, struct

sh_text = pathlib.Path("ios/scripts/fetch_mpvkit.sh").read_text(encoding="utf-8")
m = re.search(r"(def parse_bsd_ar_members\(.*?\n)\nshim_result =", sh_text, re.S)
assert m, "Missing helper functions in fetch_mpvkit.sh"
ns = {"struct": struct, "pathlib": pathlib}
exec(m.group(1), ns)

# 1. Empty / non-ar edge case
assert ns["parse_bsd_ar_members"](b"") == []
assert ns["parse_bsd_ar_members"](b"\xca\xfe\xba\xbe") == []

# 2. BSD #1/ extended member name + odd-length padding edge case
def make_ar_member(name: str, payload: bytes) -> bytes:
    name_b = name.encode("utf-8") + b"\x00"
    if len(name_b) % 4:
        name_b += b"\x00" * (4 - (len(name_b) % 4))
    hdr_name = f"#1/{len(name_b)}".ljust(16)
    total_sz = len(name_b) + len(payload)
    hdr = (
        hdr_name.encode("ascii")
        + b"0           0     0     100644  "
        + str(total_sz).ljust(10).encode("ascii")
        + b"`\n"
    )
    assert len(hdr) == 60
    body = hdr + name_b + payload
    if total_sz & 1:
        body += b"\n"
    return body

ar_blob = b"!<arch>\n" + make_ar_member("odd_member.o", b"abc") + make_ar_member("video_out_vulkan_context_moltenvk.m.o", b"xyz!")
parsed = ns["parse_bsd_ar_members"](ar_blob)
assert len(parsed) == 2
assert ar_blob[parsed[0][1]:parsed[0][1] + parsed[0][2]] == b"abc"
assert ar_blob[parsed[1][1]:parsed[1][1] + parsed[1][2]] == b"xyz!"

# 3. Synthetic Mach-O 64 object with _moltenvk_reconfig + 8-byte VO_NOTIMPL _moltenvk_control + __const relocations
text = struct.pack(
    "<IIII",
    0xF9402808,  # ldr x8, [x0, #80]
    0xF9401900,  # ldr x0, [x8, #48]
    0x12800040,  # mov w0, #-3 (VO_NOTIMPL)
    0xD65F03C0,  # ret
)
const_data = b"\x00" * 88
strtab = (
    b"\x00"
    b"_moltenvk_reconfig\x00"
    b"_moltenvk_control\x00"
    b"_moltenvk_init\x00"
    b"_moltenvk_uninit\x00"
    b"_ra_ctx_vulkan_moltenvk\x00"
)
names = ["_moltenvk_reconfig", "_moltenvk_control", "_moltenvk_init", "_moltenvk_uninit", "_ra_ctx_vulkan_moltenvk"]
vals = [0, 8, 16, 16, 16]
sects = [1, 1, 1, 1, 2]
symtab = bytearray()
for nm, val, sc in zip(names, vals, sects):
    strx = strtab.index(nm.encode("ascii") + b"\x00")
    symtab += struct.pack("<IBBHQ", strx, 0x0F, sc, 0, val)

relocs = b"".join(
    struct.pack("<II", off, (1 << 27) | idx)
    for off, idx in [(24, 0), (40, 1), (72, 2), (80, 3)]
)

seg_cmdsize = 72 + 80 * 2
sym_cmdsize = 24
hdr_end = 32 + seg_cmdsize + sym_cmdsize
text_off = hdr_end
const_off = text_off + len(text)
reloff = const_off + len(const_data)
symoff = reloff + len(relocs)
stroff = symoff + len(symtab)

mach_hdr = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 1, 2, seg_cmdsize + sym_cmdsize, 0, 0)
seg_cmd = struct.pack("<II16sQQQQIIII", 0x19, seg_cmdsize, b"", 0, len(text) + len(const_data), text_off, len(text) + len(const_data), 7, 7, 2, 0)
sect_text = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0, len(text), text_off, 2, 0, 0, 0x80000400, 0, 0, 0)
sect_const = struct.pack("<16s16sQQIIIIIIII", b"__const", b"__DATA", len(text), len(const_data), const_off, 3, reloff, 4, 0, 0, 0, 0)
sym_cmd = struct.pack("<IIIIII", 0x02, sym_cmdsize, symoff, len(names), stroff, len(strtab))
obj = mach_hdr + seg_cmd + sect_text + sect_const + sym_cmd + text + const_data + relocs + bytes(symtab) + strtab

sections, sym_list, syms, out_stroff = ns["parse_macho64_obj"](obj)
assert sections[(b"__DATA", b"__const")][1] == 88
assert syms["_moltenvk_control"][2] == 8
assert len(b"_ra_ctx_vulkan_moltenvk\x00") == len(b"_uzv_orig_moltenvk_fns_\x00") == 24
assert obj[out_stroff + syms["_ra_ctx_vulkan_moltenvk"][3]:out_stroff + syms["_ra_ctx_vulkan_moltenvk"][3] + 24] == b"_ra_ctx_vulkan_moltenvk\x00"
'''
    ]);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
  });

  test('iOS MPV MoltenVK resize notification symbols stay aligned across C bridge and Swift views', () {
    final fetchSh = File('ios/scripts/fetch_mpvkit.sh').readAsStringSync();
    final bridgeH = File('packages/novaplay_ios/ios/Classes/Player/UzvIosMpvBridge.h').readAsStringSync();
    final bridgeC = File('packages/novaplay_ios/ios/Classes/Player/UzvIosMpvBridge.c').readAsStringSync();
    final mpvSwift = File('packages/novaplay_ios/ios/Classes/Player/IosMpvKernel.swift').readAsStringSync();
    final kernelSwift = File('packages/novaplay_ios/ios/Classes/Player/IosPlayerKernel.swift').readAsStringSync();
    final vcSwift = File('packages/novaplay_ios/ios/Classes/Player/NativePlayerViewController.swift').readAsStringSync();

    expect(fetchSh, contains('_mpv_novaplay_notify_layer_resized'));
    expect(fetchSh, contains('void mpv_novaplay_notify_layer_resized('));
    expect(bridgeH, contains('void uzv_ios_mpv_notify_layer_resized(int64_t wid, int32_t width, int32_t height);'));
    expect(bridgeC, contains('dlsym(lib_handle, "mpv_novaplay_notify_layer_resized")'));
    expect(mpvSwift, contains('NovaMpvMetalLayer'));
    expect(mpvSwift, contains('uzv_ios_mpv_notify_layer_resized('));
    expect(kernelSwift, contains('func syncActiveBackendLayoutAfterTransition()'));
    expect(vcSwift, contains('syncActiveBackendLayoutAfterTransition()'));
  });
}
