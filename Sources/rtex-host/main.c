// Keep the engine and its LuaTeX workers in a private process group. The group
// leader stays alive through cleanup, so its group ID cannot be reused meanwhile.
#include <errno.h>
#include <limits.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t stopping = 0;
static void request_stop(int signal_number) { stopping = signal_number; }

static void kill_workers(int signal_number) {
    pid_t group = getpgrp();
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, NULL, 0);
    if (bytes <= 0) return;
    // Extra capacity covers workers created between sizing and enumeration.
    bytes += 128 * (int)sizeof(pid_t);
    pid_t *pids = calloc(1, (size_t)bytes);
    if (!pids) return;
    int count = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, pids, bytes) / (int)sizeof(pid_t);
    for (int i = 0; i < count; ++i) {
        if (pids[i] > 0 && pids[i] != getpid() && getpgid(pids[i]) == group)
            kill(pids[i], signal_number);
    }
    free(pids);
}

int main(int argc, char **argv) {
    (void)argc;
    char executable[PATH_MAX], resolved[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, resolved)) {
        perror("rtex-host: executable path"); return 127;
    }
    char *slash = strrchr(resolved, '/');
    if (!slash || (size_t)(slash - resolved) + sizeof("/rtex") > sizeof(resolved)) return 127;
    strcpy(slash, "/rtex");
    // Foundation may already have made us a group leader. Either way, the group
    // must be ours before the Rust process and its workers can launch.
    if (setsid() < 0 && getpgrp() != getpid()) {
        perror("rtex-host: private process group"); return 127;
    }
    struct sigaction action = {0};
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGHUP, &action, NULL);
    pid_t owner = getppid();
    if (owner == 1) return 0;
    pid_t child = fork();
    if (child < 0) { perror("rtex-host: fork"); return 127; }
    if (child == 0) {
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL);
        argv[0] = resolved;
        execv(resolved, argv);
        perror("rtex-host: rtex"); _exit(127);
    }
    int status = 0;
    while (!stopping) {
        if (getppid() != owner) { stopping = SIGTERM; break; }
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) break;
        if (result < 0 && errno != EINTR) break;
        usleep(20000);
    }
    int interrupted = stopping;
    // Killing the whole group with TERM also reaches workers that fork during
    // cleanup; the supervisor handles TERM itself and remains alive.
    kill(-getpgrp(), SIGTERM);
    for (int i = 0; i < 10; ++i) { usleep(20000); kill_workers(SIGTERM); }
    for (int i = 0; i < 3; ++i) { kill_workers(SIGKILL); usleep(10000); }
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    if (interrupted) return 0;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
