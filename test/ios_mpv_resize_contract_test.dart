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

    final syncBlockStart = vcSwift.indexOf('private func syncOrientationForCurrentState(');
    expect(syncBlockStart, greaterThanOrEqualTo(0));
    final syncBlock = vcSwift.substring(syncBlockStart, syncBlockStart + 600);
    final manualIdx = syncBlock.indexOf('if manualOrientationThisEpisode {');
    final switchIdx = syncBlock.indexOf('switch mode {');
    expect(manualIdx, greaterThanOrEqualTo(0));
    expect(switchIdx, greaterThan(manualIdx));

    final cycleStart = vcSwift.indexOf('private func cycleOrientationStep()');
    expect(cycleStart, greaterThanOrEqualTo(0));
    final cycleBlock = vcSwift.substring(cycleStart, cycleStart + 520);
    expect(cycleBlock, contains('if isTransitioningOrientation {'));
    expect(cycleBlock, contains('else if let inflight = inFlightGeometryStep'));

    final ctrlSwift = File('packages/novaplay_ios/ios/Classes/Player/IosPlayerController.swift').readAsStringSync();
    final panelsSwift = File('packages/novaplay_ios/ios/Classes/Player/IosPlayerPanels.swift').readAsStringSync();
    expect(ctrlSwift, contains('kernel.videoView.naturalVideoSize = kSize'));
    expect(ctrlSwift, contains('kernel.videoView.naturalVideoSize = .zero'));

    final effSizeStart = ctrlSwift.indexOf('var effectiveDisplayVideoSize: CGSize {');
    expect(effSizeStart, greaterThanOrEqualTo(0));
    expect(ctrlSwift.substring(effSizeStart, effSizeStart + 180), contains('guard !resolvingSource else { return .zero }'));

    final loadPayloadStart = ctrlSwift.indexOf('private func loadPayload(');
    expect(loadPayloadStart, greaterThanOrEqualTo(0));
    expect(effSizeStart, greaterThan(loadPayloadStart));
    final loadPayloadBlock = ctrlSwift.substring(loadPayloadStart, effSizeStart);
    final kernelLoadIdx = loadPayloadBlock.indexOf('kernel.load(');
    final postLoadMetricsIdx = loadPayloadBlock.indexOf('uiDelegate?.controllerDidUpdateMetrics()');
    expect(kernelLoadIdx, greaterThan(0));
    expect(postLoadMetricsIdx, greaterThan(kernelLoadIdx));

    expect(vcSwift, contains('if overlayHost.isMenuOpen {'));
    expect(vcSwift, contains('if overlayHost.isPanelOpen && size != view.bounds.size {'));
    expect(vcSwift, contains('private func syncSceneOrientationFlipIfNeeded()'));
    expect(panelsSwift, contains('sheet.safeAreaLayoutGuide.trailingAnchor'));
  });

  test('uzv_moltenvk_resize_shim C state machine handles stale extent, 1x1 init, 1px rounding, and concurrent notify race', () async {
    final res = await Process.run('python3', [
      '-c',
      r'''
import pathlib, re, subprocess, tempfile

sh_text = pathlib.Path("ios/scripts/fetch_mpvkit.sh").read_text(encoding="utf-8")
m = re.search(r'shim_m\.write_text\(\s*"""(.*?)""",\s*encoding="utf-8"', sh_text, re.S)
assert m, "Could not extract shim_m C source from fetch_mpvkit.sh"
shim_src = m.group(1)

harness = r"""
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

struct vo {
    char pad[248];
    int dwidth;
    int dheight;
};

struct fake_priv {
    char pad[48];
    void *layer;
};

struct ra_ctx {
    struct vo *vo;
    char pad[72];
    struct fake_priv *priv;
};

static double g_layer_w = 0.0;
static double g_layer_h = 0.0;
static int g_mock_swapchain_w = 0;
static int g_mock_swapchain_h = 0;
static int g_resize_calls = 0;
static int g_wakeups = 0;
static int g_inject_concurrent_notify = 0;
static int64_t g_concurrent_wid = 0;
static int32_t g_concurrent_w = 0;
static int32_t g_concurrent_h = 0;

void uzv_test_query_metal_drawable_size(void *layer, double *out_w, double *out_h) {
    (void)layer;
    *out_w = g_layer_w;
    *out_h = g_layer_h;
}

void vo_wakeup(struct vo *vo) {
    (void)vo;
    g_wakeups += 1;
}

static bool orig_init_ok(struct ra_ctx *ctx) {
    (void)ctx;
    return true;
}

static void orig_uninit_ok(struct ra_ctx *ctx) {
    (void)ctx;
}

static int orig_ctrl_stub(struct ra_ctx *ctx, int *events, int req, void *arg) {
    (void)ctx; (void)events; (void)req; (void)arg;
    return -3;
}

const void * const uzv_orig_moltenvk_fns_[11] = {
    [0] = "vulkan",
    [1] = "moltenvk",
    [3] = NULL,
    [5] = (const void *)orig_ctrl_stub,
    [9] = (const void *)orig_init_ok,
    [10] = (const void *)orig_uninit_ok,
};

extern const void * const ra_ctx_vulkan_moltenvk[11];
extern void mpv_novaplay_notify_layer_resized(int64_t wid, int32_t width, int32_t height);

bool ra_vk_ctx_resize(struct ra_ctx *ctx, int width, int height) {
    g_resize_calls += 1;
    int actual_w = g_mock_swapchain_w > 0 ? g_mock_swapchain_w : width;
    int actual_h = g_mock_swapchain_h > 0 ? g_mock_swapchain_h : height;
    ctx->vo->dwidth = actual_w;
    ctx->vo->dheight = actual_h;
    if (g_inject_concurrent_notify) {
        g_inject_concurrent_notify = 0;
        g_layer_w = (double)g_concurrent_w;
        g_layer_h = (double)g_concurrent_h;
        mpv_novaplay_notify_layer_resized(g_concurrent_wid, g_concurrent_w, g_concurrent_h);
    }
    return true;
}

int main(void) {
    bool (*fn_init)(struct ra_ctx *) = (bool (*)(struct ra_ctx *))ra_ctx_vulkan_moltenvk[9];
    void (*fn_uninit)(struct ra_ctx *) = (void (*)(struct ra_ctx *))ra_ctx_vulkan_moltenvk[10];
    int (*fn_ctrl)(struct ra_ctx *, int *, int, void *) =
        (int (*)(struct ra_ctx *, int *, int, void *))ra_ctx_vulkan_moltenvk[5];

    struct vo vo = {0};
    void *fake_layer = (void *)(intptr_t)0x12345678;
    int64_t wid = (int64_t)(intptr_t)fake_layer;
    struct fake_priv priv = {0};
    priv.layer = fake_layer;
    struct ra_ctx ctx = {0};
    ctx.vo = &vo;
    ctx.priv = &priv;

    /* 1. 1x1 initial swapchain extent followed by real 2556x1179 layout */
    g_layer_w = 2556.0;
    g_layer_h = 1179.0;
    g_mock_swapchain_w = 1;
    g_mock_swapchain_h = 1;
    assert(fn_init(&ctx) == true);
    assert(vo.dwidth == 2556 && vo.dheight == 1179); /* 1x1 clobber guarded */

    g_mock_swapchain_w = 2556;
    g_mock_swapchain_h = 1179;
    int ev = 0;
    int calls_before = g_resize_calls;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    assert(g_resize_calls == calls_before + 1);
    assert((ev & 3) == 3);

    /* Settled: next poll does zero redundant swapchain rebuilds */
    ev = 0;
    calls_before = g_resize_calls;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    assert(g_resize_calls == calls_before);
    assert(ev == 0);

    /* 2. Stale pre-commit swapchain extent on rotation (2556x1179 -> 1179x2556) */
    g_layer_w = 1179.0;
    g_layer_h = 2556.0;
    mpv_novaplay_notify_layer_resized(wid, 1179, 2556);
    assert(g_wakeups == 1);

    /* Tick 1: MoltenVK still sees stale 2556x1179 before CATransaction commit */
    g_mock_swapchain_w = 2556;
    g_mock_swapchain_h = 1179;
    ev = 0;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);

    /* Tick 2: CATransaction commits -> MoltenVK now creates 1179x2556 swapchain! */
    g_mock_swapchain_w = 1179;
    g_mock_swapchain_h = 2556;
    ev = 0;
    calls_before = g_resize_calls;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    assert(g_resize_calls == calls_before + 1);
    assert(vo.dwidth == 1179 && vo.dheight == 2556);
    assert((ev & 3) == 3);

    /* Tick 3: Settled at 1179x2556 */
    ev = 0;
    calls_before = g_resize_calls;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    assert(g_resize_calls == calls_before);

    /* 3. 1px float truncation vs rounding tolerance (1080x1920 vs 1079x1920) does not spin */
    g_layer_w = 1080.0;
    g_layer_h = 1920.0;
    g_mock_swapchain_w = 1079;
    g_mock_swapchain_h = 1920;
    mpv_novaplay_notify_layer_resized(wid, 1080, 1920);
    ev = 0;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    calls_before = g_resize_calls;
    ev = 0;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    assert(g_resize_calls == calls_before);

    /* 4. Concurrent notify_layer_resized arriving mid-ra_vk_ctx_resize is NOT clobbered */
    g_layer_w = 2556.0;
    g_layer_h = 1179.0;
    g_mock_swapchain_w = 0;
    g_mock_swapchain_h = 0;
    g_inject_concurrent_notify = 1;
    g_concurrent_wid = wid;
    g_concurrent_w = 1179;
    g_concurrent_h = 2556;
    mpv_novaplay_notify_layer_resized(wid, 2556, 1179);
    ev = 0;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    /* Next tick MUST process the mid-resize concurrent notification to 1179x2556 */
    calls_before = g_resize_calls;
    ev = 0;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    assert(g_resize_calls == calls_before + 1);
    assert(vo.dwidth == 1179 && vo.dheight == 2556);

    /* 5. Pathological non-converging extent stops retrying after UZV_MAX_EXTENT_RETRIES */
    g_layer_w = 2556.0;
    g_layer_h = 1179.0;
    g_mock_swapchain_w = 800;
    g_mock_swapchain_h = 600;
    mpv_novaplay_notify_layer_resized(wid, 2556, 1179);
    for (int i = 0; i < 12; i++) {
        ev = 0;
        assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    }
    calls_before = g_resize_calls;
    assert(fn_ctrl(&ctx, &ev, 2, NULL) == 1);
    assert(g_resize_calls == calls_before);

    fn_uninit(&ctx);
    return 0;
}
"""

with tempfile.TemporaryDirectory() as td:
    td_p = pathlib.Path(td)
    shim_c = td_p / "shim.c"
    main_c = td_p / "main.c"
    exe = td_p / "test_shim"
    shim_c.write_text(shim_src, encoding="utf-8")
    main_c.write_text(harness, encoding="utf-8")
    defs = [
        "-DUZV_FNS_PTR_COUNT=11",
        "-DUZV_FNS_TYPE_IDX=0",
        "-DUZV_FNS_NAME_IDX=1",
        "-DUZV_FNS_RECONFIG_IDX=3",
        "-DUZV_FNS_CONTROL_IDX=5",
        "-DUZV_FNS_INIT_IDX=9",
        "-DUZV_FNS_UNINIT_IDX=10",
        "-DUZV_RA_CTX_PRIV_OFFSET=80",
        "-DUZV_PRIV_LAYER_OFFSET=48",
        "-DUZV_VO_DWIDTH_OFFSET=248",
    ]
    subprocess.run(
        ["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", *defs, str(shim_c), str(main_c), "-pthread", "-lm", "-o", str(exe)],
        check=True,
    )
    subprocess.run([str(exe)], check=True)
'''
    ]);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
  });
}
