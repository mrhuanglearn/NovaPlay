/*
 * JNI glue between MdkNative (Kotlin) and MDK's C API (libmdk.so, wang-bin's multimedia development kit).
 *
 * libmdk.so is dlopen()ed, not linked, so the app builds and runs without it (the kernel then falls back to Exo).
 * OBSERVED: UZN 1.1.7 ships libmdk.so (MDK 0.38, arm64-v8a only) next to libffmpeg.so / libass.so and offers
 * 播放内核 → MDK (MDK); 1.1.13 does not have it. The original drives MDK through the fvp Flutter plugin (libfvp.so);
 * UZV renders into an Android Surface instead, so its page keeps the same native controls for every kernel.
 *
 * The mdkPlayerAPI struct is a table of pointers (the `object` pointer, then function pointers). Its member order is
 * taken from fvp's ffigen bindings of the MDK 0.35 C headers (lib/src/generated_bindings.dart); MDK only appends new
 * members, so the prefix used here is the same in 0.38. Cross-checked against libfvp.so from the same UZN build, whose
 * calls load the table at 0xa8 (updateNativeSurface), 0x88 (onStateChanged), 0x170 (onEvent), 0x188 (setProperty),
 * 0x218 (onMediaStatus), 0x138 (seekWithFlags) - the offsets below.
 */
#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TAG "uzv_mdk"
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

/* ---- MDK C ABI (subset) ------------------------------------------------------------------------------------------ */

enum { MDK_TYPE_VIDEO = 0, MDK_TYPE_AUDIO = 1, MDK_TYPE_SUBTITLE = 3 };
enum { MDK_SEEK_DEFAULT = 1282 }; /* FromStart | KeyFrame | InCache */

/* Indexes into mdkPlayerAPI (pointer-sized slots; slot 0 is the mdkPlayer* object). */
enum {
    I_OBJECT = 0, I_SET_MEDIA = 3, I_SET_MEDIA_FOR_TYPE = 4, I_PREPARE = 13, I_MEDIA_INFO = 14, I_SET_STATE = 15,
    I_STATE = 16, I_ON_STATE_CHANGED = 17, I_MEDIA_STATUS = 19, I_UPDATE_NATIVE_SURFACE = 21, I_SET_ASPECT_RATIO = 28,
    I_POSITION = 38, I_SEEK_WITH_FLAGS = 39, I_SET_PLAYBACK_RATE = 41, I_BUFFERED = 43, I_ON_EVENT = 46,
    I_SET_PROPERTY = 49, I_GET_PROPERTY = 50, I_SET_ACTIVE_TRACKS = 61, I_SET_DECODERS = 62, I_ON_MEDIA_STATUS = 67,
};

typedef uint64_t MDK_CallbackToken;
typedef struct { void (*cb)(int32_t state, void *opaque); void *opaque; } mdkStateChangedCallback;
typedef struct { bool (*cb)(int32_t oldValue, int32_t newValue, void *opaque); void *opaque; } mdkMediaStatusCallback;
typedef struct { bool (*cb)(int64_t position, bool *boost, void *opaque); void *opaque; } mdkPrepareCallback;
typedef struct { void (*cb)(int64_t ms, void *opaque); void *opaque; } mdkSeekCallback;

typedef struct {
    int64_t error;
    const char *category;
    const char *detail;
    union { struct { int stream; } decoder; struct { int width, height; } video; } u;
} mdkMediaEvent;
typedef struct { bool (*cb)(const mdkMediaEvent *, void *opaque); void *opaque; } mdkMediaEventCallback;

typedef struct { int index; int64_t start_time, duration, frames; int rotation; const void *priv; } mdkVideoStreamInfo;
typedef struct { int index; int64_t start_time, duration, frames; const void *priv; } mdkAudioStreamInfo;
typedef struct { int index; int64_t start_time, duration; const void *priv; } mdkSubtitleStreamInfo;
typedef struct {
    int64_t start_time, duration, bit_rate, size;
    const char *format;
    int streams;
    mdkAudioStreamInfo *audio; int nb_audio;
    mdkVideoStreamInfo *video; int nb_video;
    mdkSubtitleStreamInfo *subtitle; int nb_subtitle;
} mdkMediaInfo; /* prefix only: MDK owns and fills it */
typedef struct {
    const char *codec; uint32_t codec_tag; const uint8_t *extra_data; int extra_data_size; int64_t bit_rate;
    int profile, level; float frame_rate; int format; const char *format_name; int width, height, b_frames; float par;
} mdkVideoCodecParameters; /* prefix only: filled into a larger zeroed buffer, see video_params() */
typedef struct { const char *key; const char *value; const void *priv; } mdkStringMapEntry;

