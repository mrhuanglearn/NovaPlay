/*
 * JNI glue between com.example.uzv.native_player.kernel.mpv.MpvNative and libmpv.
 *
 * Design follows what was OBSERVED in the original libuzn_mpv.so (ANALYSIS.md): libmpv.so is dlopen()ed at runtime
 * (no link-time dependency, so probe() can report a missing/!loadable libmpv instead of the whole app failing to start),
 * the 18 mpv entry points are resolved with dlsym, the render API uses the "opengl" backend with eglGetProcAddress, the
 * render update callback calls the static Kotlin method onMpvRenderUpdate()V, and log lines are formatted "[prefix] text".
 * The code itself is written from scratch; the waitEvent() int[] layout is this project's own contract (see below).
 *
 * waitEvent() returns int[4] = { event_id, error, reply_userdata (low 32 bits), extra }:
 *   extra = reason for MPV_EVENT_END_FILE, the value format for MPV_EVENT_PROPERTY_CHANGE (0 = property unavailable),
 *           the log level for MPV_EVENT_LOG_MESSAGE, else 0.
 *   For END_FILE the "error" slot carries the loading error of mpv_event_end_file (when reason == ERROR).
 *   Property values are not carried; the caller reads them back with getProperty / getPropertyString.
 *   Log messages are not carried either; they are appended to an internal ring buffer (getLastLogMessages).
 */
#include <dlfcn.h>
#ifdef __ANDROID__
#include <android/log.h>
#endif
#include <jni.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mpv_abi_fn.h"
#include "mpv_abi_types.h"

/* Overridable so the host test can point the glue at stub libraries. */
#ifndef UZV_MPV_LIB
#define UZV_MPV_LIB "libmpv.so"
#endif
#ifndef UZV_EGL_LIB
#define UZV_EGL_LIB "libEGL.so"
#endif

#define JNI_FN(ret, name) JNIEXPORT ret JNICALL Java_com_example_uzv_native_1player_kernel_mpv_MpvNative_##name

#ifdef __ANDROID__
#define ATTACH_ENV_T JNIEnv **
#else
#define ATTACH_ENV_T void **
#endif

/* ---- libmpv, resolved lazily -------------------------------------------------------------------------------------- */

typedef struct {
#define X(name, ret, args) ret(*name) args;
    UZV_MPV_FUNCTIONS(X)
#undef X
} MpvApi;

static MpvApi api;
static pthread_mutex_t load_lock = PTHREAD_MUTEX_INITIALIZER;
static int load_state; /* 0 = not tried, 1 = loaded, -1 = failed */
static char load_detail[512] = "libmpv not probed yet";
static JavaVM *java_vm; /* set in JNI_OnLoad */

static void log_append(const char *prefix, const char *text);

/* FFmpeg's MediaCodec decoders and mpv's audiotrack / aimagereader code reach Java through the JavaVM registered with
 * libavcodec. Without it hwdec=mediacodec-copy and ao=audiotrack fail with "No Java virtual machine has been registered"
 * and mpv silently falls back to software decoding and OpenSL ES (seen on 2026-11-08 under Waydroid). The original glue
 * has the same gap (OBSERVED: no av_jni_* import or string in libuzn_mpv.so); registering the VM is this project's fix.
 * dlsym on the libmpv handle also searches its DT_NEEDED libraries, which is where libavcodec comes in. */
static void register_java_vm(void *lib) {
    int (*set_vm)(void *, void *) = NULL;
    *(void **)(&set_vm) = dlsym(lib, "av_jni_set_java_vm");
    if (!set_vm || !java_vm) return; /* host tests use stub libraries without libavcodec */
    if (set_vm(java_vm, NULL) < 0) log_append("uzv_mpv", "av_jni_set_java_vm failed");
}

