#include "CrossBuildLinux.h"

#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdarg.h>

// The engine's own entry point. xX_main_Xx.h defines xX_main_Xx() as a
// static inline and wires up the guest's argv/rootfs; main.c in the upstream
// tree drives it, and this file reproduces the parts of that sequence that make
// sense in-process (everything except host-terminal handling and process exit).
//
// These includes mirror main.c's, because xX_main_Xx.h expects the kernel, fs
// and emulator headers to be in scope already (it uses do_execve, task_run_current,
// struct task, the engine's errno names, and exit_hook).
#include "kernel/calls.h"
#include "kernel/task.h"
#include "fs/path.h"
#include "emu/cpu.h"
#include "emu/tlb.h"
#include "asbestos/frame.h"
#include "asbestos/asbestos.h"
#include "platform/host_context_aarch64.h"
#include "platform/native_fault.h"
#include "xX_main_Xx.h"

// Set by xX_main_Xx() and invoked by the engine when the root guest task exits.
// Upstream's own handler calls exit(), which would tear down the host app, so it
// is replaced below with one that unwinds only the guest thread.
extern void (*exit_hook)(struct task *task, int code);

// Defined below; referenced by the guest thread, so it must be declared first.
static void cblk_exit_hook(struct task *task, int code);

static int g_booted = 0;
static int g_guest_exit_code = 0;
static volatile int g_guest_finished = 0;
static char *g_stdout_buffer = NULL;
static char *g_stderr_buffer = NULL;

static char *cblk_strdup(const char *text) {
    if (text == NULL) { text = ""; }
    size_t n = strlen(text);
    char *copy = (char *)malloc(n + 1);
    if (copy == NULL) { return NULL; }
    memcpy(copy, text, n + 1);
    return copy;
}

// ---- guest output capture -------------------------------------------------
// xX_main_Xx() checks isatty(1): when stdout is not a terminal it wires the
// guest's stdio through create_piped_stdio(), so pointing fd 1/2 at pipes is
// enough to capture everything the guest writes, including printk (the engine
// duplicates stderr onto fd 666).

static int g_saved_stdout = -1;
static int g_saved_stderr = -1;

static int redirect_stdio_to_pipes(int pipe_fds[2]) {
    if (pipe(pipe_fds) != 0) { return -1; }
    g_saved_stdout = dup(STDOUT_FILENO);
    g_saved_stderr = dup(STDERR_FILENO);
    dup2(pipe_fds[1], STDOUT_FILENO);
    dup2(pipe_fds[1], STDERR_FILENO);
    close(pipe_fds[1]);
    // The engine duplicates stderr onto fd 666 for printk, so route that at the
    // pipe too (STDOUT_FILENO now refers to it).
    dup2(STDOUT_FILENO, 666);
    return 0;
}

static void restore_stdio(void) {
    if (g_saved_stdout >= 0) { dup2(g_saved_stdout, STDOUT_FILENO); close(g_saved_stdout); g_saved_stdout = -1; }
    if (g_saved_stderr >= 0) { dup2(g_saved_stderr, STDERR_FILENO); close(g_saved_stderr); g_saved_stderr = -1; }
}

static char *drain_fd(int fd) {
    size_t capacity = 8192;
    size_t length = 0;
    char *buffer = (char *)malloc(capacity);
    if (buffer == NULL) { return NULL; }
    for (;;) {
        if (length + 4096 + 1 > capacity) {
            capacity *= 2;
            char *grown = (char *)realloc(buffer, capacity);
            if (grown == NULL) { free(buffer); return NULL; }
            buffer = grown;
        }
        ssize_t got = read(fd, buffer + length, 4096);
        if (got <= 0) { break; }
        length += (size_t)got;
    }
    buffer[length] = '\0';
    return buffer;
}

// ---- boot -----------------------------------------------------------------

struct guest_boot_args {
    int argc;
    char **argv;
    const char *envp;
};

