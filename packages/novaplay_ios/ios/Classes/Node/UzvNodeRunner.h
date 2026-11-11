#ifndef UZV_NODE_RUNNER_H
#define UZV_NODE_RUNNER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Starts the embedded Node.js runtime (NodeMobile.framework) on a 4 MiB stack pthread
/// and blocks the calling background thread until the Node event loop exits.
///
/// Returns:
///   >= 0 : Node exit code
///   -1   : Thread / memory setup error
///   -2   : NodeMobile.framework not bundled or symbol `node_start` missing
int uzv_ios_start_node(
    int argc,
    const char *const *argv,
    const char *bridge_port,
    const char *bridge_token,
    const char *data_dir,
    char *err_buf,
    int err_buf_len
);

#ifdef __cplusplus
}
#endif

#endif /* UZV_NODE_RUNNER_H */
