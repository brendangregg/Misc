/*
 * gettimeofdaybench
 *
 * USAGE: time gettimeofdaybench
 *
 * Compile with -O1.
 *
 * 30-Aug-2014	Brendan Gregg	Created this.
 */
#include <sys/time.h>

int
main(int argc, char *argv[])
{
	int i, ret;
	struct timeval tv;

	for (i = 0; i < 100 * 1000 * 1000; i++) {
		ret = gettimeofday(&tv, 0);
	}

	return (0);
}
