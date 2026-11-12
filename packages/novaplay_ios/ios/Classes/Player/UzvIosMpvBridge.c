#include "UzvIosMpvBridge.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct mpv_handle mpv_handle;

typedef enum {
    UZV_MPV_FORMAT_NONE = 0,
    UZV_MPV_FORMAT_STRING = 1,
    UZV_MPV_FORMAT_OSD_STRING = 2,
    UZV_MPV_FORMAT_FLAG = 3,
    UZV_MPV_FORMAT_INT64 = 4,
    UZV_MPV_FORMAT_DOUBLE = 5,
    UZV_MPV_FORMAT_NODE = 6
} uzv_mpv_format;

typedef enum {
    UZV_MPV_EVENT_NONE = 0,
    UZV_MPV_EVENT_SHUTDOWN = 1,
    UZV_MPV_EVENT_LOG_MESSAGE = 2,
    UZV_MPV_EVENT_START_FILE = 6,
    UZV_MPV_EVENT_END_FILE = 7,
    UZV_MPV_EVENT_FILE_LOADED = 8,
    UZV_MPV_EVENT_IDLE = 11,
    UZV_MPV_EVENT_VIDEO_RECONFIG = 17,
    UZV_MPV_EVENT_AUDIO_RECONFIG = 18,
    UZV_MPV_EVENT_SEEK = 20,
    UZV_MPV_EVENT_PLAYBACK_RESTART = 21,
    UZV_MPV_EVENT_PROPERTY_CHANGE = 22
} uzv_mpv_event_id;

typedef struct {
    int event_id;
    int error;
    uint64_t reply_userdata;
    void *data;
} uzv_mpv_event;

typedef struct {
    const char *prefix;
    const char *level;
    const char *text;
    int log_level;
} uzv_mpv_event_log_message;

typedef struct {
    int reason;
    int error;
    int64_t playlist_entry_id;
    int64_t playlist_insert_id;
    int playlist_insert_num_entries;
} uzv_mpv_event_end_file;

#define UZV_IOS_MPV_FN_LIST(X)                                                                           \
    X(mpv_create, mpv_handle *, (void))                                                                  \
    X(mpv_initialize, int, (mpv_handle * ctx))                                                           \
    X(mpv_terminate_destroy, void, (mpv_handle * ctx))                                                   \
    X(mpv_set_option, int, (mpv_handle * ctx, const char *name, int format, void *data))                 \
    X(mpv_set_option_string, int, (mpv_handle * ctx, const char *name, const char *data))                \
    X(mpv_command, int, (mpv_handle * ctx, const char **args))                                           \
    X(mpv_set_property, int, (mpv_handle * ctx, const char *name, int format, void *data))               \
    X(mpv_set_property_string, int, (mpv_handle * ctx, const char *name, const char *data))              \
    X(mpv_get_property, int, (mpv_handle * ctx, const char *name, int format, void *data))               \
    X(mpv_get_property_string, char *, (mpv_handle * ctx, const char *name))                             \
    X(mpv_observe_property, int, (mpv_handle * ctx, uint64_t userdata, const char *name, int format))    \
    X(mpv_wait_event, uzv_mpv_event *, (mpv_handle * ctx, double timeout))                               \
    X(mpv_wakeup, void, (mpv_handle * ctx))                                                              \
    X(mpv_error_string, const char *, (int error))                                                       \
    X(mpv_request_log_messages, int, (mpv_handle * ctx, const char *min_level))                          \
    X(mpv_free, void, (void *data))

typedef struct {
#define DECL_FN(name, ret, args) ret (*name) args;
    UZV_IOS_MPV_FN_LIST(DECL_FN)
#undef DECL_FN
} UzvIosMpvApi;

struct uzv_mpv_instance {
    mpv_handle *handle;
    pthread_mutex_t log_lock;
    char log_buf[4096];
    size_t log_len;
};

static UzvIosMpvApi g_mpv;
static pthread_mutex_t g_load_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_load_state = 0; /* 0 = untried, 1 = loaded, -1 = failed */
static char g_load_detail[512] = "NovaMpv not probed yet";