static int load_mpv(void) {
    pthread_mutex_lock(&load_lock);
    if (load_state == 0) {
        void *lib = dlopen(UZV_MPV_LIB, RTLD_NOW | RTLD_LOCAL);
        if (!lib) {
            const char *err = dlerror();
            snprintf(load_detail, sizeof load_detail, "dlopen(%s) failed: %s", UZV_MPV_LIB, err ? err : "unknown error");
            load_state = -1;
        } else {
            const char *missing = NULL;
#define X(name, ret, args)                                  \
    if (!missing) {                                         \
        *(void **)(&api.name) = dlsym(lib, #name);          \
        if (!api.name) missing = #name;                     \
    }
            UZV_MPV_FUNCTIONS(X)
#undef X
            if (missing) {
                snprintf(load_detail, sizeof load_detail, "%s loaded but symbol %s is missing", UZV_MPV_LIB, missing);
                memset(&api, 0, sizeof api);
                dlclose(lib);
                load_state = -1;
            } else {
                unsigned long (*version)(void) = NULL;
                *(void **)(&version) = dlsym(lib, "mpv_client_api_version");
                if (version) {
                    unsigned long v = version();
                    snprintf(load_detail, sizeof load_detail, "%s loaded, client API %lu.%lu", UZV_MPV_LIB, v >> 16, v & 0xffff);
                } else {
                    snprintf(load_detail, sizeof load_detail, "%s loaded", UZV_MPV_LIB);
                }
                register_java_vm(lib);
                load_state = 1;
            }
        }
    }
    int ok = load_state > 0;
    pthread_mutex_unlock(&load_lock);
    return ok;
}

/* ---- log ring buffer ---------------------------------------------------------------------------------------------- */

#define LOG_CAP 65536
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static char log_buf[LOG_CAP + 1];
static size_t log_len;

/* Appends "[prefix] text\n"; when full, whole oldest lines are dropped. */
static void log_append(const char *prefix, const char *text) {
    char line[2048];
    int n = snprintf(line, sizeof line, "[%s] %s", prefix ? prefix : "", text ? text : "");
    if (n < 0) return;
    if ((size_t)n >= sizeof line) n = (int)sizeof line - 1;
    if (n == 0 || line[n - 1] != '\n') {
        if ((size_t)n >= sizeof line - 1) n = (int)sizeof line - 2;
        line[n++] = '\n';
    }
    pthread_mutex_lock(&log_lock);
    if (log_len + (size_t)n > LOG_CAP) {
        size_t drop = log_len + (size_t)n - LOG_CAP;
        const char *nl = memchr(log_buf + drop, '\n', log_len - drop);
        drop = nl ? (size_t)(nl - log_buf) + 1 : log_len;
        memmove(log_buf, log_buf + drop, log_len - drop);
        log_len -= drop;
    }
    memcpy(log_buf + log_len, line, (size_t)n);
    log_len += (size_t)n;
    log_buf[log_len] = '\0';
    pthread_mutex_unlock(&log_lock);
#ifdef __ANDROID__
    /* Also to logcat (tag "mpv"): the ring buffer is only read when something fails visibly. */
    line[n - 1] = '\0';
    __android_log_write(ANDROID_LOG_WARN, "mpv", line);
#endif
}

/* ---- UTF-8 <-> jstring (JNI's own helpers use modified UTF-8, which mangles emoji / supplementary characters) ----- */

/* Returns a malloc'ed UTF-8 copy, or NULL for null / out of memory. Lone surrogates become U+FFFD. */
static char *jstring_to_utf8(JNIEnv *env, jstring s) {
    if (!s) return NULL;
    jsize len = (*env)->GetStringLength(env, s);
    const jchar *u = (*env)->GetStringChars(env, s, NULL);
    if (!u) return NULL;
    char *out = malloc((size_t)len * 3 + 1);
    if (out) {
        size_t o = 0;
        for (jsize i = 0; i < len; i++) {
            uint32_t cp = u[i];
            if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (uint32_t)(u[i + 1] - 0xDC00);
                i++;
            } else if (cp >= 0xD800 && cp <= 0xDFFF) {
                cp = 0xFFFD;
            }
            if (cp < 0x80) {
                out[o++] = (char)cp;
            } else if (cp < 0x800) {
                out[o++] = (char)(0xC0 | (cp >> 6));
                out[o++] = (char)(0x80 | (cp & 0x3F));
            } else if (cp < 0x10000) {
                out[o++] = (char)(0xE0 | (cp >> 12));
                out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                out[o++] = (char)(0x80 | (cp & 0x3F));
            } else {
                out[o++] = (char)(0xF0 | (cp >> 18));
                out[o++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                out[o++] = (char)(0x80 | (cp & 0x3F));
            }
        }
        out[o] = '\0';
    }
    (*env)->ReleaseStringChars(env, s, u);
    return out;
}

static int is_cont(unsigned char c) { return (c & 0xC0) == 0x80; }

/* Decodes UTF-8 strictly; every invalid byte becomes U+FFFD. NULL in, NULL out. */
static jstring utf8_to_jstring(JNIEnv *env, const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    jchar *buf = malloc((n + 1) * sizeof(jchar)); /* UTF-16 units never outnumber UTF-8 bytes */
    if (!buf) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < n;) {
        unsigned char b = (unsigned char)s[i];
        uint32_t cp = 0xFFFD;
        size_t adv = 1;
        if (b < 0x80) {
            cp = b;
        } else if (b >= 0xC2 && b <= 0xDF && i + 1 < n && is_cont((unsigned char)s[i + 1])) {
            cp = ((uint32_t)(b & 0x1F) << 6) | ((unsigned char)s[i + 1] & 0x3F);
            adv = 2;
        } else if (b >= 0xE0 && b <= 0xEF && i + 2 < n && is_cont((unsigned char)s[i + 1]) && is_cont((unsigned char)s[i + 2])) {
            uint32_t c = ((uint32_t)(b & 0x0F) << 12) | ((uint32_t)((unsigned char)s[i + 1] & 0x3F) << 6) | ((unsigned char)s[i + 2] & 0x3F);
            if (c >= 0x800 && !(c >= 0xD800 && c <= 0xDFFF)) {
                cp = c;
                adv = 3;
            }
        } else if (b >= 0xF0 && b <= 0xF4 && i + 3 < n && is_cont((unsigned char)s[i + 1]) && is_cont((unsigned char)s[i + 2]) &&
                   is_cont((unsigned char)s[i + 3])) {
            uint32_t c = ((uint32_t)(b & 0x07) << 18) | ((uint32_t)((unsigned char)s[i + 1] & 0x3F) << 12) |
                         ((uint32_t)((unsigned char)s[i + 2] & 0x3F) << 6) | ((unsigned char)s[i + 3] & 0x3F);
            if (c >= 0x10000 && c <= 0x10FFFF) {
                cp = c;
                adv = 4;
            }
        }
        if (cp >= 0x10000) {
            cp -= 0x10000;
            buf[o++] = (jchar)(0xD800 + (cp >> 10));
            buf[o++] = (jchar)(0xDC00 + (cp & 0x3FF));
        } else {
            buf[o++] = (jchar)cp;
        }
        i += adv;
    }
    jstring r = (*env)->NewString(env, buf, (jsize)o);
    free(buf);
    return r;
}

