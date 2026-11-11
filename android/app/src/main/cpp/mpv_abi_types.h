/*
 * The part of the libmpv client / render API that uzv_mpv.c uses, written out by hand so the glue builds without
 * the mpv headers (libmpv itself is only dlopen()ed, see uzv_mpv.c).
 *
 * Every definition here is a copy of what mpv's public headers (client.h, render.h, render_gl.h; client API 2.x)
 * declare. native_tests/mpv_glue/run.sh compiles the REAL headers and this file side by side and diffs sizeof /
 * offsetof / enum values, and checks the function-pointer types in mpv_abi_fn.h against the real prototypes.
 * Change nothing here without re-running it.
 */
#ifndef UZV_MPV_ABI_TYPES_H
#define UZV_MPV_ABI_TYPES_H

#include <stdint.h>

typedef struct mpv_handle mpv_handle;
typedef struct mpv_render_context mpv_render_context;

typedef enum mpv_error {
    MPV_ERROR_SUCCESS = 0,
    MPV_ERROR_EVENT_QUEUE_FULL = -1,
    MPV_ERROR_NOMEM = -2,
    MPV_ERROR_UNINITIALIZED = -3,
    MPV_ERROR_INVALID_PARAMETER = -4,
    MPV_ERROR_PROPERTY_FORMAT = -9,
    MPV_ERROR_UNSUPPORTED = -18,
    MPV_ERROR_GENERIC = -20
} mpv_error;

typedef enum mpv_format {
    MPV_FORMAT_NONE = 0,
    MPV_FORMAT_STRING = 1,
    MPV_FORMAT_OSD_STRING = 2,
    MPV_FORMAT_FLAG = 3,
    MPV_FORMAT_INT64 = 4,
    MPV_FORMAT_DOUBLE = 5,
    MPV_FORMAT_NODE = 6
} mpv_format;

typedef enum mpv_event_id {
    MPV_EVENT_NONE = 0,
    MPV_EVENT_SHUTDOWN = 1,
    MPV_EVENT_LOG_MESSAGE = 2,
    MPV_EVENT_START_FILE = 6,
    MPV_EVENT_END_FILE = 7,
    MPV_EVENT_FILE_LOADED = 8,
    MPV_EVENT_IDLE = 11,
    MPV_EVENT_TICK = 14,
    MPV_EVENT_VIDEO_RECONFIG = 17,
    MPV_EVENT_AUDIO_RECONFIG = 18,
    MPV_EVENT_SEEK = 20,
    MPV_EVENT_PLAYBACK_RESTART = 21,
    MPV_EVENT_PROPERTY_CHANGE = 22,
    MPV_EVENT_QUEUE_OVERFLOW = 24,
    MPV_EVENT_HOOK = 25
} mpv_event_id;

typedef enum mpv_log_level {
    MPV_LOG_LEVEL_NONE = 0,
    MPV_LOG_LEVEL_FATAL = 10,
    MPV_LOG_LEVEL_ERROR = 20,
    MPV_LOG_LEVEL_WARN = 30,
    MPV_LOG_LEVEL_INFO = 40,
    MPV_LOG_LEVEL_V = 50,
    MPV_LOG_LEVEL_DEBUG = 60,
    MPV_LOG_LEVEL_TRACE = 70
} mpv_log_level;

typedef enum mpv_end_file_reason {
    MPV_END_FILE_REASON_EOF = 0,
    MPV_END_FILE_REASON_STOP = 2,
    MPV_END_FILE_REASON_QUIT = 3,
    MPV_END_FILE_REASON_ERROR = 4,
    MPV_END_FILE_REASON_REDIRECT = 5
} mpv_end_file_reason;

typedef struct mpv_event {
    mpv_event_id event_id;
    int error;
    uint64_t reply_userdata;
    void *data;
} mpv_event;

typedef struct mpv_event_property {
    const char *name;
    mpv_format format;
    void *data;
} mpv_event_property;

typedef struct mpv_event_log_message {
    const char *prefix;
    const char *level;
    const char *text;
    mpv_log_level log_level;
} mpv_event_log_message;

typedef struct mpv_event_end_file {
    mpv_end_file_reason reason;
    int error;
    int64_t playlist_entry_id;
    int64_t playlist_insert_id;
    int playlist_insert_num_entries;
} mpv_event_end_file;

enum mpv_render_param_type {
    MPV_RENDER_PARAM_INVALID = 0,
    MPV_RENDER_PARAM_API_TYPE = 1,
    MPV_RENDER_PARAM_OPENGL_INIT_PARAMS = 2,
    MPV_RENDER_PARAM_OPENGL_FBO = 3,
    MPV_RENDER_PARAM_FLIP_Y = 4
};

typedef struct mpv_render_param {
    enum mpv_render_param_type type;
    void *data;
} mpv_render_param;

typedef struct mpv_opengl_init_params {
    void *(*get_proc_address)(void *ctx, const char *name);
    void *get_proc_address_ctx;
} mpv_opengl_init_params;

typedef struct mpv_opengl_fbo {
    int fbo;
    int w, h;
    int internal_format;
} mpv_opengl_fbo;

#define MPV_RENDER_API_TYPE_OPENGL "opengl"

#endif