static bool try_bind_symbols(void *lib_handle, const char *source_name) {
    UzvIosMpvApi candidate;
    memset(&candidate, 0, sizeof(candidate));
    const char *missing = NULL;

#define BIND_FN(name, ret, args)                                     \
    if (!missing) {                                                  \
        *(void **)(&candidate.name) = dlsym(lib_handle, #name);      \
        if (!candidate.name) {                                       \
            missing = #name;                                         \
        }                                                            \
    }
    UZV_IOS_MPV_FN_LIST(BIND_FN)
#undef BIND_FN

    if (missing) {
        snprintf(g_load_detail, sizeof(g_load_detail), "%s missing symbol %s", source_name, missing);
        return false;
    }
    g_mpv = candidate;
    snprintf(g_load_detail, sizeof(g_load_detail), "Loaded libmpv from %s", source_name);
    return true;
}

static bool ensure_mpv_loaded(void) {
    pthread_mutex_lock(&g_load_lock);
    if (g_load_state != 0) {
        bool ok = (g_load_state == 1);
        pthread_mutex_unlock(&g_load_lock);
        return ok;
    }

    const char *candidates[] = {
        "@rpath/NovaMpv.framework/NovaMpv",
        "@executable_path/Frameworks/NovaMpv.framework/NovaMpv",
        "@rpath/Libmpv.framework/Libmpv",
        "@executable_path/Frameworks/Libmpv.framework/Libmpv",
        "@rpath/libmpv.framework/libmpv",
        "@executable_path/Frameworks/libmpv.framework/libmpv",
        NULL
    };

    const char *last_err = NULL;
    for (int i = 0; candidates[i] != NULL; i++) {
        void *h = dlopen(candidates[i], RTLD_NOW | RTLD_GLOBAL);
        if (!h) {
            last_err = dlerror();
            continue;
        }
        if (try_bind_symbols(h, candidates[i])) {
            g_load_state = 1;
            pthread_mutex_unlock(&g_load_lock);
            return true;
        }
    }

    if (dlsym(RTLD_DEFAULT, "mpv_create") != NULL && try_bind_symbols(RTLD_DEFAULT, "RTLD_DEFAULT")) {
        g_load_state = 1;
        pthread_mutex_unlock(&g_load_lock);
        return true;
    }

    snprintf(
        g_load_detail,
        sizeof(g_load_detail),
        "NovaMpv.framework unavailable (%s)",
        last_err ? last_err : "mpv_create not found"
    );
    g_load_state = -1;
    pthread_mutex_unlock(&g_load_lock);
    return false;
}

static void append_instance_log(uzv_mpv_instance *inst, const char *prefix, const char *level, const char *text) {
    if (!inst || !text || text[0] == '\0') return;
    char line[512];
    int n = snprintf(
        line,
        sizeof(line),
        "[%s/%s] %s",
        prefix ? prefix : "mpv",
        level ? level : "info",
        text
    );
    if (n <= 0) return;
    size_t add_len = (size_t)n < sizeof(line) ? (size_t)n : (sizeof(line) - 1);

    pthread_mutex_lock(&inst->log_lock);
    if (add_len >= sizeof(inst->log_buf)) {
        add_len = sizeof(inst->log_buf) - 1;
    }
    if (inst->log_len + add_len + 1 > sizeof(inst->log_buf)) {
        size_t keep = sizeof(inst->log_buf) / 2;
        if (keep > inst->log_len) keep = inst->log_len;
        size_t drop = inst->log_len - keep;
        memmove(inst->log_buf, inst->log_buf + drop, keep);
        inst->log_len = keep;
    }
    memcpy(inst->log_buf + inst->log_len, line, add_len);
    inst->log_len += add_len;
    inst->log_buf[inst->log_len] = '\0';
    pthread_mutex_unlock(&inst->log_lock);
}

bool uzv_ios_mpv_is_available(void) {
    return ensure_mpv_loaded();
}

const char *uzv_ios_mpv_probe_detail(void) {
    (void)ensure_mpv_loaded();
    return g_load_detail;
}

uzv_mpv_instance *uzv_ios_mpv_create(void) {
    if (!ensure_mpv_loaded()) return NULL;
    mpv_handle *h = g_mpv.mpv_create();
    if (!h) return NULL;
    uzv_mpv_instance *inst = (uzv_mpv_instance *)calloc(1, sizeof(uzv_mpv_instance));
    if (!inst) {
        g_mpv.mpv_terminate_destroy(h);
        return NULL;
    }
    inst->handle = h;
    pthread_mutex_init(&inst->log_lock, NULL);
    return inst;
}

int uzv_ios_mpv_set_option_int64(uzv_mpv_instance *inst, const char *name, int64_t value) {
    if (!inst || !inst->handle || !name) return -4;
    int64_t v = value;
    return g_mpv.mpv_set_option(inst->handle, name, UZV_MPV_FORMAT_INT64, &v);
}

int uzv_ios_mpv_set_option_string(uzv_mpv_instance *inst, const char *name, const char *value) {
    if (!inst || !inst->handle || !name) return -4;
    return g_mpv.mpv_set_option_string(inst->handle, name, value ? value : "");
}

int uzv_ios_mpv_initialize(uzv_mpv_instance *inst) {
    if (!inst || !inst->handle) return -4;
    g_mpv.mpv_request_log_messages(inst->handle, "warn");
    return g_mpv.mpv_initialize(inst->handle);
}

void uzv_ios_mpv_wakeup(uzv_mpv_instance *inst) {
    if (!inst || !inst->handle) return;
    g_mpv.mpv_wakeup(inst->handle);
}

void uzv_ios_mpv_destroy(uzv_mpv_instance *inst) {
    if (!inst) return;
    if (inst->handle) {
        g_mpv.mpv_terminate_destroy(inst->handle);
        inst->handle = NULL;
    }
    pthread_mutex_destroy(&inst->log_lock);
    free(inst);
}

int uzv_ios_mpv_command2(uzv_mpv_instance *inst, const char *a0, const char *a1) {
    if (!inst || !inst->handle || !a0) return -4;
    const char *cmd[3] = {a0, a1, NULL};
    return g_mpv.mpv_command(inst->handle, cmd);
}

int uzv_ios_mpv_command3(uzv_mpv_instance *inst, const char *a0, const char *a1, const char *a2) {
    if (!inst || !inst->handle || !a0) return -4;
    const char *cmd[4] = {a0, a1, a2, NULL};
    return g_mpv.mpv_command(inst->handle, cmd);
}

int uzv_ios_mpv_command4(uzv_mpv_instance *inst, const char *a0, const char *a1, const char *a2, const char *a3) {
    if (!inst || !inst->handle || !a0) return -4;
    const char *cmd[5] = {a0, a1, a2, a3, NULL};
    return g_mpv.mpv_command(inst->handle, cmd);
}

int uzv_ios_mpv_command5(
    uzv_mpv_instance *inst,
    const char *a0,
    const char *a1,
    const char *a2,
    const char *a3,
    const char *a4
) {
    if (!inst || !inst->handle || !a0) return -4;
    const char *cmd[6] = {a0, a1, a2, a3, a4, NULL};
    return g_mpv.mpv_command(inst->handle, cmd);
}

int uzv_ios_mpv_set_property_string(uzv_mpv_instance *inst, const char *name, const char *value) {
    if (!inst || !inst->handle || !name) return -4;
    return g_mpv.mpv_set_property_string(inst->handle, name, value ? value : "");
}

int uzv_ios_mpv_set_property_flag(uzv_mpv_instance *inst, const char *name, bool value) {
    if (!inst || !inst->handle || !name) return -4;
    int flag = value ? 1 : 0;
    return g_mpv.mpv_set_property(inst->handle, name, UZV_MPV_FORMAT_FLAG, &flag);
}

int uzv_ios_mpv_set_property_int64(uzv_mpv_instance *inst, const char *name, int64_t value) {
    if (!inst || !inst->handle || !name) return -4;
    int64_t v = value;
    return g_mpv.mpv_set_property(inst->handle, name, UZV_MPV_FORMAT_INT64, &v);
}

int uzv_ios_mpv_set_property_double(uzv_mpv_instance *inst, const char *name, double value) {
    if (!inst || !inst->handle || !name) return -4;
    double v = value;
    return g_mpv.mpv_set_property(inst->handle, name, UZV_MPV_FORMAT_DOUBLE, &v);
}

bool uzv_ios_mpv_get_property_flag(uzv_mpv_instance *inst, const char *name, bool fallback) {
    if (!inst || !inst->handle || !name) return fallback;
    int flag = 0;
    if (g_mpv.mpv_get_property(inst->handle, name, UZV_MPV_FORMAT_FLAG, &flag) < 0) {
        return fallback;
    }
    return flag != 0;
}

int64_t uzv_ios_mpv_get_property_int64(uzv_mpv_instance *inst, const char *name, int64_t fallback) {
    if (!inst || !inst->handle || !name) return fallback;
    int64_t v = fallback;
    if (g_mpv.mpv_get_property(inst->handle, name, UZV_MPV_FORMAT_INT64, &v) < 0) {
        return fallback;
    }
    return v;
}

double uzv_ios_mpv_get_property_double(uzv_mpv_instance *inst, const char *name, double fallback) {
    if (!inst || !inst->handle || !name) return fallback;
    double v = fallback;
    if (g_mpv.mpv_get_property(inst->handle, name, UZV_MPV_FORMAT_DOUBLE, &v) < 0) {
        return fallback;
    }
    return v;
}

char *uzv_ios_mpv_get_property_string_copy(uzv_mpv_instance *inst, const char *name) {
    if (!inst || !inst->handle || !name) return NULL;
    char *mpv_str = g_mpv.mpv_get_property_string(inst->handle, name);
    if (!mpv_str) return NULL;
    size_t len = strlen(mpv_str);
    char *copy = (char *)malloc(len + 1);
    if (copy) {
        memcpy(copy, mpv_str, len + 1);
    }
    g_mpv.mpv_free(mpv_str);
    return copy;
}

void uzv_ios_mpv_free_cstr(char *ptr) {
    free(ptr);
}

int uzv_ios_mpv_observe_property(uzv_mpv_instance *inst, uint64_t userdata, const char *name, int32_t format) {
    if (!inst || !inst->handle || !name) return -4;
    return g_mpv.mpv_observe_property(inst->handle, userdata, name, (int)format);
}

UzvIosMpvEvent uzv_ios_mpv_wait_event(uzv_mpv_instance *inst, double timeout_sec) {
    UzvIosMpvEvent out;
    memset(&out, 0, sizeof(out));
    if (!inst || !inst->handle) {
        out.event_id = UZV_MPV_EVENT_SHUTDOWN;
        return out;
    }
    uzv_mpv_event *ev = g_mpv.mpv_wait_event(inst->handle, timeout_sec);
    if (!ev) {
        out.event_id = UZV_MPV_EVENT_NONE;
        return out;
    }
    out.event_id = ev->event_id;
    out.error_code = ev->error;
    out.reply_userdata = ev->reply_userdata;
    if (ev->event_id == UZV_MPV_EVENT_LOG_MESSAGE && ev->data) {
        const uzv_mpv_event_log_message *lm = (const uzv_mpv_event_log_message *)ev->data;
        append_instance_log(inst, lm->prefix, lm->level, lm->text);
    } else if (ev->event_id == UZV_MPV_EVENT_END_FILE && ev->data) {
        const uzv_mpv_event_end_file *ef = (const uzv_mpv_event_end_file *)ev->data;
        out.end_reason = ef->reason;
        out.end_error = ef->error;
    }
    return out;
}

char *uzv_ios_mpv_copy_recent_logs(uzv_mpv_instance *inst) {
    if (!inst) return NULL;
    pthread_mutex_lock(&inst->log_lock);
    size_t len = inst->log_len;
    char *copy = (char *)malloc(len + 1);
    if (copy) {
        if (len > 0) memcpy(copy, inst->log_buf, len);
        copy[len] = '\0';
    }
    pthread_mutex_unlock(&inst->log_lock);
    return copy;
}

const char *uzv_ios_mpv_error_string(int error_code) {
    if (!ensure_mpv_loaded() || !g_mpv.mpv_error_string) {
        return "mpv unavailable";
    }
    const char *s = g_mpv.mpv_error_string(error_code);
    return s ? s : "unknown mpv error";
}