/* ---- render update callback (any mpv thread -> static Kotlin method) ----------------------------------------------- */

static jclass native_class; /* global ref */
static jmethodID update_method;
static pthread_key_t detach_key;
static int detach_key_ok;

static void detach_current_thread(void *unused) {
    (void)unused;
    if (java_vm) (*java_vm)->DetachCurrentThread(java_vm);
}

/* mpv forbids calling any mpv API from here, so this only pokes the Kotlin side (which requests a GL redraw). */
static void on_render_update(void *unused) {
    (void)unused;
    if (!java_vm || !native_class || !update_method) return;
    JNIEnv *env = NULL;
    jint rc = (*java_vm)->GetEnv(java_vm, (void **)&env, JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
        if ((*java_vm)->AttachCurrentThread(java_vm, (ATTACH_ENV_T)&env, NULL) != JNI_OK) return;
        /* A thread that exits while attached aborts ART; the key destructor detaches it. */
        if (detach_key_ok) pthread_setspecific(detach_key, (void *)1);
    } else if (rc != JNI_OK) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, native_class, update_method);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env); /* must not unwind into mpv */
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    java_vm = vm;
    detach_key_ok = pthread_key_create(&detach_key, detach_current_thread) == 0;
    jclass cls = (*env)->FindClass(env, "com/example/uzv/native_player/kernel/mpv/MpvNative");
    if (cls) {
        update_method = (*env)->GetStaticMethodID(env, cls, "onMpvRenderUpdate", "()V");
        if (update_method) native_class = (*env)->NewGlobalRef(env, cls);
        (*env)->DeleteLocalRef(env, cls);
    }
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (!native_class) log_append("uzv_mpv", "MpvNative.onMpvRenderUpdate()V not found; frames will not be redrawn");
    return JNI_VERSION_1_6;
}