static void *guest_thread_main(void *opaque) {
    struct guest_boot_args *args = (struct guest_boot_args *)opaque;

    int err = xX_main_Xx(args->argc, args->argv, args->envp);
    if (err < 0) {
        fprintf(stderr, "xX_main_Xx: %s\n", strerror(-err));
        g_guest_exit_code = err;
        g_guest_finished = 1;
        return NULL;
    }

    // xX_main_Xx installs the engine's own exit handler, which calls exit() and
    // would take the host app down with it. Swap in one that records the code and
    // unwinds this thread instead, before the guest actually runs.
    exit_hook = cblk_exit_hook;

    // The parts of main.c that run after xX_main_Xx and are not terminal-related.
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/shm", 01777);
    generic_setattrat(AT_PWD, "/dev/shm", make_attr(mode, 01777), true);

    task_run_current();

    // task_run_current() does not return: the root task's exit path calls
    // exit_hook, which unwinds this thread via pthread_exit.
    g_guest_finished = 1;
    return NULL;
}

// Replaces the engine's handler, which calls exit(). Recording the code and
// unwinding just this thread keeps the host app alive.
static void cblk_exit_hook(struct task *task, int code) {
    (void)task;
    if (code & 0xff) {
        g_guest_exit_code = 128 + (code & 0xff);
    } else {
        g_guest_exit_code = code >> 8;
    }
    g_guest_finished = 1;
    pthread_exit(NULL);
}

static void cblk_append_env(char *buf, size_t cap, size_t *offset, const char *fmt, ...) {
    if (*offset >= cap) { return; }
    va_list ap;
    va_start(ap, fmt);
    int needed = vsnprintf(buf + *offset, cap - *offset, fmt, ap);
    va_end(ap);
    if (needed < 0) { return; }
    size_t n = (size_t)needed;
    if (n >= cap - *offset) { *offset = cap; buf[cap - 1] = '\0'; return; }
    *offset += n + 1;   // entries are NUL-separated
}