typedef void **(*api_new_fn)(void);
typedef void (*api_delete_fn)(void ***);
typedef int (*version_fn)(void);
typedef void *(*java_vm_fn)(void *);
typedef void (*video_params_fn)(const mdkVideoStreamInfo *, void *);
typedef bool (*stream_meta_fn)(const void *, mdkStringMapEntry *);

static struct {
    void *lib;
    char error[256];
    api_new_fn api_new;
    api_delete_fn api_delete;
    version_fn version;
    java_vm_fn java_vm;
    video_params_fn video_params;
    stream_meta_fn audio_meta, subtitle_meta;
} g;

static JavaVM *g_vm;
static jclass g_native;      /* MdkNative */
static jmethodID g_on_event; /* static void onMdkEvent(long id, int kind, int a, int b, String text) */
static pthread_key_t g_detach_key;
static pthread_once_t g_load_once = PTHREAD_ONCE_INIT;

typedef struct {
    void **api;
    jlong id;
    jobject surface; /* global ref of the android.view.Surface MDK draws into */
    float aspect;    /* the last setAspectRatio value, applied again to each new surface */
    bool has_aspect;
    volatile int alive;
    MDK_CallbackToken event_token, status_token;
} Player;

#define CALL(p, idx, type, ...) ((type)((p)->api[idx]))((p)->api[I_OBJECT], ##__VA_ARGS__)

/* ---- loading ------------------------------------------------------------------------------------------------------ */

static void load_once(void) {
    g.lib = dlopen("libmdk.so", RTLD_NOW);
    if (!g.lib) {
        snprintf(g.error, sizeof g.error, "dlopen(libmdk.so) failed: %s", dlerror());
        return;
    }
    g.api_new = (api_new_fn)dlsym(g.lib, "mdkPlayerAPI_new");
    g.api_delete = (api_delete_fn)dlsym(g.lib, "mdkPlayerAPI_delete");
    g.version = (version_fn)dlsym(g.lib, "MDK_version");
    g.java_vm = (java_vm_fn)dlsym(g.lib, "MDK_javaVM");
    g.video_params = (video_params_fn)dlsym(g.lib, "MDK_VideoStreamCodecParameters");
    g.audio_meta = (stream_meta_fn)dlsym(g.lib, "MDK_AudioStreamMetadata");
    g.subtitle_meta = (stream_meta_fn)dlsym(g.lib, "MDK_SubtitleStreamMetadata");
    if (!g.api_new || !g.api_delete || !g.version) {
        snprintf(g.error, sizeof g.error, "libmdk.so lacks mdkPlayerAPI_new / mdkPlayerAPI_delete / MDK_version");
        dlclose(g.lib);
        g.lib = NULL;
        return;
    }
    if (g.java_vm && g_vm) g.java_vm(g_vm); /* MediaCodec and Surface need the VM; libmdk's own JNI_OnLoad may not have run */
    /* MDK writes its log to stdout, which the Node bridge sends to logcat as NODEJS. For a diagnosis, call
     * MDK_setLogLevel(4) here (Debug); MDK_setLogHandler did not route the messages to a handler of ours (2026-11-10). */
}

static bool loaded(void) {
    pthread_once(&g_load_once, load_once);
    return g.lib != NULL;
}

static void detach_thread(void *env) {
    (void)env;
    if (g_vm) (*g_vm)->DetachCurrentThread(g_vm);
}

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;
    JNIEnv *env;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    jclass c = (*env)->FindClass(env, "com/example/uzv/native_player/kernel/mdk/MdkNative");
    if (!c) return JNI_ERR;
    g_native = (*env)->NewGlobalRef(env, c);
    g_on_event = (*env)->GetStaticMethodID(env, c, "onMdkEvent", "(JIIILjava/lang/String;)V");
    if (!g_on_event) return JNI_ERR;
    pthread_key_create(&g_detach_key, detach_thread);
    return JNI_VERSION_1_6;
}

/* Called from MDK's threads: attach once per thread, detached when the thread exits. */
static JNIEnv *thread_env(void) {
    JNIEnv *env = NULL;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK) return env;
    if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) return NULL;
    pthread_setspecific(g_detach_key, env);
    return env;
}

static void post(Player *p, int kind, int a, int b, const char *text) {
    if (!p->alive) return;
    JNIEnv *env = thread_env();
    if (!env) return;
    jstring s = text ? (*env)->NewStringUTF(env, text) : NULL;
    (*env)->CallStaticVoidMethod(env, g_native, g_on_event, p->id, kind, a, b, s);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (s) (*env)->DeleteLocalRef(env, s);
}

