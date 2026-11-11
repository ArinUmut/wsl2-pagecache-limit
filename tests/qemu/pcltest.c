// SPDX-License-Identifier: GPL-2.0-only
/*
 * Small static helper for the QEMU tests: exercises the page cache through
 * different paths and reports the peak file / clean page cache it observed.
 *
 *   pcltest read      <file>              sequential read(2), 1 MiB
 *   pcltest mmap      <file>              MAP_SHARED, touch every page
 *   pcltest nowait    <file>              preadv2(RWF_NOWAIT), EAGAIN tolerated
 *   pcltest dontcache <file>              preadv2(RWF_DONTCACHE)
 *   pcltest sendfile  <src> <dst>         sendfile(2) file -> file
 *   pcltest write     <file> <MiB>        buffered write, no fsync
 *   pcltest mlock     <file> <seconds>    mmap + mlock the whole file, hold
 *
 * Output: "peak_file_kb=N peak_clean_kb=N secs=S bytes=B"
 * Clean = Active(file) + Inactive(file) - Dirty - Writeback (kB, /proc/meminfo).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#ifndef RWF_NOWAIT
#define RWF_NOWAIT 0x00000008
#endif
#ifndef RWF_DONTCACHE
#define RWF_DONTCACHE 0x00000080
#endif

#define CHUNK (1UL << 20)

static long peak_file, peak_clean;

static void sample(void)
{
	static char buf[8192];
	long af = 0, inf = 0, dirty = 0, wb = 0, file, clean, unw;
	int fd = open("/proc/meminfo", O_RDONLY);
	ssize_t n;
	char *p;

	if (fd < 0)
		return;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return;
	buf[n] = 0;
	if ((p = strstr(buf, "Active(file):")))
		af = atol(p + 13);
	if ((p = strstr(buf, "Inactive(file):")))
		inf = atol(p + 15);
	if ((p = strstr(buf, "\nDirty:")))
		dirty = atol(p + 7);
	if ((p = strstr(buf, "\nWriteback:")))
		wb = atol(p + 11);
	file = af + inf;
	unw = dirty + wb;
	clean = file - (unw < file ? unw : file);
	if (file > peak_file)
		peak_file = file;
	if (clean > peak_clean)
		peak_clean = clean;
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int open_or_die(const char *path, int flags)
{
	int fd = open(path, flags, 0644);

	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		exit(2);
	}
	return fd;
}

static off_t size_of(int fd)
{
	struct stat st;

	if (fstat(fd, &st)) {
		perror("fstat");
		exit(2);
	}
	return st.st_size;
}

static long do_pread(const char *path, int rwf)
{
	static char buf[CHUNK];
	int fd = open_or_die(path, O_RDONLY);
	long total = 0;
	off_t off = 0;

	for (;;) {
		struct iovec iov = { buf, CHUNK };
		ssize_t n = preadv2(fd, &iov, 1, off, rwf);

		if (n < 0 && errno == EAGAIN && (rwf & RWF_NOWAIT)) {
			/* not cached: fall back to a blocking read of this chunk */
			n = preadv2(fd, &iov, 1, off, 0);
		}
		if (n < 0) {
			perror("preadv2");
			exit(2);
		}
		if (n == 0)
			break;
		off += n;
		total += n;
		if ((total & ((8 * CHUNK) - 1)) == 0)
			sample();
	}
	close(fd);
	return total;
}

static long do_mmap(const char *path)
{
	int fd = open_or_die(path, O_RDONLY);
	off_t len = size_of(fd);
	volatile unsigned char *p;
	unsigned long sum = 0;
	off_t i;

	p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		exit(2);
	}
	for (i = 0; i < len; i += 4096) {
		sum += p[i];
		if ((i & ((8 * CHUNK) - 1)) == 0)
			sample();
	}
	munmap((void *)p, len);
	close(fd);
	return sum == 0xdeadbeef ? 0 : len;
}

static long do_write(const char *path, long mib)
{
	static char buf[CHUNK];
	int fd = open_or_die(path, O_WRONLY | O_CREAT | O_TRUNC);
	long i;

	memset(buf, 0x5a, sizeof(buf));
	for (i = 0; i < mib; i++) {
		if (write(fd, buf, CHUNK) != (ssize_t)CHUNK) {
			perror("write");
			exit(2);
		}
		if ((i & 7) == 0)
			sample();
	}
	close(fd);
	return mib * CHUNK;
}

static long do_sendfile(const char *src, const char *dst)
{
	int in = open_or_die(src, O_RDONLY);
	int out = open_or_die(dst, O_WRONLY | O_CREAT | O_TRUNC);
	long total = 0;
	ssize_t n;

	while ((n = sendfile(out, in, NULL, 8 * CHUNK)) > 0) {
		total += n;
		sample();
	}
	if (n < 0) {
		perror("sendfile");
		exit(2);
	}
	close(in);
	close(out);
	return total;
}

static long do_mlock(const char *path, int secs)
{
	int fd = open_or_die(path, O_RDONLY);
	off_t len = size_of(fd);
	void *p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, 0);

	if (p == MAP_FAILED || mlock(p, len)) {
		perror("mmap/mlock");
		exit(2);
	}
	printf("locked %ld bytes\n", (long)len);
	fflush(stdout);
	sleep(secs);
	munlock(p, len);
	munmap(p, len);
	close(fd);
	return len;
}

int main(int argc, char **argv)
{
	double t0;
	long bytes;

	if (argc < 3) {
		fprintf(stderr, "usage: see source\n");
		return 2;
	}
	sample();
	t0 = now();
	if (!strcmp(argv[1], "read"))
		bytes = do_pread(argv[2], 0);
	else if (!strcmp(argv[1], "nowait"))
		bytes = do_pread(argv[2], RWF_NOWAIT);
	else if (!strcmp(argv[1], "dontcache"))
		bytes = do_pread(argv[2], RWF_DONTCACHE);
	else if (!strcmp(argv[1], "mmap"))
		bytes = do_mmap(argv[2]);
	else if (!strcmp(argv[1], "write") && argc > 3)
		bytes = do_write(argv[2], atol(argv[3]));
	else if (!strcmp(argv[1], "sendfile") && argc > 3)
		bytes = do_sendfile(argv[2], argv[3]);
	else if (!strcmp(argv[1], "mlock") && argc > 3)
		bytes = do_mlock(argv[2], atoi(argv[3]));
	else {
		fprintf(stderr, "bad arguments\n");
		return 2;
	}
	sample();
	printf("peak_file_kb=%ld peak_clean_kb=%ld secs=%.4f bytes=%ld\n",
	       peak_file, peak_clean, now() - t0, bytes);
	return 0;
}