int32_t cblk_boot_and_run(const char *fakefsRoot,
                          const char *workingDirectory,
                          const char *command,
                          char **outStdout,
                          char **outStderr) {
    if (outStdout != NULL) { *outStdout = NULL; }
    if (outStderr != NULL) { *outStderr = NULL; }

    // The interpreter keeps process-global state (guest address space, task
    // tables), so a second boot in the same process is not supported.
    if (g_booted) {
        if (outStderr != NULL) { *outStderr = cblk_strdup("The Linux guest has already been booted in this process."); }
        if (outStdout != NULL) { *outStdout = cblk_strdup(""); }
        return -1;
    }
    if (fakefsRoot == NULL || fakefsRoot[0] == '\0') {
        if (outStderr != NULL) { *outStderr = cblk_strdup("No fakefs root supplied."); }
        if (outStdout != NULL) { *outStdout = cblk_strdup(""); }
        return -1;
    }
    g_booted = 1;

    // argv: ish -f <root> [-d <cwd>] /bin/sh -c <command>
    static char *argv[8];
    int argc = 0;
    argv[argc++] = (char *)"ish";
    argv[argc++] = (char *)"-f";
    argv[argc++] = (char *)fakefsRoot;
    if (workingDirectory != NULL && workingDirectory[0] != '\0') {
        argv[argc++] = (char *)"-d";
        argv[argc++] = (char *)workingDirectory;
    }
    argv[argc++] = (char *)"/bin/sh";
    if (command != NULL && command[0] != '\0') {
        argv[argc++] = (char *)"-c";
        argv[argc++] = (char *)command;
    }
    argv[argc] = NULL;

    static char envp[1024];
    size_t p = 0;
    cblk_append_env(envp, sizeof(envp), &p, "HOME=/root");
    cblk_append_env(envp, sizeof(envp), &p, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    cblk_append_env(envp, sizeof(envp), &p, "TERM=xterm-256color");
    cblk_append_env(envp, sizeof(envp), &p, "PYTHONMALLOC=malloc");

    // The engine's fault recovery expects an alternate signal stack.
    static char altstack[SIGSTKSZ];
    stack_t ss;
    ss.ss_sp = altstack;
    ss.ss_size = SIGSTKSZ;
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    int pipe_fds[2] = { -1, -1 };
    if (redirect_stdio_to_pipes(pipe_fds) != 0) {
        restore_stdio();
        if (outStderr != NULL) { *outStderr = cblk_strdup("Could not create capture pipes."); }
        if (outStdout != NULL) { *outStdout = cblk_strdup(""); }
        return -1;
    }

    struct guest_boot_args args;
    args.argc = argc;
    args.argv = argv;
    args.envp = envp;

    pthread_t thread;
    if (pthread_create(&thread, NULL, guest_thread_main, &args) != 0) {
        close(pipe_fds[0]);
        restore_stdio();
        if (outStderr != NULL) { *outStderr = cblk_strdup("Could not start the guest thread."); }
        if (outStdout != NULL) { *outStdout = cblk_strdup(""); }
        return -1;
    }
    pthread_join(thread, NULL);

    // Anything the guest wrote is sitting in the pipe.
    char *captured = drain_fd(pipe_fds[0]);
    close(pipe_fds[0]);
    restore_stdio();

    g_stdout_buffer = captured != NULL ? captured : cblk_strdup("");
    g_stderr_buffer = cblk_strdup("");

    if (outStdout != NULL) { *outStdout = g_stdout_buffer; }
    if (outStderr != NULL) { *outStderr = g_stderr_buffer; }
    return g_guest_exit_code;
}

int32_t cblk_has_booted(void) {
    return g_booted ? 1 : 0;
}

void cblk_free(char *text) {
    // The returned buffers are owned by this shim and reused across calls, so a
    // free here would be wrong; kept for API symmetry with the other shims.
    (void)text;
}

const char *cblk_engine_version(void) {
    return "ios-linuxkit 2.4.1 (build 818), AArch64 guest, asbestos interpreter";
}

// ---- persistent session ---------------------------------------------------
//
// Boots the guest once with an interactive /bin/sh whose stdio are host pipes,
// then streams commands to it. Each command is followed by a sentinel echo, so
// the reader knows when the output for that command is complete rather than
// guessing from timeouts.

#include <poll.h>

static int g_session_in = -1;       // host -> guest stdin
static int g_session_out = -1;      // guest stdout/stderr -> host
static int g_session_running = 0;
static pthread_t g_session_thread;
static char *g_session_scratch = NULL;
static size_t g_session_scratch_len = 0;
static unsigned g_session_serial = 0;

static int write_all(int fd, const char *text, size_t length) {
    size_t written = 0;
    while (written < length) {
        ssize_t n = write(fd, text + written, length - written);
        if (n <= 0) {
            if (errno == EINTR) { continue; }
            return -1;
        }
        written += (size_t)n;
    }
    return 0;
}

struct session_boot_args {
    int argc;
    char **argv;
    const char *envp;
};

static void *session_thread_main(void *opaque) {
    struct session_boot_args *args = (struct session_boot_args *)opaque;

    // Fault recovery is thread-local. The one-shot path installed an alternate
    // signal stack on its calling thread, but the persistent session runs the
    // emulator on this pthread. Without a stack here, guest faults/signals can
    // terminate the host iOS process (commonly exposed by long-lived servers).
    size_t altstack_size = (size_t)SIGSTKSZ * 4;
    void *altstack_mem = malloc(altstack_size);
    if (altstack_mem == NULL) {
        g_session_running = 0;
        return NULL;
    }
    stack_t ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = altstack_mem;
    ss.ss_size = altstack_size;
    if (sigaltstack(&ss, NULL) != 0) {
        free(altstack_mem);
        g_session_running = 0;
        return NULL;
    }

    int err = xX_main_Xx(args->argc, args->argv, args->envp);
    if (err < 0) {
        fprintf(stderr, "xX_main_Xx: %s\n", strerror(-err));
        g_session_running = 0;
        return NULL;
    }
    exit_hook = cblk_exit_hook;   // see the one-shot path: do not let the guest exit() the app

    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/shm", 01777);
    generic_setattrat(AT_PWD, "/dev/shm", make_attr(mode, 01777), true);

    task_run_current();
    g_session_running = 0;

    stack_t disabled;
    memset(&disabled, 0, sizeof(disabled));
    disabled.ss_flags = SS_DISABLE;
    sigaltstack(&disabled, NULL);
    free(altstack_mem);
    return NULL;
}

int32_t cblk_session_start(const char *fakefsRoot, const char *workingDirectory) {
    if (g_session_running) { return 0; }
    if (g_booted) {
        // The interpreter cannot be booted twice in one process.
        return -1;
    }
    if (fakefsRoot == NULL || fakefsRoot[0] == '\0') { return -1; }
    g_booted = 1;

    int toGuest[2] = { -1, -1 };
    int fromGuest[2] = { -1, -1 };
    if (pipe(toGuest) != 0) { return -2; }
    if (pipe(fromGuest) != 0) {
        close(toGuest[0]);
        close(toGuest[1]);
        return -2;
    }

    // The guest reads commands from fd 0 and writes output to fd 1/2, so the
    // host holds the opposite ends.
    g_saved_stdout = dup(STDOUT_FILENO);
    g_saved_stderr = dup(STDERR_FILENO);
    int saved_stdin = dup(STDIN_FILENO);
    dup2(toGuest[0], STDIN_FILENO);
    dup2(fromGuest[1], STDOUT_FILENO);
    dup2(fromGuest[1], STDERR_FILENO);
    dup2(STDOUT_FILENO, 666);          // printk
    close(toGuest[0]);
    close(fromGuest[1]);

    // Interactive shell with no -c: it stays alive and reads commands.
    static char *argv[8];
    int argc = 0;
    argv[argc++] = (char *)"ish";
    argv[argc++] = (char *)"-f";
    argv[argc++] = (char *)fakefsRoot;
    if (workingDirectory != NULL && workingDirectory[0] != '\0') {
        argv[argc++] = (char *)"-d";
        argv[argc++] = (char *)workingDirectory;
    }
    argv[argc++] = (char *)"/bin/sh";
    argv[argc] = NULL;

    static char envp[1024];
    size_t p = 0;
    cblk_append_env(envp, sizeof(envp), &p, "HOME=/root");
    cblk_append_env(envp, sizeof(envp), &p, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    cblk_append_env(envp, sizeof(envp), &p, "TERM=dumb");
    cblk_append_env(envp, sizeof(envp), &p, "PS1=");

    static struct session_boot_args args;
    args.argc = argc;
    args.argv = argv;
    args.envp = envp;

    g_session_in = toGuest[1];
    g_session_out = fromGuest[0];
    g_session_running = 1;

    if (pthread_create(&g_session_thread, NULL, session_thread_main, &args) != 0) {
        g_session_running = 0;
        if (g_session_in >= 0) { close(g_session_in); g_session_in = -1; }
        if (g_session_out >= 0) { close(g_session_out); g_session_out = -1; }
        restore_stdio();
        if (saved_stdin >= 0) { dup2(saved_stdin, STDIN_FILENO); close(saved_stdin); }
        return -2;
    }

    // The guest inherited the redirected descriptors. Restore the app process's
    // standard descriptors immediately; leaving stdin/stdout/stderr redirected
    // for the lifetime of the session destabilizes host logging and frameworks.
    restore_stdio();
    if (saved_stdin >= 0) { dup2(saved_stdin, STDIN_FILENO); close(saved_stdin); }

    // Wait for the shell to come up by round-tripping a marker.
    char *ready = NULL;
    int rc = cblk_session_run(":", 30000, &ready);
    if (ready != NULL) { free(ready); }
    return rc;
}

int32_t cblk_session_is_running(void) {
    return g_session_running ? 1 : 0;
}

// Appends to a growable scratch buffer, used to accumulate one command's output.
static int scratch_append(const char *text, size_t length) {
    if (g_session_scratch_len + length + 1 > g_session_scratch_len) {
        size_t want = g_session_scratch_len + length + 1;
        char *grown = (char *)realloc(g_session_scratch, want);
        if (grown == NULL) { return -1; }
        g_session_scratch = grown;
    }
    memcpy(g_session_scratch + g_session_scratch_len, text, length);
    g_session_scratch_len += length;
    g_session_scratch[g_session_scratch_len] = '\0';
    return 0;
}

int32_t cblk_session_run(const char *command, int32_t timeoutMs, char **outCombined) {
    if (outCombined != NULL) { *outCombined = NULL; }
    if (!g_session_running) {
        if (outCombined != NULL) { *outCombined = cblk_strdup("The Linux guest is not running."); }
        return -1;
    }

    unsigned serial = ++g_session_serial;
    char marker[64];
    snprintf(marker, sizeof(marker), "__CB_DONE_%u__", serial);

    // The command, then an echoed sentinel on its own line. The trailing newline
    // after the marker keeps it unambiguous even if the command's own output
    // lacks one.
    char *script = NULL;
    if (asprintf(&script, "%s\nprintf '\\n%s\\n'\n", command, marker) < 0 || script == NULL) {
        if (outCombined != NULL) { *outCombined = cblk_strdup("Out of memory building the command."); }
        return -1;
    }
    if (write_all(g_session_in, script, strlen(script)) != 0) {
        free(script);
        if (outCombined != NULL) { *outCombined = cblk_strdup("Could not write to the guest."); }
        return -1;
    }
    free(script);

    if (g_session_scratch != NULL) { free(g_session_scratch); g_session_scratch = NULL; }
    g_session_scratch_len = 0;

    // Read until the sentinel appears or the deadline passes.
    char chunk[4096];
    int found = 0;
    int elapsedMs = 0;
    while (elapsedMs < timeoutMs) {
        struct pollfd pfd;
        pfd.fd = g_session_out;
        pfd.events = POLLIN;
        int ready = poll(&pfd, 1, 100);
        elapsedMs += 100;
        if (ready <= 0) { continue; }
        ssize_t got = read(g_session_out, chunk, sizeof(chunk));
        if (got <= 0) { break; }
        if (scratch_append(chunk, (size_t)got) != 0) { break; }
        if (strstr(g_session_scratch, marker) != NULL) { found = 1; break; }
    }

    // Trim the sentinel and the echoed command tail from the captured text.
    if (g_session_scratch != NULL) {
        char *at = strstr(g_session_scratch, marker);
        if (at != NULL) { *at = '\0'; }
        // Drop the leading newline the sentinel printf emitted.
        size_t len = strlen(g_session_scratch);
        while (len > 0 && (g_session_scratch[len - 1] == '\n' || g_session_scratch[len - 1] == '\r')) {
            g_session_scratch[--len] = '\0';
        }
    }
    if (outCombined != NULL) {
        *outCombined = g_session_scratch != NULL ? g_session_scratch : cblk_strdup("");
    }
    if (!found) { return 124; }   // timed out, matching the helper's convention
    return 0;
}

void cblk_session_stop(void) {
    if (g_session_in >= 0) { close(g_session_in); g_session_in = -1; }
    if (g_session_out >= 0) { close(g_session_out); g_session_out = -1; }
    g_session_running = 0;
    restore_stdio();
}
