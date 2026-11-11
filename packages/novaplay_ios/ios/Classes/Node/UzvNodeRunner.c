#include "UzvNodeRunner.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* iOS background pthreads default to 512 KiB stack, which overflows V8 parser/compiler frames.
 * Match Android's 4 MiB stack allocation for embedded Node.js. */
#define UZV_IOS_NODE_STACK_SIZE (4u * 1024u * 1024u)

typedef int (*uzv_node_start_fn)(int, char **);

typedef struct {
    int argc;
    char **argv;
    uzv_node_start_fn start_fn;
    int exit_code;
} UzvNodeRunContext;

static void *uzv_run_node_thread(void *ctx_ptr) {
    UzvNodeRunContext *ctx = (UzvNodeRunContext *)ctx_ptr;
    pthread_setname_np("uzv-nodejs-main");
    ctx->exit_code = ctx->start_fn(ctx->argc, ctx->argv);
    return NULL;
}

static uzv_node_start_fn uzv_resolve_node_start(char *err_buf, int err_buf_len) {
    uzv_node_start_fn fn = (uzv_node_start_fn)dlsym(RTLD_DEFAULT, "node_start");
    if (!fn) {
        fn = (uzv_node_start_fn)dlsym(RTLD_DEFAULT, "_ZN4node5StartEiPPc");
    }
    if (fn) return fn;

    const char *candidates[] = {
        "@rpath/NodeMobile.framework/NodeMobile",
        "@executable_path/Frameworks/NodeMobile.framework/NodeMobile",
        NULL
    };
    const char *last_dl_err = NULL;
    for (int i = 0; candidates[i] != NULL; i++) {
        void *handle = dlopen(candidates[i], RTLD_NOW | RTLD_GLOBAL);
        if (!handle) {
            last_dl_err = dlerror();
            continue;
        }
        fn = (uzv_node_start_fn)dlsym(handle, "node_start");
        if (!fn) {
            fn = (uzv_node_start_fn)dlsym(handle, "_ZN4node5StartEiPPc");
        }
        if (fn) return fn;
        last_dl_err = dlerror();
    }

    if (err_buf && err_buf_len > 0) {
        snprintf(
            err_buf,
            (size_t)err_buf_len,
            "NodeMobile.framework unavailable (%s)",
            last_dl_err ? last_dl_err : "symbol node_start not found"
        );
    }
    return NULL;
}

int uzv_ios_start_node(
    int argc,
    const char *const *argv,
    const char *bridge_port,
    const char *bridge_token,
    const char *data_dir,
    char *err_buf,
    int err_buf_len
) {
    if (err_buf && err_buf_len > 0) {
        err_buf[0] = '\0';
    }

    uzv_node_start_fn start_fn = uzv_resolve_node_start(err_buf, err_buf_len);
    if (!start_fn) {
        return -2;
    }

    if (bridge_port) setenv("UZV_BRIDGE_PORT", bridge_port, 1);
    if (bridge_token) setenv("UZV_BRIDGE_TOKEN", bridge_token, 1);
    if (data_dir) setenv("UZV_DATA_DIR", data_dir, 1);

    if (argc <= 0 || !argv) {
        if (err_buf && err_buf_len > 0) {
            snprintf(err_buf, (size_t)err_buf_len, "Invalid Node argv");
        }
        return -1;
    }

    /* libuv uv_setup_args() requires argv strings to reside in one contiguous memory block. */
    size_t total_bytes = 0;
    for (int i = 0; i < argc; i++) {
        total_bytes += strlen(argv[i]) + 1;
    }

    char **c_argv = (char **)calloc((size_t)argc + 1, sizeof(char *));
    char *contig_block = (char *)malloc(total_bytes > 0 ? total_bytes : 1);
    if (!c_argv || !contig_block) {
        free(c_argv);
        free(contig_block);
        if (err_buf && err_buf_len > 0) {
            snprintf(err_buf, (size_t)err_buf_len, "Out of memory allocating Node argv");
        }
        return -1;
    }

    char *cursor = contig_block;
    for (int i = 0; i < argc; i++) {
        size_t len = strlen(argv[i]);
        memcpy(cursor, argv[i], len + 1);
        c_argv[i] = cursor;
        cursor += len + 1;
    }
    c_argv[argc] = NULL;

    UzvNodeRunContext ctx;
    ctx.argc = argc;
    ctx.argv = c_argv;
    ctx.start_fn = start_fn;
    ctx.exit_code = -1;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, UZV_IOS_NODE_STACK_SIZE);

    pthread_t thread;
    int rc = pthread_create(&thread, &attr, uzv_run_node_thread, &ctx);
    pthread_attr_destroy(&attr);

    if (rc != 0) {
        free(c_argv);
        free(contig_block);
        if (err_buf && err_buf_len > 0) {
            snprintf(err_buf, (size_t)err_buf_len, "pthread_create failed with code %d", rc);
        }
        return -1;
    }

    pthread_join(thread, NULL);
    free(c_argv);
    free(contig_block);
    return ctx.exit_code;
}