/* kinds: 1 = state (a), 2 = media status (a = new, b = old), 3 = event (a = error, text = "category\tdetail") */
static void on_state(int32_t state, void *opaque) { post(opaque, 1, state, 0, NULL); }
static bool on_status(int32_t old_value, int32_t new_value, void *opaque) {
    post(opaque, 2, new_value, old_value, NULL);
    return true;
}
static bool on_event(const mdkMediaEvent *e, void *opaque) {
    char text[512];
    snprintf(text, sizeof text, "%s\t%s", e->category ? e->category : "", e->detail ? e->detail : "");
    post(opaque, 3, (int)e->error, 0, text);
    return false;
}

/* ---- JNI ---------------------------------------------------------------------------------------------------------- */

#define JNI(name) Java_com_example_uzv_native_1player_kernel_mdk_MdkNative_##name
#define P ((Player *)(intptr_t)handle)

JNIEXPORT jstring JNICALL JNI(probeError)(JNIEnv *env, jclass cls) {
    (void)cls;
    return loaded() ? NULL : (*env)->NewStringUTF(env, g.error[0] ? g.error : "libmdk.so could not be loaded");
}

JNIEXPORT jint JNICALL JNI(version)(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    return loaded() ? g.version() : 0;
}

static const char *const HW_DECODERS[] = {"AMediaCodec", "FFmpeg", "dav1d", NULL};
static const char *const SW_DECODERS[] = {"FFmpeg", "dav1d", NULL};

JNIEXPORT jlong JNICALL JNI(create)(JNIEnv *env, jclass cls, jlong id, jboolean hw) {
    (void)env; (void)cls;
    if (!loaded()) return 0;
    void **api = g.api_new();
    if (!api) return 0;
    Player *p = calloc(1, sizeof(Player));
    p->api = api;
    p->id = id;
    p->alive = 1;
    CALL(p, I_SET_DECODERS, void (*)(void *, int32_t, const char *const *), MDK_TYPE_VIDEO, hw ? HW_DECODERS : SW_DECODERS);
    mdkStateChangedCallback sc = {on_state, p};
    CALL(p, I_ON_STATE_CHANGED, void (*)(void *, mdkStateChangedCallback), sc);
    mdkMediaStatusCallback ms = {on_status, p};
    CALL(p, I_ON_MEDIA_STATUS, void (*)(void *, mdkMediaStatusCallback, MDK_CallbackToken *), ms, &p->status_token);
    mdkMediaEventCallback ev = {on_event, p};
    CALL(p, I_ON_EVENT, void (*)(void *, mdkMediaEventCallback, MDK_CallbackToken *), ev, &p->event_token);
    return (jlong)(intptr_t)p;
}

JNIEXPORT void JNICALL JNI(destroy)(JNIEnv *env, jclass cls, jlong handle) {
    (void)cls;
    Player *p = P;
    if (!p) return;
    p->alive = 0;
    CALL(p, I_SET_STATE, void (*)(void *, int32_t), 0);
    CALL(p, I_UPDATE_NATIVE_SURFACE, void (*)(void *, void *, int, int, int32_t), NULL, -1, -1, 0);
    void **api = p->api;
    g.api_delete(&api);
    if (p->surface) (*env)->DeleteGlobalRef(env, p->surface);
    free(p);
}

static const char *chars(JNIEnv *env, jstring s) { return s ? (*env)->GetStringUTFChars(env, s, NULL) : NULL; }
static void release_chars(JNIEnv *env, jstring s, const char *c) { if (s && c) (*env)->ReleaseStringUTFChars(env, s, c); }

JNIEXPORT void JNICALL JNI(setMedia)(JNIEnv *env, jclass cls, jlong handle, jstring url, jint type) {
    (void)cls;
    const char *u = chars(env, url);
    if (type < 0) CALL(P, I_SET_MEDIA, void (*)(void *, const char *), u ? u : "");
    else CALL(P, I_SET_MEDIA_FOR_TYPE, void (*)(void *, const char *, int32_t), u ? u : "", type);
    release_chars(env, url, u);
}

JNIEXPORT void JNICALL JNI(setProperty)(JNIEnv *env, jclass cls, jlong handle, jstring key, jstring value) {
    (void)cls;
    const char *k = chars(env, key), *v = chars(env, value);
    CALL(P, I_SET_PROPERTY, void (*)(void *, const char *, const char *), k, v ? v : "");
    release_chars(env, key, k);
    release_chars(env, value, v);
}

