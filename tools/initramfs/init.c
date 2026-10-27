/*
 * Minimal static PID 1 for first-boot bring-up of the Cosmo mainline kernel.
 *
 * Purpose: prove the mainline kernel boots on real hardware and reaches
 * userspace. It writes an unmistakable banner to the console and /dev/kmsg,
 * mounts proc/sys/devtmpfs, then heartbeats forever so the serial log shows
 * sustained life. It is NOT a real init — swap for a distro initramfs later.
 *
 * Built statically with the aarch64 cross toolchain (see tools/mkboot.sh).
 */
#include <sys/mount.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

static void emit(const char *s)
{
	int n = (int)strlen(s);
	/* console (PID1 stdout) and the kernel log buffer */
	write(1, s, n);
	int k = open("/dev/kmsg", O_WRONLY);
	if (k >= 0) { write(k, s, n); close(k); }
}

int main(void)
{
	const char *banner =
		"\n\n"
		"========================================\n"
		"  PENNYOS: mainline kernel reached userspace\n"
		"  Planet Cosmo Communicator (MT6771)\n"
		"========================================\n\n";

	/* Make basic filesystems available (kernel has DEVTMPFS_MOUNT, but be explicit). */
	mount("proc",  "/proc", "proc",     0, 0);
	mount("sysfs", "/sys",  "sysfs",    0, 0);
	mount("devtmpfs", "/dev", "devtmpfs", 0, 0);

	emit(banner);

	unsigned long i = 0;
	for (;;) {
		char msg[64];
		int n = 0;
		const char *p = "pennyos: alive tick ";
		while (*p) msg[n++] = *p++;
		/* crude decimal of i */
		char num[20]; int m = 0; unsigned long v = i++;
		if (v == 0) num[m++] = '0';
		while (v) { num[m++] = '0' + (v % 10); v /= 10; }
		while (m) msg[n++] = num[--m];
		msg[n++] = '\n';
		write(1, msg, n);
		sleep(2);
	}
	return 0;
}
