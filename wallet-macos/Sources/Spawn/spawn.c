#include "spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
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
int posix_spawnattr_destroy(posix_spawnattr_t *attr);
int posix_spawnattr_init(posix_spawnattr_t *attr);
int posix_spawnattr_setflags(posix_spawnattr_t *attr, short flags);

#if defined(__APPLE__)
enum {
    WALLET_NODE_POSIX_SPAWN_START_SUSPENDED = 0x0080,
};
#endif

enum {
    WALLET_NODE_READY_FD = 3,
    WALLET_NODE_ALIVE_FD = 4,
    WALLET_NODE_SECRET_FD = 5,
};

static int duplicate_for_spawn_if_needed(int fd, int target_fd, int *owned_fd) {
    *owned_fd = -1;

    if (fd == target_fd || (fd != WALLET_NODE_READY_FD && fd != WALLET_NODE_ALIVE_FD &&
                            fd != WALLET_NODE_SECRET_FD)) {
        return 0;
    }

    int duplicated = fcntl(fd, F_DUPFD_CLOEXEC, WALLET_NODE_SECRET_FD + 1);
    if (duplicated == -1) {
        return errno;
    }

    *owned_fd = duplicated;
    return 0;
}

static int add_close_if_extra(posix_spawn_file_actions_t *actions, int fd) {
    if (fd == WALLET_NODE_READY_FD || fd == WALLET_NODE_ALIVE_FD ||
        fd == WALLET_NODE_SECRET_FD) {
        return 0;
    }

    return posix_spawn_file_actions_addclose(actions, fd);
}

static void abort_spawned_child(pid_t pid) {
    if (pid <= 0) {
        return;
    }

    (void)kill(pid, SIGKILL);
    int status = 0;
    while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {
    }
}

int wallet_node_spawn_helper(const char *exec_path,
                             int ready_write_fd,
                             int alive_read_fd,
                             int secret_read_fd,
                             int start_suspended,
                             pid_t *out_pid) {
    if (exec_path == NULL || exec_path[0] == '\0' || out_pid == NULL ||
        ready_write_fd < 0 || alive_read_fd < 0 || secret_read_fd < 0 ||
        ready_write_fd == alive_read_fd || ready_write_fd == secret_read_fd ||
        alive_read_fd == secret_read_fd) {
        return EINVAL;
    }

    int owned_ready_fd = -1;
    int owned_alive_fd = -1;
    int owned_secret_fd = -1;
    int err = duplicate_for_spawn_if_needed(ready_write_fd, WALLET_NODE_READY_FD, &owned_ready_fd);
    if (err != 0) {
        return err;
    }
    int spawn_ready_fd = owned_ready_fd == -1 ? ready_write_fd : owned_ready_fd;
    err = duplicate_for_spawn_if_needed(alive_read_fd, WALLET_NODE_ALIVE_FD, &owned_alive_fd);
    if (err != 0) {
        if (owned_ready_fd != -1) {
            close(owned_ready_fd);
        }
        return err;
    }
    int spawn_alive_fd = owned_alive_fd == -1 ? alive_read_fd : owned_alive_fd;
    err = duplicate_for_spawn_if_needed(secret_read_fd, WALLET_NODE_SECRET_FD, &owned_secret_fd);
    if (err != 0) {
        if (owned_ready_fd != -1) {
            close(owned_ready_fd);
        }
        if (owned_alive_fd != -1) {
            close(owned_alive_fd);
        }
        return err;
    }
    int spawn_secret_fd = owned_secret_fd == -1 ? secret_read_fd : owned_secret_fd;

    posix_spawn_file_actions_t actions;
    err = posix_spawn_file_actions_init(&actions);
    if (err != 0) {
        if (owned_ready_fd != -1) {
            close(owned_ready_fd);
        }
        if (owned_alive_fd != -1) {
            close(owned_alive_fd);
        }
        if (owned_secret_fd != -1) {
            close(owned_secret_fd);
        }
        return err;
    }

    err = posix_spawn_file_actions_adddup2(&actions, spawn_ready_fd, WALLET_NODE_READY_FD);
    pid_t spawned_pid = 0;
    if (err == 0) {
        err = posix_spawn_file_actions_adddup2(&actions, spawn_alive_fd, WALLET_NODE_ALIVE_FD);
    }
    if (err == 0) {
        err = posix_spawn_file_actions_adddup2(&actions, spawn_secret_fd, WALLET_NODE_SECRET_FD);
    }
    if (err == 0) {
        err = add_close_if_extra(&actions, spawn_ready_fd);
    }
    if (err == 0) {
        err = add_close_if_extra(&actions, spawn_alive_fd);
    }
    if (err == 0) {
        err = add_close_if_extra(&actions, spawn_secret_fd);
    }

    posix_spawnattr_t attributes;
    int attributes_initialized = 0;
    if (err == 0 && start_suspended) {
#if defined(__APPLE__)
        err = posix_spawnattr_init(&attributes);
        if (err == 0) {
            attributes_initialized = 1;
            err = posix_spawnattr_setflags(
                &attributes,
                (short)WALLET_NODE_POSIX_SPAWN_START_SUSPENDED);
        }
#else
        err = ENOTSUP;
#endif
    }

    if (err == 0) {
        char *const argv[] = {
            (char *)exec_path,
            "--ready-fd",
            "3",
            "--alive-fd",
            "4",
            "--secret-fd",
            "5",
            NULL,
        };

        const posix_spawnattr_t *attributes_pointer =
            attributes_initialized ? &attributes : NULL;
        err = posix_spawn(
            &spawned_pid,
            exec_path,
            &actions,
            attributes_pointer,
            argv,
            WALLET_NODE_ENVIRON);
    }

    int attributes_destroy_err = attributes_initialized
        ? posix_spawnattr_destroy(&attributes)
        : 0;
    int destroy_err = posix_spawn_file_actions_destroy(&actions);
    if (owned_ready_fd != -1) {
        close(owned_ready_fd);
    }
    if (owned_alive_fd != -1) {
        close(owned_alive_fd);
    }
    if (owned_secret_fd != -1) {
        close(owned_secret_fd);
    }

    if (err != 0) {
        return err;
    }
    if (attributes_destroy_err != 0) {
        abort_spawned_child(spawned_pid);
        return attributes_destroy_err;
    }
    if (destroy_err != 0) {
        abort_spawned_child(spawned_pid);
        return destroy_err;
    }

    *out_pid = spawned_pid;
    return 0;
}