JNIEXPORT jstring JNICALL JNI(getProperty)(JNIEnv *env, jclass cls, jlong handle, jstring key) {
    (void)cls;
    const char *k = chars(env, key);
    const char *v = CALL(P, I_GET_PROPERTY, const char *(*)(void *, const char *), k);
    release_chars(env, key, k);
    return v ? (*env)->NewStringUTF(env, v) : NULL;
}

JNIEXPORT void JNICALL JNI(prepare)(JNIEnv *env, jclass cls, jlong handle, jlong startMs) {
    (void)env; (void)cls;
    mdkPrepareCallback cb = {NULL, NULL};
    CALL(P, I_PREPARE, void (*)(void *, int64_t, mdkPrepareCallback, int32_t), (int64_t)startMs, cb, MDK_SEEK_DEFAULT);
}

JNIEXPORT void JNICALL JNI(setState)(JNIEnv *env, jclass cls, jlong handle, jint state) {
    (void)env; (void)cls;
    CALL(P, I_SET_STATE, void (*)(void *, int32_t), state);
}

JNIEXPORT jint JNICALL JNI(state)(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    return CALL(P, I_STATE, int32_t (*)(void *));
}

JNIEXPORT jint JNICALL JNI(mediaStatus)(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    return CALL(P, I_MEDIA_STATUS, int32_t (*)(void *));
}

JNIEXPORT jlong JNICALL JNI(position)(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    return CALL(P, I_POSITION, int64_t (*)(void *));
}

static const mdkMediaInfo *info(Player *p) { return CALL(p, I_MEDIA_INFO, const mdkMediaInfo *(*)(void *)); }

JNIEXPORT jlong JNICALL JNI(duration)(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    const mdkMediaInfo *i = info(P);
    return i ? i->duration : 0;
}

JNIEXPORT jlong JNICALL JNI(buffered)(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    return CALL(P, I_BUFFERED, int64_t (*)(void *, int64_t *), NULL);
}

JNIEXPORT jboolean JNICALL JNI(seek)(JNIEnv *env, jclass cls, jlong handle, jlong ms) {
    (void)env; (void)cls;
    mdkSeekCallback cb = {NULL, NULL};
    return CALL(P, I_SEEK_WITH_FLAGS, bool (*)(void *, int64_t, int32_t, mdkSeekCallback), (int64_t)ms, MDK_SEEK_DEFAULT, cb);
}

JNIEXPORT void JNICALL JNI(setPlaybackRate)(JNIEnv *env, jclass cls, jlong handle, jfloat rate) {
    (void)env; (void)cls;
    CALL(P, I_SET_PLAYBACK_RATE, void (*)(void *, float), rate);
}

/* 0 = stretch (IgnoreAspectRatio), FLT_EPSILON = keep (KeepAspectRatio), -FLT_EPSILON = crop (KeepAspectRatioCrop).
 * The value belongs to one video output, keyed by the opaque pointer MDK renders for: here the Surface global ref that
 * updateNativeSurface was given. OBSERVED (phone, 2026-11-10, MDK log): with vo NULL MDK made a second, default output
 * ("getVideoOutContext 0x0", "vo count: 2"), the picture went to the Surface's output, and changing the value later had no
 * effect on it. So it is kept here and applied to the current surface, and again to each new one. */
JNIEXPORT void JNICALL JNI(setAspectRatio)(JNIEnv *env, jclass cls, jlong handle, jfloat value) {
    (void)env; (void)cls;
    Player *p = P;
    p->aspect = value;
    p->has_aspect = true;
    if (p->surface) CALL(p, I_SET_ASPECT_RATIO, void (*)(void *, float, void *), value, p->surface);
}

/* surface == null detaches; MDK renders into the window on its own thread. */
JNIEXPORT void JNICALL JNI(setSurface)(JNIEnv *env, jclass cls, jlong handle, jobject surface, jint w, jint h) {
    (void)cls;
    Player *p = P;
    /* On Android MDK takes the android.view.Surface object and calls ANativeWindow_fromSurface on it itself (OBSERVED:
     * UZN 1.1.7's libfvp nativeSetSurface hands it the jobject, once as a NewGlobalRef). The first version passed an
     * ANativeWindow* here, which MDK read as a jobject: SIGSEGV in GetObjectField on the phone (2026-11-10). A global
     * ref, since MDK's render thread keeps using it after this call returns. */
    if (surface && p->surface && (*env)->IsSameObject(env, surface, p->surface)) { /* a resize: same ref, new size */
        CALL(p, I_UPDATE_NATIVE_SURFACE, void (*)(void *, void *, int, int, int32_t), p->surface, w, h, 0);
        return;
    }
    jobject ref = surface ? (*env)->NewGlobalRef(env, surface) : NULL;
    CALL(p, I_UPDATE_NATIVE_SURFACE, void (*)(void *, void *, int, int, int32_t), ref, ref ? w : -1, ref ? h : -1, 0);
    if (ref && p->has_aspect) CALL(p, I_SET_ASPECT_RATIO, void (*)(void *, float, void *), p->aspect, ref);
    if (p->surface) (*env)->DeleteGlobalRef(env, p->surface);
    p->surface = ref;
}

