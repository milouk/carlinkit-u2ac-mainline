// SPDX-License-Identifier: GPL-3.0-or-later
// fakephone [PORT]: the phone (MD) end for aa-proxy-rs's direct-TCP mode (aa_server_tcp_addr), on the dongle.
// Answers the head unit's VERSION_REQUEST with a VERSION_RESPONSE (1.7, status 0) and echoes every other frame
// back unchanged, so carsim/mockhu.py (the car) can check every byte that went car -> dongle -> phone -> car.
// Frame: [channel][flags][len_hi][len_lo] (+ 4-byte total length when flags has FIRST without LAST), payload.
// Build: zig cc -target arm-linux-musleabihf -static -Os -o fakephone fakephone.c
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int rd(int fd, unsigned char *b, size_t n)
{
	size_t g = 0;
	while (g < n) {
		ssize_t r = read(fd, b + g, n - g);
		if (r <= 0)
			return -1;
		g += (size_t)r;
	}
	return 0;
}

static int wr(int fd, const unsigned char *b, size_t n)
{
	size_t g = 0;
	while (g < n) {
		ssize_t r = write(fd, b + g, n - g);
		if (r <= 0)
			return -1;
		g += (size_t)r;
	}
	return 0;
}

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	int port = argc > 1 ? atoi(argv[1]) : 5299, one = 1;
	int s = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) };
	static unsigned char buf[70000];
	unsigned char h[8];

	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 4)) {
		perror("fakephone: bind/listen");
		return 1;
	}
	setvbuf(stderr, NULL, _IONBF, 0);
	fprintf(stderr, "fakephone: listening on 127.0.0.1:%d\n", port);
	for (;;) {
		int c = accept(s, NULL, NULL);
		unsigned long frames = 0, bytes = 0;
		double t0 = now();

		if (c < 0)
			continue;
		setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
		fprintf(stderr, "fakephone: aa-proxy-rs connected\n");
		for (;;) {
			int ch, fl, len, hl = 4;

			if (rd(c, h, 4))
				break;
			ch = h[0];
			fl = h[1];
			len = (h[2] << 8) | h[3];
			if ((fl & 3) == 1) {
				if (rd(c, h + 4, 4))
					break;
				hl = 8;
			}
			if (rd(c, buf, (size_t)len))
				break;
			frames++;
			bytes += (unsigned long)len;
			if (ch == 0 && !(fl & 8) && len >= 6 && buf[0] == 0 && buf[1] == 1) {
				static const unsigned char r[] = { 0, 3, 0, 8, 0, 2, 0, 1, 0, 7, 0, 0 };
				fprintf(stderr, "fakephone: [%.2f s] VERSION_REQUEST %d.%d -> VERSION_RESPONSE 1.7\n",
					now() - t0, (buf[2] << 8) | buf[3], (buf[4] << 8) | buf[5]);
				if (wr(c, r, sizeof r))
					break;
				continue;
			}
			if (wr(c, h, (size_t)hl) || wr(c, buf, (size_t)len))
				break;
		}
		fprintf(stderr, "fakephone: [%.2f s] closed after %lu frames, %lu payload bytes\n", now() - t0, frames,
			bytes);
		close(c);
	}
}
