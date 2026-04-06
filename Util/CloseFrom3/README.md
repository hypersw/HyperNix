# closefrom3

Close all file descriptors >= 3, then exec a program.

```
closefrom3 <program> [args...]
```

A single `close_range(3, ~0U, 0)` syscall (Linux 5.9+) followed by `execvp`.
Stdin, stdout, and stderr are preserved.

## Why This Exists

### The Problem

SSH runs `SSH_ASKPASS` programs as child processes with stdout connected to a pipe.
SSH reads the pipe to get the password/PIN. The pipe stays open until **all** write
ends are closed — not just the askpass process itself, but any grandchild processes
that inherited the fd.

When the askpass script calls `git credential-cache store` to cache the password,
git spawns a `credential-cache--daemon` process that runs indefinitely (until
timeout). This daemon inherits all file descriptors from its parent chain,
including the SSH pipe fd. SSH sees the pipe still open and waits forever.

### What We Tried

**1. Redirecting stdout/stderr to /dev/null on the git command:**
```sh
echo "$value"  # to SSH
git credential-cache store >/dev/null 2>/dev/null
```
Didn't work. The shell's pipe machinery (`printf ... | git ...`) creates the
pipe on a high-numbered fd. Redirecting fds 1 and 2 doesn't affect it. The
daemon inherits the high fd.

**2. Backgrounding the store command:**
```sh
echo "$value"
git credential-cache store ... &
```
Worse — the backgrounded subshell keeps the pipe fd, and the daemon inherits
from it. SSH still hangs.

**3. `exec 1>&-` (closing stdout before store):**
```sh
echo "$value"
exec 1>&-
git credential-cache store ...
```
Didn't work. The SSH pipe fd is on a high-numbered fd (bash internal bookkeeping),
not fd 1. Closing fd 1 doesn't close the copies on fds 10+.

**4. Subshell with all output redirected:**
```sh
echo "$value"
(git credential-cache store ...) </dev/null >/dev/null 2>/dev/null &
```
Didn't work. The subshell inherits all parent fds before the redirects take
effect at the fork boundary. The daemon gets the inherited fds.

**5. `exec` to replace the process:**
```sh
echo "$value"
exec /bin/sh -c '...' </dev/null >/dev/null 2>/dev/null
```
Didn't work. `exec` with redirections replaces fds 0/1/2 but preserves all
higher fds. The SSH pipe on fd 10+ survives across exec.

**6. `setsid` for a new session:**
```sh
echo "$value"
printf ... | setsid git credential-cache store >/dev/null 2>/dev/null
```
Didn't work. `setsid` creates a new session and detaches from the controlling
terminal, but does not close file descriptors. All inherited fds survive.

**7. Closing fds 3-1024 in a loop:**
```sh
echo "$value"
printf ... | /bin/sh -c '
  i=3; while [ $i -lt 1024 ]; do eval "exec ${i}>&-" 2>/dev/null; i=$((i+1)); done
  git credential-cache store
' >/dev/null 2>/dev/null
```
Worked! But fragile (guesses max fd number), slow (loops 1021 times), and ugly.

**8. `systemd-run --user --pipe --wait`:**
```sh
echo "$value"
printf ... | systemd-run --user --pipe --wait --quiet git credential-cache store
```
No hang (systemd forks from PID 1, clean fds). But the credential-cache daemon
spawned inside the systemd scope dies with the scope, so the cache doesn't persist.

### The Solution

`close_range(3, ~0U, 0)` — a single Linux syscall that atomically closes all
file descriptors from 3 to the maximum. Available since Linux 5.9 (2020), glibc
2.34 (2021). Not callable from shell, so this tiny C wrapper exists.

```sh
echo "$value"
printf ... | closefrom3 git credential-cache store >/dev/null 2>/dev/null
```

The `closefrom3` binary sits between the pipe and `git`: it inherits the pipe on
stdin (fd 0), closes everything >= 3 (including the leaked SSH pipe fd), then
exec's `git credential-cache store` which reads credentials from stdin normally.
The daemon it spawns starts with a clean fd table — no SSH pipe to keep open.

## Building

```
nix build
# or
cc -O2 -Wall -o closefrom3 closefrom3.c
```

## Requirements

- Linux >= 5.9 (for `close_range` syscall)
