#include "spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <crt_externs.h>
#define WALLET_NODE_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define WALLET_NODE_ENVIRON environ
#endif

int posix_spawn(pid_t *restrict pid,
                const char *restrict path,
                const posix_spawn_file_actions_t *file_actions,
                const posix_spawnattr_t *restrict attrp,
                char *const argv[restrict],
                char *const envp[restrict]);
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *file_actions, int filedes);
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *file_actions,
                                     int filedes,
                                     int newfiledes);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *file_actions);
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *file_actions);

enum {
    WALLET_NODE_READY_FD = 3,
    WALLET_NODE_ALIVE_FD = 4,
};

static int duplicate_for_spawn_if_needed(int fd, int *owned_fd) {
    *owned_fd = -1;

    if (fd != WALLET_NODE_READY_FD) {
        return 0;
    }

    int duplicated = fcntl(fd, F_DUPFD_CLOEXEC, WALLET_NODE_ALIVE_FD + 1);
    if (duplicated == -1) {
        return errno;
    }

    *owned_fd = duplicated;
    return 0;
}

static int add_close_if_extra(posix_spawn_file_actions_t *actions, int fd) {
    if (fd == WALLET_NODE_READY_FD || fd == WALLET_NODE_ALIVE_FD) {
        return 0;
    }

    return posix_spawn_file_actions_addclose(actions, fd);
}

int wallet_node_spawn_helper(const char *exec_path,
                             int ready_write_fd,
                             int alive_read_fd,
                             pid_t *out_pid) {
    if (exec_path == NULL || exec_path[0] == '\0' || out_pid == NULL ||
        ready_write_fd < 0 || alive_read_fd < 0 || ready_write_fd == alive_read_fd) {
        return EINVAL;
    }

    int owned_alive_fd = -1;
    int err = duplicate_for_spawn_if_needed(alive_read_fd, &owned_alive_fd);
    if (err != 0) {
        return err;
    }
    int spawn_alive_fd = owned_alive_fd == -1 ? alive_read_fd : owned_alive_fd;

    posix_spawn_file_actions_t actions;
    err = posix_spawn_file_actions_init(&actions);
    if (err != 0) {
        if (owned_alive_fd != -1) {
            close(owned_alive_fd);
        }
        return err;
    }

    err = posix_spawn_file_actions_adddup2(&actions, ready_write_fd, WALLET_NODE_READY_FD);
    if (err == 0) {
        err = posix_spawn_file_actions_adddup2(&actions, spawn_alive_fd, WALLET_NODE_ALIVE_FD);
    }
    if (err == 0) {
        err = add_close_if_extra(&actions, ready_write_fd);
    }
    if (err == 0) {
        err = add_close_if_extra(&actions, spawn_alive_fd);
    }

    if (err == 0) {
        char *const argv[] = {
            (char *)exec_path,
            "--ready-fd",
            "3",
            "--alive-fd",
            "4",
            NULL,
        };

        pid_t pid = 0;
        err = posix_spawn(&pid, exec_path, &actions, NULL, argv, WALLET_NODE_ENVIRON);
        if (err == 0) {
            *out_pid = pid;
        }
    }

    int destroy_err = posix_spawn_file_actions_destroy(&actions);
    if (owned_alive_fd != -1) {
        close(owned_alive_fd);
    }

    if (err != 0) {
        return err;
    }
    return destroy_err;
}
