// SPDX-License-Identifier: GPL-2.0
/*
 * penny-btd: give BlueZ an HCI device for the Cosmo's built-in Bluetooth.
 *
 * MediaTek's driver exposes the controller as /dev/stpbt, a byte stream of H4
 * packets meant for Android's Bluetooth stack. Linux wants an HCI device. This
 * daemon opens /dev/stpbt (which powers the chip's Bluetooth function on and
 * loads its patch), creates a virtual HCI controller through /dev/vhci, and
 * copies packets between the two.
 *
 *   BlueZ <-> hciN (hci_vhci) <-> /dev/vhci <-> penny-btd <-> /dev/stpbt <-> chip
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define H4_CMD   0x01
#define H4_ACL   0x02
#define H4_SCO   0x03
#define H4_EVT   0x04
#define H4_ISO   0x05
#define H4_VENDOR 0xff	/* hci_vhci control packets */

#define BUFSZ 4096

static volatile sig_atomic_t stop;
static void on_signal(int s) { (void)s; stop = 1; }

/* Length of the H4 packet at the start of buf, 0 if more bytes are needed, -1 if bad. */
static int h4_len(const uint8_t *b, size_t n)
{
	if (n < 1)
		return 0;
	switch (b[0]) {
	case H4_EVT:
		return n < 3 ? 0 : 3 + b[2];
	case H4_ACL:
	case H4_ISO:
		return n < 5 ? 0 : 5 + (b[3] | b[4] << 8);
	case H4_SCO:
		return n < 4 ? 0 : 4 + b[3];
	default:
		return -1;
	}
}

static int write_all(int fd, const uint8_t *b, size_t n, const char *what)
{
	for (int tries = 0; tries < 50; tries++) {
		ssize_t w = write(fd, b, n);

		if (w == (ssize_t)n)
			return 0;
		if (w < 0 && (errno == EAGAIN || errno == EINTR)) {
			usleep(2000);
			continue;
		}
		fprintf(stderr, "penny-btd: write to %s: %s (%zd of %zu)\n", what,
			w < 0 ? strerror(errno) : "short write", w, n);
		return -1;
	}
	fprintf(stderr, "penny-btd: write to %s kept returning EAGAIN\n", what);
	return -1;
}

/*
 * What Android's libbluetooth_mtk sends after opening /dev/stpbt on this chip
 * family (script bt_init_preload_script_consys, read from its disassembly): BD
 * address, radio, TX power offset and sleep settings from the 110-byte NVRAM
 * record, then an HCI reset. Each command waits for its Command Complete.
 */
#define NVRAM_PATH "/opt/pennyos/conn/nvram/BT_Addr"

static int send_cmd(int bt, uint16_t opcode, const uint8_t *par, uint8_t plen)
{
	uint8_t pkt[4 + 255], buf[BUFSZ];
	size_t have = 0;

	pkt[0] = H4_CMD;
	pkt[1] = opcode & 0xff;
	pkt[2] = opcode >> 8;
	pkt[3] = plen;
	if (plen)
		memcpy(pkt + 4, par, plen);
	if (write_all(bt, pkt, 4 + plen, "stpbt"))
		return -1;

	for (int waited = 0; waited < 2000; ) {
		struct pollfd p = { bt, POLLIN, 0 };
		int len;

		if (poll(&p, 1, 100) <= 0) {
			waited += 100;
			continue;
		}
		ssize_t n = read(bt, buf + have, 2048);
		if (n > 0)
			have += n;
		while ((len = h4_len(buf, have)) > 0 && (size_t)len <= have) {
			/* 04 0e len ncmd op_lo op_hi status */
			if (buf[0] == H4_EVT && buf[1] == 0x0e && len >= 7 &&
			    buf[4] == pkt[1] && buf[5] == pkt[2]) {
				if (buf[6])
					fprintf(stderr, "penny-btd: command 0x%04x: status 0x%02x\n",
						opcode, buf[6]);
				return buf[6] ? -1 : 0;
			}
			memmove(buf, buf + len, have - len);
			have -= len;
		}
		if (len < 0)
			have = 0;
	}
	fprintf(stderr, "penny-btd: command 0x%04x: no answer\n", opcode);
	return -1;
}

