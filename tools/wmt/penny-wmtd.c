// SPDX-License-Identifier: GPL-2.0
/*
 * penny-wmtd - minimal replacement for Android's wmt_loader + wmt_launcher on the
 * Planet Cosmo (MT6771 built-in consys, MT6631 RF), for the PennyOS port of the
 * vendor WMT driver.
 *
 *  1. /dev/wmtdetect: tell the driver which SoC consys it is and start WMT
 *  2. /dev/stpwmt:    select STP-over-BTIF, then serve the driver's requests:
 *       "srh_patch"  -> find the ROM patch files that match the chip's firmware
 *                       version and hand their names/addresses to the driver
 *       "open_stp" / "close_stp" / "rst_stp" -> nothing to do for BTIF
 *
 * Protocol taken from the vendor kernel driver and the open-source launcher
 * shipped with the Banana Pi R2 kernels (utils/wmt/src/stp_uart_launcher.c).
 * Patch files are requested by the kernel via request_firmware(), so they must
 * sit in the firmware search path and are passed by bare file name.
 *
 * Usage: penny-wmtd [-p /lib/firmware] [-n ROMv4_be_patch] [-1]   (-1: init only)
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define DETECT_DEV "/dev/wmtdetect"
#define WMT_DEV    "/dev/stpwmt"

#define COMBO_IOCTL_SET_CHIP_ID      _IOW('w', 1, int)
#define COMBO_IOCTL_GET_SOC_CHIP_ID  _IOR('w', 3, int)
#define COMBO_IOCTL_DO_MODULE_INIT   _IOR('w', 4, int)

#define WMT_IOC_MAGIC 0xa0
#define WMT_IOCTL_SET_STP_MODE   _IOW(WMT_IOC_MAGIC, 5, int)
#define WMT_IOCTL_GET_CHIP_INFO  _IOR(WMT_IOC_MAGIC, 12, int)
#define WMT_IOCTL_SET_PATCH_NUM  _IOW(WMT_IOC_MAGIC, 14, int)
#define WMT_IOCTL_SET_PATCH_INFO _IOW(WMT_IOC_MAGIC, 15, char *)

#define STP_BTIF_FULL 0x3
#define FM_MODE_COMM  0x2

struct wmt_patch_info {
	int dowloadSeq;
	char addRess[4];
	char patchName[256];
};

static const char *fw_dir = "/lib/firmware";
static const char *patch_prefix = "ROMv4_be_patch";

static int do_loader(void)
{
	int fd = open(DETECT_DEV, O_RDWR), chip, ret;

	if (fd < 0) {
		perror(DETECT_DEV);
		return -1;
	}
	chip = ioctl(fd, COMBO_IOCTL_GET_SOC_CHIP_ID, NULL);
	printf("penny-wmtd: SoC consys chip id 0x%x\n", chip);
	ret = ioctl(fd, COMBO_IOCTL_SET_CHIP_ID, chip);
	printf("penny-wmtd: set chip id -> %d\n", ret);
	ret = ioctl(fd, COMBO_IOCTL_DO_MODULE_INIT, chip);
	printf("penny-wmtd: module init -> %d\n", ret);
	close(fd);
	return ret;
}

/* Byte 22/23 of a patch = firmware version it is for; byte 24 = count<<4 | seq,
 * bytes 25..27 = download address (byte 24's slot is sent as 0). */
static int search_patch(int wmt)
{
	int fwver = ioctl(wmt, WMT_IOCTL_GET_CHIP_INFO, 2);
	struct dirent *de;
	DIR *dir = opendir(fw_dir);
	int found = 0;

	printf("penny-wmtd: chip id 0x%x hw 0x%x fw 0x%x\n",
	       ioctl(wmt, WMT_IOCTL_GET_CHIP_INFO, 0),
	       ioctl(wmt, WMT_IOCTL_GET_CHIP_INFO, 1), fwver);
	if (!dir) {
		perror(fw_dir);
		return -1;
	}
	while ((de = readdir(dir))) {
		unsigned char hdr[28];
		struct wmt_patch_info pi;
		char path[512];
		int fd, patchver;

		if (strncmp(de->d_name, patch_prefix, strlen(patch_prefix)))
			continue;
		snprintf(path, sizeof(path), "%s/%s", fw_dir, de->d_name);
		fd = open(path, O_RDONLY);
		if (fd < 0)
			continue;
		if (read(fd, hdr, sizeof(hdr)) != sizeof(hdr)) {
			close(fd);
			continue;
		}
		close(fd);
		patchver = hdr[22] << 8 | hdr[23];
		printf("penny-wmtd: %s: for fw 0x%04x, info %02x %02x %02x %02x\n",
		       de->d_name, patchver, hdr[24], hdr[25], hdr[26], hdr[27]);
		if ((patchver ^ fwver) & 0x00ff)
			continue;
		if (!found)
			ioctl(wmt, WMT_IOCTL_SET_PATCH_NUM, (hdr[24] & 0xf0) >> 4);
		memset(&pi, 0, sizeof(pi));
		pi.dowloadSeq = hdr[24] & 0x0f;
		memcpy(pi.addRess, &hdr[24], 4);
		pi.addRess[0] = 0;
		snprintf(pi.patchName, sizeof(pi.patchName), "%s", de->d_name);
		if (ioctl(wmt, WMT_IOCTL_SET_PATCH_INFO, &pi) < 0)
			perror("WMT_IOCTL_SET_PATCH_INFO");
		found++;
	}
	closedir(dir);
	printf("penny-wmtd: %d matching patch file(s)\n", found);
	return found ? 0 : -1;
}

int main(int argc, char **argv)
{
	int opt, init_only = 0, wmt, i;

	setvbuf(stdout, NULL, _IOLBF, 0);
	while ((opt = getopt(argc, argv, "p:n:1")) != -1) {
		if (opt == 'p')
			fw_dir = optarg;
		else if (opt == 'n')
			patch_prefix = optarg;
		else if (opt == '1')
			init_only = 1;
	}

	if (access(WMT_DEV, F_OK) != 0)
		do_loader();
	for (i = 0; i < 50 && access(WMT_DEV, F_OK) != 0; i++)
		usleep(100000);
	wmt = open(WMT_DEV, O_RDWR | O_NOCTTY);
	if (wmt < 0) {
		perror(WMT_DEV);
		return 1;
	}
	if (ioctl(wmt, WMT_IOCTL_SET_STP_MODE, (FM_MODE_COMM << 4) | STP_BTIF_FULL) < 0)
		perror("WMT_IOCTL_SET_STP_MODE");
	printf("penny-wmtd: STP over BTIF selected, serving %s\n", WMT_DEV);
	if (init_only)
		return 0;

	for (;;) {
		struct pollfd pfd = { .fd = wmt, .events = POLLIN | POLLRDNORM };
		char cmd[256];
		const char *resp = "ok";
		int len;

		if (poll(&pfd, 1, -1) < 0) {
			if (errno == EINTR)
				continue;
			perror("poll");
			return 1;
		}
		len = read(wmt, cmd, sizeof(cmd) - 1);
		if (len <= 0)
			continue;
		cmd[len] = 0;
		printf("penny-wmtd: driver asks: \"%s\"\n", cmd);
		if (!strcmp(cmd, "srh_patch")) {
			if (search_patch(wmt))
				resp = "fail";
		} else if (strcmp(cmd, "open_stp") && strcmp(cmd, "close_stp") &&
			   strcmp(cmd, "rst_stp")) {
			printf("penny-wmtd: unknown request, answering ok\n");
		}
		if (write(wmt, resp, strlen(resp)) < 0)
			perror("write");
	}
}
