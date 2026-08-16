#ifndef WALLET_NODE_SPAWN_H
#define WALLET_NODE_SPAWN_H

#include <sys/types.h>

typedef void *posix_spawnattr_t;
typedef void *posix_spawn_file_actions_t;

#ifdef __cplusplus
extern "C" {
#endif

int wallet_node_spawn_helper(const char *exec_path,
                             int ready_write_fd,
                             int alive_read_fd,
                             int secret_read_fd,
                             int start_suspended,
                             pid_t *out_pid);

#ifdef __cplusplus
}
#endif

#endif
