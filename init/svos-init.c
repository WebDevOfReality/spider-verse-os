/*
 * svos-init — PID 1 for Spider-Verse OS (Stage 2b)
 *
 * Provenance: drafted with AI assistance (GLM (glm-5.3-flash) by Z.ai)
 * at Anthony's request; every line explainable on demand (AGENTS.md §4).
 *
 * What PID 1 actually has to do on an initramfs boot:
 *   1. mount proc, sysfs, devtmpfs (nothing else will do it)
 *   2. open /dev/console so init's own stdio (and its children's) works —
 *      the kernel warns "unable to open an initial console" because devtmpfs
 *      does not exist yet when it launches PID 1
 *   3. spawn a shell on the console in its own session (setsid, so ^C etc.
 *      work), and respawn it forever when it dies
 *   4. reap orphans: every process whose parent dies is reparented to PID 1;
 *      if we don't wait() for them, they stay zombies forever
 *   5. never exit — the kernel panics "Attempted to kill init" if we do
 *
 * Signals PID 1 must handle (see signal(7), "SIGKILL/SIGSTOP cannot be caught"):
 *   SIGCHLD  a child exited — wait() for it
 *   SIGINT   kernel maps ctrl-alt-del / console break to SIGINT on PID 1
 *   SIGHUP   console hangup (serial line dropped)
 *   SIGTERM/SIGQUIT/SIGUSR*  we ignore; PID 1 has default-immunity anyway
 *                            unless a handler is installed (signal(7))
 */

/* svos-init uses POSIX.2008 + the XSI bits musl gates (sync(2)) */
#define _XOPEN_SOURCE 700

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
/* sync(2) is in unistd.h on glibc but <sys/...> only via _XOPEN_SOURCE on musl */
#include <sys/utsname.h>

#define CONSOLE "/dev/console"
#define SHELL   "/bin/sh"

static volatile sig_atomic_t got_sigint;

static void xmount(const char *src, const char *tgt, const char *fstype)
{
	/* mkdir so a truly empty initramfs still works */
	mkdir(tgt, 0755);
	if (mount(src, tgt, fstype, 0, NULL) != 0)
		fprintf(stderr, "svos-init: mount %s: %s\n", tgt, strerror(errno));
}

static void on_sigchld(int sig)
{
	(void)sig;
	/* reap everything that's ours, without blocking */
	for (;;) {
		int status;
		pid_t pid = waitpid(-1, &status, WNOHANG);
		if (pid <= 0)
			break;
	}
}

static void on_sigint(int sig)
{
	(void)sig;   /* the signal number itself carries no extra meaning here */
	got_sigint = (sig_atomic_t)1;
}

static void spawn_shell(void)
{
	pid_t pid;

	/*
	 * setsid: new session + controlling terminal on the (already opened)
	 * console. Without this the shell has no job control ("can't access
	 * tty" in Stage 1 came from this).
	 */
	pid = fork();
	if (pid == 0) {
		setsid();
		/* make console our controlling tty: TIOCSCTTY needs no arg here */
		ioctl(0, TIOCSCTTY, 0);
		execl(SHELL, "sh", (char *)NULL);
		/* only reached on failure */
		_exit(127);
	}
	if (pid < 0)
		fprintf(stderr, "svos-init: fork: %s\n", strerror(errno));
}

static void banner(void)
{
	/*
	 * ASCII art kept from Stage 1: hand-made by Anthony (AGENTS.md §2 —
	 * AI must not generate art; reproducing an existing human-made asset
	 * byte-for-byte is copying, not generating).
	 */
	printf("\n");
	printf("        .-\"\"\"-.        Spider-Verse OS\n");
	printf("       / _   _ \\       ===========================\n");
	printf("      | (o) (o) |      Weaver (Stage 2)\n");
	printf("      |    ^    |\n");
	printf("       \\  ---  /       init: svos-init (C) | libc: musl\n");
	printf("        `-----`        userland: busybox\n");
	printf("      web-spinner\n");
	printf("\n");

	/* read kernel version out of procfs rather than linking extra APIs */
	{
		FILE *v = fopen("/proc/version", "r");
		char line[128];
		if (v && fgets(line, sizeof(line), v)) {
			line[strcspn(line, "\n")] = '\0';
			printf("weaver: %s\n", line);
		} else {
			printf("weaver: kernel version unavailable\n");
		}
		if (v)
			fclose(v);
	}
	printf("weaver: pid1 = svos-init, arch x86_64\n");
}

int main(void)
{
	/* 1. filesystems first — nothing exists before this */
	xmount("proc",  "/proc",  "proc");
	xmount("sysfs", "/sys",   "sysfs");
	xmount("devtmpfs", "/dev", "devtmpfs");
	mkdir("/tmp", 0755);
	mount("tmpfs", "/tmp", "tmpfs", 0, NULL);

	/* 2. console: re-open our stdio onto the real device */
	{
		int fd = open(CONSOLE, O_RDWR);
		if (fd >= 0) {
			dup2(fd, 0);
			dup2(fd, 1);
			dup2(fd, 2);
			if (fd > 2)
				close(fd);
		} else {
			fprintf(stderr, "svos-init: open %s: %s\n",
				CONSOLE, strerror(errno));
		}
	}

	/* 3. signal plumbing before anything can die on us */
	signal(SIGCHLD, on_sigchld);
	signal(SIGINT,  on_sigint);   /* ctrl-alt-del lands here */
	signal(SIGHUP,  SIG_IGN);     /* serial carrier drops must not kill us */
	setvbuf(stdout, NULL, _IONBF, 0);

	banner();

	/* 4. PID 1 loop: spawn, wait, respawn, reap, never exit */
	for (;;) {
		spawn_shell();
		pause();   /* sleep until any signal arrives */

		if (got_sigint) {
			got_sigint = 0;
			/* ctrl-alt-del = reboot the machine */
			sync();
			reboot(RB_AUTOBOOT);
		}
		/* SIGCHLD also wakes pause(); loop re-spawns the shell */
	}
}