JNIEXPORT void JNICALL JNI(setActiveTracks)(JNIEnv *env, jclass cls, jlong handle, jint type, jintArray tracks) {
    (void)cls;
    jsize n = tracks ? (*env)->GetArrayLength(env, tracks) : 0;
    jint *t = n > 0 ? (*env)->GetIntArrayElements(env, tracks, NULL) : NULL;
    CALL(P, I_SET_ACTIVE_TRACKS, void (*)(void *, int32_t, const int *, size_t), type, (const int *)t, (size_t)n);
    if (t) (*env)->ReleaseIntArrayElements(env, tracks, t, JNI_ABORT);
}

/* [width, height, fps, bitrate (bits/s)] of the first video stream, or null before the media is loaded. */
JNIEXPORT jdoubleArray JNICALL JNI(videoInfo)(JNIEnv *env, jclass cls, jlong handle) {
    (void)cls;
    const mdkMediaInfo *i = info(P);
    if (!i || i->nb_video <= 0 || !i->video || !g.video_params) return NULL;
    uint8_t buf[1024]; /* larger than any version of mdkVideoCodecParameters */
    memset(buf, 0, sizeof buf);
    g.video_params(&i->video[0], buf);
    const mdkVideoCodecParameters *c = (const mdkVideoCodecParameters *)buf;
    jdouble v[4] = {c->width, c->height, c->frame_rate, (double)(c->bit_rate > 0 ? c->bit_rate : i->bit_rate)};
    jdoubleArray out = (*env)->NewDoubleArray(env, 4);
    (*env)->SetDoubleArrayRegion(env, out, 0, 4, v);
    return out;
}

JNIEXPORT jstring JNICALL JNI(videoCodec)(JNIEnv *env, jclass cls, jlong handle) {
    (void)cls;
    const mdkMediaInfo *i = info(P);
    if (!i || i->nb_video <= 0 || !i->video || !g.video_params) return NULL;
    uint8_t buf[1024];
    memset(buf, 0, sizeof buf);
    g.video_params(&i->video[0], buf);
    const char *codec = ((const mdkVideoCodecParameters *)buf)->codec;
    return codec ? (*env)->NewStringUTF(env, codec) : NULL;
}

/* One "key=value\tkey=value" string of metadata (language, title, ...) per audio (type 1) / subtitle (type 3) stream. */
JNIEXPORT jobjectArray JNICALL JNI(tracks)(JNIEnv *env, jclass cls, jlong handle, jint type) {
    (void)cls;
    const mdkMediaInfo *i = info(P);
    int n = !i ? 0 : type == MDK_TYPE_AUDIO ? i->nb_audio : type == MDK_TYPE_SUBTITLE ? i->nb_subtitle : 0;
    jclass str = (*env)->FindClass(env, "java/lang/String");
    jobjectArray out = (*env)->NewObjectArray(env, n, str, NULL);
    for (int k = 0; k < n; k++) {
        char text[1024] = "";
        size_t len = 0;
        mdkStringMapEntry e;
        memset(&e, 0, sizeof e);
        const void *stream = type == MDK_TYPE_AUDIO ? (const void *)&i->audio[k] : (const void *)&i->subtitle[k];
        stream_meta_fn meta = type == MDK_TYPE_AUDIO ? g.audio_meta : g.subtitle_meta;
        while (meta && meta(stream, &e) && len < sizeof text - 2) {
            int w = snprintf(text + len, sizeof text - len, "%s%s=%s", len ? "\t" : "", e.key ? e.key : "", e.value ? e.value : "");
            if (w < 0) break;
            len += (size_t)w;
        }
        jstring s = (*env)->NewStringUTF(env, text);
        (*env)->SetObjectArrayElement(env, out, k, s);
        (*env)->DeleteLocalRef(env, s);
    }
    return out;
}
