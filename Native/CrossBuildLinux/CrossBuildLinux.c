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
#include "xX_main_Xx.h"

// Set by xX_main_Xx() and invoked by the engine when the root guest task exits.
// Upstream's own handler calls exit(), which would tear down the host app, so it
// is replaced below with one that unwinds only the guest thread.
extern void (*exit_hook)(struct task *task, int code);

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
