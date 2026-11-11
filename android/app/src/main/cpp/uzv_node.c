/*
 * JNI entry into the embedded Node.js runtime: NodeRuntime.startNodeWithArguments(String[], String?, boolean): Int.
 *
 * OBSERVED (libflutter_nodejs_mobile.so of the original APK): that library has NO JNI exports. It is a Dart-FFI library
 * (flutter_node_start, flutter_register_node_data_dir_path, flutter_register_bridge_cb, flutter_bridge_notify,
 * flutter_bridge_free_str) that registers a "flutter_bridge" native module and calls node::Start from libnode.so. This
 * project does not reproduce that bridge (it talks to Node over a loopback socket, see node_host/src/bridge_tcp.js), so all it
 * needs from the runtime is node::Start(argc, argv), which libnode.so exports; this file calls it directly.
 *
 * libnode.so is dlopen()ed, not linked, so the app still builds and loads without it (the UnsatisfiedLinkError then
 * comes from System.loadLibrary("node") in NodeRuntime, as before).
 */
#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TAG "UzvNode"
#define NODE_STACK_SIZE (4u * 1024u * 1024u) /* Node assumes a roomy main-thread stack; Android threads get ~1 MiB by default */

typedef int (*node_start_fn)(int, char **);

typedef struct {
    int argc;
    char **argv;
    node_start_fn start;
    int result;
} NodeRun;

static void *run_node(void *p) {
    NodeRun *run = p;
    run->result = run->start(run->argc, run->argv);
    return NULL;
}

static int log_pipe[2] = {-1, -1};

/* Node's stdout / stderr go to logcat under the tag NODEJS, one line per entry. */
static void *pump_to_logcat(void *unused) {
    (void)unused;
    char buf[2048];
    size_t len = 0;
    ssize_t n;
    while ((n = read(log_pipe[0], buf + len, sizeof buf - 1 - len)) > 0) {
        len += (size_t)n;
        char *line = buf;
        char *nl;
        while ((nl = memchr(line, '\n', (size_t)(buf + len - line))) != NULL) {
            *nl = '\0';
            __android_log_write(ANDROID_LOG_INFO, "NODEJS", line);
            line = nl + 1;
        }
        len = (size_t)(buf + len - line);
        memmove(buf, line, len);
        if (len == sizeof buf - 1) { /* a line longer than the buffer: flush it as it is */
            buf[len] = '\0';
            __android_log_write(ANDROID_LOG_INFO, "NODEJS", buf);
            len = 0;
        }
    }
    return NULL;
}

static void redirect_output_to_logcat(void) {
    if (log_pipe[0] >= 0) return;
    if (pipe(log_pipe) != 0) return;
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    dup2(log_pipe[1], STDOUT_FILENO);
    dup2(log_pipe[1], STDERR_FILENO);
    pthread_t t;
    if (pthread_create(&t, NULL, pump_to_logcat, NULL) == 0) pthread_detach(t);
}

JNIEXPORT jint JNICALL Java_com_example_uzv_node_NodeRuntime_startNodeWithArguments(JNIEnv *env, jclass cls, jobjectArray args,
                                                                                    jstring node_path, jboolean redirect) {
    (void)cls;
    void *lib = dlopen("libnode.so", RTLD_NOW);
    node_start_fn start = lib ? (node_start_fn)dlsym(lib, "_ZN4node5StartEiPPc") : NULL;
    if (!start) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "node::Start not found in libnode.so: %s", dlerror());
        return -1;
    }
    if (node_path) {
        const char *p = (*env)->GetStringUTFChars(env, node_path, NULL);
        if (p) {
            setenv("NODE_PATH", p, 1);
            (*env)->ReleaseStringUTFChars(env, node_path, p);
        }
    }
    if (redirect) redirect_output_to_logcat();

    /* libuv's uv_setup_args() wants argv in one contiguous block that outlives the call. */
    jsize argc = args ? (*env)->GetArrayLength(env, args) : 0;
    size_t total = 0;
    for (jsize i = 0; i < argc; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, args, i);
        total += (size_t)(*env)->GetStringUTFLength(env, s) + 1;
        (*env)->DeleteLocalRef(env, s);
    }
    char **argv = calloc((size_t)argc + 1, sizeof(char *));
    char *block = malloc(total ? total : 1);
    if (!argv || !block) return -1;
    char *cursor = block;
    for (jsize i = 0; i < argc; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, args, i);
        jsize n = (*env)->GetStringUTFLength(env, s);
        (*env)->GetStringUTFRegion(env, s, 0, (*env)->GetStringLength(env, s), cursor);
        cursor[n] = '\0';
        argv[i] = cursor;
        cursor += n + 1;
        (*env)->DeleteLocalRef(env, s);
    }

    NodeRun run = {(int)argc, argv, start, -1};
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, NODE_STACK_SIZE);
    pthread_t thread;
    if (pthread_create(&thread, &attr, run_node, &run) != 0) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "could not start the Node thread");
        pthread_attr_destroy(&attr);
        return -1;
    }
    pthread_attr_destroy(&attr);
    pthread_join(thread, NULL); /* node::Start returns when the event loop ends; the argv block must stay valid until then */
    __android_log_print(ANDROID_LOG_INFO, TAG, "node::Start returned %d", run.result);
    return run.result;
}