/* ---- OpenGL proc lookup -------------------------------------------------------------------------------------------- */

static void *(*egl_get_proc_address)(const char *);
static pthread_once_t egl_once = PTHREAD_ONCE_INIT;

static void egl_init(void) {
    void *lib = dlopen(UZV_EGL_LIB, RTLD_NOW | RTLD_LOCAL);
    if (lib) *(void **)(&egl_get_proc_address) = dlsym(lib, "eglGetProcAddress");
    if (!egl_get_proc_address) *(void **)(&egl_get_proc_address) = dlsym(RTLD_DEFAULT, "eglGetProcAddress");
}

/* eglGetProcAddress first; some drivers return NULL for core GLES functions, so fall back to the process's symbols. */
static void *gl_proc(void *ctx, const char *name) {
    (void)ctx;
    pthread_once(&egl_once, egl_init);
    void *p = egl_get_proc_address ? egl_get_proc_address(name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

/* ---- JNI exports --------------------------------------------------------------------------------------------------- */

static mpv_handle *H(jlong h) { return (mpv_handle *)(intptr_t)h; }
static mpv_render_context *RC(jlong c) { return (mpv_render_context *)(intptr_t)c; }

JNI_FN(jlong, create)(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    if (!load_mpv()) return 0;
    return (jlong)(intptr_t)api.mpv_create();
}

JNI_FN(jint, initialize)(JNIEnv *env, jobject thiz, jlong handle) {
    (void)env;
    (void)thiz;
    if (!handle) return MPV_ERROR_UNINITIALIZED;
    return api.mpv_initialize(H(handle));
}

JNI_FN(void, destroy)(JNIEnv *env, jobject thiz, jlong handle) {
    (void)env;
    (void)thiz;
    if (handle) api.mpv_terminate_destroy(H(handle));
}

JNI_FN(jint, command)(JNIEnv *env, jobject thiz, jlong handle, jobjectArray args) {
    (void)thiz;
    if (!handle) return MPV_ERROR_UNINITIALIZED;
    if (!args) return MPV_ERROR_INVALID_PARAMETER;
    jsize n = (*env)->GetArrayLength(env, args);
    const char **argv = calloc((size_t)n + 1, sizeof(char *));
    if (!argv) return MPV_ERROR_NOMEM;
    int rc = MPV_ERROR_SUCCESS;
    for (jsize i = 0; i < n; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, args, i);
        argv[i] = jstring_to_utf8(env, s);
        if (s) (*env)->DeleteLocalRef(env, s);
        if (!argv[i]) { /* a null argument would end the list early and silently change the command */
            rc = s ? MPV_ERROR_NOMEM : MPV_ERROR_INVALID_PARAMETER;
            break;
        }
    }
    if (rc == MPV_ERROR_SUCCESS) rc = api.mpv_command(H(handle), argv);
    for (jsize i = 0; i < n; i++) free((void *)argv[i]);
    free(argv);
    return rc;
}

JNI_FN(jint, setProperty)(JNIEnv *env, jobject thiz, jlong handle, jstring name, jint format, jdouble value) {
    (void)thiz;
    if (!handle) return MPV_ERROR_UNINITIALIZED;
    char *key = jstring_to_utf8(env, name);
    if (!key) return MPV_ERROR_INVALID_PARAMETER;
    int rc;
    switch (format) {
        case MPV_FORMAT_FLAG: {
            int v = value != 0.0;
            rc = api.mpv_set_property(H(handle), key, MPV_FORMAT_FLAG, &v);
            break;
        }
        case MPV_FORMAT_INT64: {
            int64_t v = (int64_t)value;
            rc = api.mpv_set_property(H(handle), key, MPV_FORMAT_INT64, &v);
            break;
        }
        case MPV_FORMAT_DOUBLE: {
            double v = value;
            rc = api.mpv_set_property(H(handle), key, MPV_FORMAT_DOUBLE, &v);
            break;
        }
        default:
            rc = MPV_ERROR_PROPERTY_FORMAT;
    }
    free(key);
    return rc;
}

JNI_FN(jint, setPropertyString)(JNIEnv *env, jobject thiz, jlong handle, jstring name, jstring value) {
    (void)thiz;
    if (!handle) return MPV_ERROR_UNINITIALIZED;
    char *key = jstring_to_utf8(env, name);
    char *val = jstring_to_utf8(env, value);
    int rc = key && val ? api.mpv_set_property_string(H(handle), key, val) : MPV_ERROR_INVALID_PARAMETER;
    free(key);
    free(val);
    return rc;
}

/* NaN when the property is unavailable or the format is not FLAG / INT64 / DOUBLE. */
JNI_FN(jdouble, getProperty)(JNIEnv *env, jobject thiz, jlong handle, jstring name, jint format) {
    (void)thiz;
    if (!handle) return NAN;
    char *key = jstring_to_utf8(env, name);
    if (!key) return NAN;
    double out = NAN;
    switch (format) {
        case MPV_FORMAT_FLAG: {
            int v = 0;
            if (api.mpv_get_property(H(handle), key, MPV_FORMAT_FLAG, &v) >= 0) out = v ? 1.0 : 0.0;
            break;
        }
        case MPV_FORMAT_INT64: {
            int64_t v = 0;
            if (api.mpv_get_property(H(handle), key, MPV_FORMAT_INT64, &v) >= 0) out = (double)v;
            break;
        }
        case MPV_FORMAT_DOUBLE: {
            double v = 0;
            if (api.mpv_get_property(H(handle), key, MPV_FORMAT_DOUBLE, &v) >= 0) out = v;
            break;
        }
        default:
            break;
    }
    free(key);
    return out;
}

JNI_FN(jstring, getPropertyString)(JNIEnv *env, jobject thiz, jlong handle, jstring name) {
    (void)thiz;
    if (!handle) return NULL;
    char *key = jstring_to_utf8(env, name);
    if (!key) return NULL;
    char *s = api.mpv_get_property_string(H(handle), key);
    free(key);
    if (!s) return NULL;
    jstring r = utf8_to_jstring(env, s);
    api.mpv_free(s);
    return r;
}

JNI_FN(jint, observeProperty)(JNIEnv *env, jobject thiz, jlong handle, jlong user_data, jstring name, jint format) {
    (void)thiz;
    if (!handle) return MPV_ERROR_UNINITIALIZED;
    char *key = jstring_to_utf8(env, name);
    if (!key) return MPV_ERROR_INVALID_PARAMETER;
    int rc = api.mpv_observe_property(H(handle), (uint64_t)user_data, key, (mpv_format)format);
    free(key);
    return rc;
}

JNI_FN(jintArray, waitEvent)(JNIEnv *env, jobject thiz, jlong handle, jdouble timeout) {
    (void)thiz;
    jint out[4] = {MPV_EVENT_NONE, 0, 0, 0};
    if (handle) {
        const mpv_event *ev = api.mpv_wait_event(H(handle), timeout);
        if (ev) {
            out[0] = (jint)ev->event_id;
            out[1] = ev->error;
            out[2] = (jint)(uint32_t)ev->reply_userdata;
            switch (ev->event_id) {
                case MPV_EVENT_END_FILE:
                    if (ev->data) {
                        const mpv_event_end_file *e = ev->data;
                        out[3] = (jint)e->reason;
                        if (e->reason == MPV_END_FILE_REASON_ERROR) out[1] = e->error;
                    }
                    break;
                case MPV_EVENT_PROPERTY_CHANGE:
                    if (ev->data) out[3] = (jint)((const mpv_event_property *)ev->data)->format;
                    break;
                case MPV_EVENT_LOG_MESSAGE:
                    if (ev->data) {
                        const mpv_event_log_message *m = ev->data;
                        log_append(m->prefix, m->text);
                        out[3] = (jint)m->log_level;
                    }
                    break;
                default:
                    break;
            }
        }
    }
    jintArray arr = (*env)->NewIntArray(env, 4);
    if (arr) (*env)->SetIntArrayRegion(env, arr, 0, 4, out);
    return arr;
}

JNI_FN(void, wakeup)(JNIEnv *env, jobject thiz, jlong handle) {
    (void)env;
    (void)thiz;
    if (handle) api.mpv_wakeup(H(handle));
}

JNI_FN(jstring, errorString)(JNIEnv *env, jobject thiz, jint code) {
    (void)thiz;
    if (!load_mpv()) return utf8_to_jstring(env, "libmpv not loaded");
    const char *s = api.mpv_error_string(code);
    return utf8_to_jstring(env, s ? s : "unknown error");
}

JNI_FN(jint, requestLogMessages)(JNIEnv *env, jobject thiz, jlong handle, jstring min_level) {
    (void)thiz;
    if (!handle) return MPV_ERROR_UNINITIALIZED;
    char *level = jstring_to_utf8(env, min_level);
    if (!level) return MPV_ERROR_INVALID_PARAMETER;
    int rc = api.mpv_request_log_messages(H(handle), level);
    free(level);
    return rc;
}

JNI_FN(jstring, getLastLogMessages)(JNIEnv *env, jobject thiz) {
    (void)thiz;
    pthread_mutex_lock(&log_lock);
    jstring r = utf8_to_jstring(env, log_buf);
    pthread_mutex_unlock(&log_lock);
    return r;
}

JNI_FN(void, clearLogMessages)(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    pthread_mutex_lock(&log_lock);
    log_len = 0;
    log_buf[0] = '\0';
    pthread_mutex_unlock(&log_lock);
}

/* Must run on the GL thread with the EGL context current (mpv initialises its GL state here). */
JNI_FN(jlong, renderContextCreate)(JNIEnv *env, jobject thiz, jlong handle) {
    (void)env;
    (void)thiz;
    if (!handle) return 0;
    mpv_opengl_init_params gl = {gl_proc, NULL};
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    mpv_render_context *ctx = NULL;
    int rc = api.mpv_render_context_create(&ctx, H(handle), params);
    if (rc < 0 || !ctx) {
        char msg[160];
        const char *why = api.mpv_error_string(rc);
        snprintf(msg, sizeof msg, "mpv_render_context_create failed: %s (%d)", why ? why : "?", rc);
        log_append("uzv_mpv", msg);
        return 0;
    }
    api.mpv_render_context_set_update_callback(ctx, on_render_update, NULL);
    return (jlong)(intptr_t)ctx;
}

/* GL thread, context current: mpv deletes its GL objects here. Frees the update callback along with the context. */
JNI_FN(void, renderContextFree)(JNIEnv *env, jobject thiz, jlong render_context) {
    (void)env;
    (void)thiz;
    if (render_context) api.mpv_render_context_free(RC(render_context));
}

/* Draws into the default framebuffer of the current surface; FLIP_Y because FBO 0 has its origin at the bottom left. */
JNI_FN(void, render)(JNIEnv *env, jobject thiz, jlong render_context, jint width, jint height) {
    (void)env;
    (void)thiz;
    if (!render_context) return;
    mpv_opengl_fbo fbo = {0, width, height, 0};
    int flip_y = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    api.mpv_render_context_render(RC(render_context), params);
}

JNI_FN(jboolean, probe)(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    return load_mpv() ? JNI_TRUE : JNI_FALSE;
}

JNI_FN(jstring, probeDetail)(JNIEnv *env, jobject thiz) {
    (void)thiz;
    load_mpv();
    pthread_mutex_lock(&load_lock);
    jstring r = utf8_to_jstring(env, load_detail);
    pthread_mutex_unlock(&load_lock);
    return r;
}
