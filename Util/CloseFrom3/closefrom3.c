/*
 * closefrom3 — close all file descriptors >= 3, then exec argv.
 *
 * Uses the close_range(2) syscall (Linux 5.9+) for a single-syscall
 * cleanup of leaked file descriptors before exec'ing a child process.
 *
 * Typical use: prevent a daemon spawned by the child from inheriting
 * pipe fds from the parent, which would keep the pipe open indefinitely.
 *
 * Usage: closefrom3 <program> [args...]
 *
 * stdin (fd 0), stdout (fd 1), and stderr (fd 2) are preserved.
 */

#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: closefrom3 <program> [args...]\n");
        return 1;
    }

    syscall(SYS_close_range, 3, ~0U, 0);
    execvp(argv[1], argv + 1);

    perror(argv[1]);
    return 127;
}
