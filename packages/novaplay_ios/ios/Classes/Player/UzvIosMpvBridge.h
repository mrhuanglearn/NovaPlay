#ifndef UZV_IOS_MPV_BRIDGE_H
#define UZV_IOS_MPV_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct uzv_mpv_instance uzv_mpv_instance;

typedef struct {
    int32_t event_id;
    int32_t error_code;
    uint64_t reply_userdata;
    int32_t end_reason;
    int32_t end_error;
} UzvIosMpvEvent;

/// Probes `NovaMpv.framework` / `Libmpv.framework` via `dlopen` + `dlsym`.
bool uzv_ios_mpv_is_available(void);

/// Human-readable status or failure reason from the dynamic loader.
const char *uzv_ios_mpv_probe_detail(void);

/// Creates an uninitialized mpv handle. Returns NULL if libmpv is unavailable.
uzv_mpv_instance *uzv_ios_mpv_create(void);

/// Sets options prior to `uzv_ios_mpv_initialize` (e.g. `wid`, `vo`, `gpu-api`, `gpu-context`).
int uzv_ios_mpv_set_option_int64(uzv_mpv_instance *inst, const char *name, int64_t value);
int uzv_ios_mpv_set_option_string(uzv_mpv_instance *inst, const char *name, const char *value);

/// Initializes the mpv instance and enables warn/error log capture.
int uzv_ios_mpv_initialize(uzv_mpv_instance *inst);

/// Wakes any blocked event waiter.
void uzv_ios_mpv_wakeup(uzv_mpv_instance *inst);

/// Terminates and frees the mpv instance.
void uzv_ios_mpv_destroy(uzv_mpv_instance *inst);

/// Executes a synchronous mpv command (`args` must NOT need trailing NULL; helper appends NULL).
int uzv_ios_mpv_command2(uzv_mpv_instance *inst, const char *a0, const char *a1);
int uzv_ios_mpv_command3(uzv_mpv_instance *inst, const char *a0, const char *a1, const char *a2);
int uzv_ios_mpv_command4(uzv_mpv_instance *inst, const char *a0, const char *a1, const char *a2, const char *a3);
int uzv_ios_mpv_command5(
    uzv_mpv_instance *inst,
    const char *a0,
    const char *a1,
    const char *a2,
    const char *a3,
    const char *a4
);

/// Property setters & getters. `uzv_ios_mpv_get_property_string_copy` returns a malloc'd C string (caller frees via `uzv_ios_mpv_free_cstr`).
int uzv_ios_mpv_set_property_string(uzv_mpv_instance *inst, const char *name, const char *value);
int uzv_ios_mpv_set_property_flag(uzv_mpv_instance *inst, const char *name, bool value);
int uzv_ios_mpv_set_property_int64(uzv_mpv_instance *inst, const char *name, int64_t value);
int uzv_ios_mpv_set_property_double(uzv_mpv_instance *inst, const char *name, double value);

bool uzv_ios_mpv_get_property_flag(uzv_mpv_instance *inst, const char *name, bool fallback);
int64_t uzv_ios_mpv_get_property_int64(uzv_mpv_instance *inst, const char *name, int64_t fallback);
double uzv_ios_mpv_get_property_double(uzv_mpv_instance *inst, const char *name, double fallback);
char *uzv_ios_mpv_get_property_string_copy(uzv_mpv_instance *inst, const char *name);
void uzv_ios_mpv_free_cstr(char *ptr);

/// Observes a property (`format`: 0=none, 1=string, 3=flag, 4=int64, 5=double).
int uzv_ios_mpv_observe_property(uzv_mpv_instance *inst, uint64_t userdata, const char *name, int32_t format);

/// Waits up to `timeout_sec` for the next mpv event and appends log messages to the instance's ring buffer.
UzvIosMpvEvent uzv_ios_mpv_wait_event(uzv_mpv_instance *inst, double timeout_sec);

/// Returns a newly allocated string containing recent mpv error/warn logs (caller frees via `uzv_ios_mpv_free_cstr`).
char *uzv_ios_mpv_copy_recent_logs(uzv_mpv_instance *inst);

/// Converts an mpv error code to a human-readable string.
const char *uzv_ios_mpv_error_string(int error_code);

#ifdef __cplusplus
}
#endif

#endif /* UZV_IOS_MPV_BRIDGE_H */
