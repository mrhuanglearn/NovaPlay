/*
 * Function-pointer types of the 18 libmpv entry points the glue resolves with dlsym(). They use only the mpv_*
 * type names, so this file compiles against either mpv_abi_types.h (the shipped glue) or mpv's real headers (the
 * host check, which asserts each type is compatible with the real prototype).
 *
 * X-macro: X(name, return type, parameter list).
 */
#ifndef UZV_MPV_ABI_FN_H
#define UZV_MPV_ABI_FN_H

#define UZV_MPV_FUNCTIONS(X)                                                                                  \
    X(mpv_create, mpv_handle *, (void))                                                                       \
    X(mpv_initialize, int, (mpv_handle * ctx))                                                                \
    X(mpv_terminate_destroy, void, (mpv_handle * ctx))                                                        \
    X(mpv_command, int, (mpv_handle * ctx, const char **args))                                                \
    X(mpv_set_property, int, (mpv_handle * ctx, const char *name, mpv_format format, void *data))             \
    X(mpv_set_property_string, int, (mpv_handle * ctx, const char *name, const char *data))                   \
    X(mpv_get_property, int, (mpv_handle * ctx, const char *name, mpv_format format, void *data))             \
    X(mpv_get_property_string, char *, (mpv_handle * ctx, const char *name))                                  \
    X(mpv_observe_property, int, (mpv_handle * mpv, uint64_t reply_userdata, const char *name, mpv_format format)) \
    X(mpv_wait_event, mpv_event *, (mpv_handle * ctx, double timeout))                                        \
    X(mpv_wakeup, void, (mpv_handle * ctx))                                                                   \
    X(mpv_error_string, const char *, (int error))                                                            \
    X(mpv_request_log_messages, int, (mpv_handle * ctx, const char *min_level))                               \
    X(mpv_free, void, (void *data))                                                                           \
    X(mpv_render_context_create, int, (mpv_render_context * *res, mpv_handle *mpv, mpv_render_param *params)) \
    X(mpv_render_context_set_update_callback, void,                                                           \
      (mpv_render_context * ctx, void (*callback)(void *cb_ctx), void *callback_ctx))                         \
    X(mpv_render_context_render, int, (mpv_render_context * ctx, mpv_render_param *params))                   \
    X(mpv_render_context_free, void, (mpv_render_context * ctx))

#endif