static int vendor_init(int bt)
{
	/* the library's built-in defaults for this chip family */
	uint8_t nv[110] = {
		[12] = 0x07, 0x80, 0x00, 0x06, 0x07, 0x07,		/* radio */
		[18] = 0x03, 0x40, 0x1f, 0x40, 0x1f, 0x00, 0x04,	/* sleep */
		[27] = 0xff, 0xff, 0xff,				/* TX power offset */
	};
	uint8_t addr[6];
	int have_addr = 0, ret = 0;
	int fd = open(NVRAM_PATH, O_RDONLY);

	if (fd >= 0) {
		uint8_t file[110];

		if (read(fd, file, sizeof(file)) == sizeof(file)) {
			memcpy(nv, file, sizeof(nv));
			have_addr = memcmp(nv, "\0\0\0\0\0\0", 6) != 0;
		}
		close(fd);
	}
	if (have_addr) {
		for (int i = 0; i < 6; i++)
			addr[i] = nv[5 - i];
		ret |= send_cmd(bt, 0xfc1a, addr, 6);
	} else {
		fprintf(stderr, "penny-btd: no " NVRAM_PATH ", keeping the chip's default address\n");
	}
	ret |= send_cmd(bt, 0xfc79, nv + 12, 6);
	ret |= send_cmd(bt, 0xfc93, nv + 27, 3);
	ret |= send_cmd(bt, 0xfc7a, nv + 18, 7);
	ret |= send_cmd(bt, 0x0c03, NULL, 0);
	return ret;
}

int main(void)
{
	static uint8_t chip[BUFSZ], host[BUFSZ];
	size_t have = 0;
	struct sigaction sa = { .sa_handler = on_signal };
	int bt, vhci;

	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	setvbuf(stderr, NULL, _IOLBF, 0);

	/* blocks while the driver powers the function on and downloads the patch */
	bt = open("/dev/stpbt", O_RDWR | O_NOCTTY);
	if (bt < 0) {
		perror("penny-btd: /dev/stpbt");
		return 1;
	}
	fprintf(stderr, "penny-btd: Bluetooth function is on\n");
	fcntl(bt, F_SETFL, fcntl(bt, F_GETFL) | O_NONBLOCK);
	if (vendor_init(bt))
		fprintf(stderr, "penny-btd: vendor set-up incomplete, carrying on\n");
	else
		fprintf(stderr, "penny-btd: vendor set-up done\n");

	vhci = open("/dev/vhci", O_RDWR);
	if (vhci < 0) {
		perror("penny-btd: /dev/vhci (is hci_vhci loaded?)");
		return 1;
	}
	{	/* create a primary controller */
		static const uint8_t create[2] = { H4_VENDOR, 0x00 };

		if (write_all(vhci, create, sizeof(create), "vhci"))
			return 1;
	}

	while (!stop) {
		struct pollfd p[2] = { { bt, POLLIN, 0 }, { vhci, POLLIN, 0 } };

		if (poll(p, 2, -1) < 0) {
			if (errno == EINTR)
				continue;
			perror("penny-btd: poll");
			break;
		}

		if (p[1].revents & POLLIN) {	/* host -> chip: one packet per read */
			ssize_t n = read(vhci, host, sizeof(host));

			if (n < 0 && errno != EAGAIN && errno != EINTR) {
				perror("penny-btd: read vhci");
				break;
			}
			if (n > 0 && host[0] == H4_VENDOR) {
				if (n >= 4)
					fprintf(stderr, "penny-btd: created hci%d\n",
						host[2] | host[3] << 8);
			} else if (n > 0 && write_all(bt, host, n, "stpbt")) {
				break;
			}
		}

		if (p[0].revents & POLLIN) {	/* chip -> host: a stream, cut into packets */
			size_t room = sizeof(chip) - have;
			/* the driver's buffer is 2048 bytes and it complains about larger reads */
			ssize_t n = read(bt, chip + have, room > 2048 ? 2048 : room);

			if (n < 0 && errno != EAGAIN && errno != EINTR) {
				perror("penny-btd: read stpbt");
				break;
			}
			if (n > 0)
				have += n;
			for (;;) {
				int len = h4_len(chip, have);

				if (len < 0) {
					fprintf(stderr, "penny-btd: unexpected byte 0x%02x from the chip, dropping %zu bytes\n",
						chip[0], have);
					have = 0;
					break;
				}
				if (len == 0 || (size_t)len > have)
					break;
				if (write_all(vhci, chip, len, "vhci"))
					goto out;
				memmove(chip, chip + len, have - len);
				have -= len;
			}
			if (have == sizeof(chip)) {
				fprintf(stderr, "penny-btd: packet larger than the buffer, dropping\n");
				have = 0;
			}
		}
		if ((p[0].revents | p[1].revents) & (POLLERR | POLLHUP | POLLNVAL)) {
			fprintf(stderr, "penny-btd: device went away\n");
			break;
		}
	}
out:
	close(vhci);
	close(bt);
	return stop ? 0 : 1;
}
