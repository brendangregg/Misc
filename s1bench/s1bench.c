/*
 * s1bench - syscall benchmark 1. Tests a syscall & think loop.
 *
 * This benchmark has three stages:
 *
 * 1. spin loop
 *			This is a simple control, for checking CPU variance
 *			between runs and systems. If there's too much variance
 *			here, don't bother with	the tests that follow.
 * 2. memory population
 *			Strides by getpagesize(), creating a region for the
 *			following test.
 * 3. syscall & think
 * 			Does a fast syscall (close(999), which fails) followed
 *			by some time "thinking": reading over the memory region
 *			for a specified	number of reads, and by a specified
 *			stride size.
 *
 * gcc -O0 -pthread -o s1bench s1bench.c
 *
 * USAGE: see -h for usage.
 *
 * 03-Jan-2017	Brendan Gregg	Created this.
 */

#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <signal.h>

void usage()
{
	printf("USAGE: s1bench spintime(ms) allocsize(B) reads_per_syscalls read_stridesize(B) runtime(ms)\n"
	    "       spintime(ms)        spin test time as a control\n"
	    "       allocsize(B)        memory size to allocate and populate (bytes)\n"
	    "       reads_per_syscall   number of memory reads per syscall\n"
	    "       stridesize(B)       size to step after each memory read (bytes)\n"
	    "       runtime(ms)         duration of workload run\n"
	    "   eg,\n"
	    "       s1bench 300 $(( 100 * 1024 * 1024 )) 2000 64 5000\n"
	    "           # example run: 100 MB, 2000 reads per syscall, 64 byte stride, 5 sec run\n"
	    "       s1bench 300 0 0 0 0 0      # spin test only (control only)\n"
	    "       s1bench 0 0 0 0 500        # syscalls only, no think\n"
	    "       s1bench 0 1024 100 64 500  # syscalls, plus some think\n\n"
	    "Output is space-delimited values, one line per category:\n"
	    "       INPUT: (input parameters)\n"
	    "       SPIN: spin_count spin_time(s) spin_usr_time(s) spin_sys_time(s) involuntary_csw\n"
	    "       POP: pop_count pop_time(s) pop_usr_time(s) pop_sys_time(s) minor_faults\n"
	    "       RUN: run_count run_time(s) run_usr_time(s) run_sys_time(s) involuntary_csw\n"
	    "       RATES: spin_count/s pop_count/s run_count/s\n\n"
	    "The syscalls called is roughly equal to run_count (plus program init).\n");
}

/*
 * These functions aren't just for code clenlyness: they show up in profilers
 * when doing active benchmarking to debug the benchmark.
 */

int g_spin = 1;
void spinstop(int dummy) {
	g_spin = 0;
}

void *spinloop(void *arg)
{
	signal(SIGUSR1, spinstop);
	unsigned long long *count = (unsigned long long *)arg;
	for (;g_spin;) { (*count)++; }
}

void spintest(unsigned long long spin_wait_us, unsigned long long *count)
{
	pthread_t thread;

	if (!spin_wait_us)
		return;

	if (pthread_create(&thread, NULL, spinloop, count) != 0) {
		perror("Thread create failed");
		exit(1);
	}
	usleep(spin_wait_us);
	if (pthread_kill(thread, SIGUSR1)) {
		perror("Couldn't terminate worker thread normally");
		exit(1);
	}
	pthread_join(thread, NULL);
}

int g_work = 1;
void workstop(int dummy) {
	g_work = 0;
}

struct workload_args {
	char *mem;
	unsigned long long memsize;
	unsigned long long readmax;
	int stride;
	unsigned long long *count;
};

void *workloop(void *arg)
{
	struct workload_args *a = (struct workload_args *)arg;
	char *memp;
	unsigned long long i, j;
	int junk;
	char *mem = a->mem;
	unsigned long long memsize = a->memsize;
	unsigned long long readmax = a->readmax;
	int stride = a->stride;
	unsigned long long *count = a->count;

	signal(SIGUSR1, workstop);
	memp = mem;
	for (;g_work;) {
		close(999);	// the syscall (it errors, but so what)
		(*count)++;
		// can do a "memp = mem;" here to reset on each loop
		for (j = 0; j < readmax; j++) {
			junk += memp[0];
			memp += stride;
			if (memp > (mem + memsize))
				memp = mem;
		}
	}
}

void workload(char *mem, unsigned long long memsize,
    unsigned long long readmax, int stride, unsigned long long *count,
    unsigned long long run_wait_us)
{
	struct workload_args args = {.mem = mem, .memsize = memsize,
	    .readmax = readmax, .stride = stride, .count = count};
	pthread_t thread;

	if (!run_wait_us)
		return;

	if (pthread_create(&thread, NULL, workloop, &args) != 0) {
		perror("Thread create failed");
		exit(1);
	}
	usleep(run_wait_us);
	if (pthread_kill(thread, SIGUSR1)) {
		perror("Couldn't terminate worker thread normally");
		exit(0);
	}
	pthread_join(thread, NULL);
}

int main(int argc, char *argv[])
{
	char *mem, *memp;
	int stride;
	unsigned long long memsize, readmax, pagesize,
	    spin_wait_us, run_wait_us;
	unsigned long long spin_count, spin_us, spin_usr_us, spin_sys_us,
	    spin_ivcs, pop_count, pop_us, pop_usr_us, pop_sys_us, pop_minflt,
	    run_count, run_us, run_usr_us, run_sys_us, run_ivcs;
	static struct timeval ts[6];
	struct rusage u[6];

	// options
	if (argc < 6) {
		usage();
		exit(0);
	}
	spin_wait_us = atoll(argv[1]) * 1000;
	memsize = atoll(argv[2]);
	readmax = atoll(argv[3]);
	stride = atoll(argv[4]);
	run_wait_us = atoll(argv[5]) * 1000;

	// init
	pagesize = getpagesize();
	spin_count = 0;
	pop_count = 0;
	run_count = 0;
	if ((mem = malloc(memsize)) == NULL) {
		printf("ERROR allocating working set memory. Exiting.\n");
		return 1;
	}

	/*
	 * spin time, with timeout
	 */
	getrusage(RUSAGE_SELF, &u[0]);
	gettimeofday(&ts[0], NULL);
	spintest(spin_wait_us, &spin_count);
	gettimeofday(&ts[1], NULL);
	getrusage(RUSAGE_SELF, &u[1]);

	/*
	 * populate working set
	 */
	getrusage(RUSAGE_SELF, &u[2]);
	gettimeofday(&ts[2], NULL);
	for (memp = mem; memp < (mem + memsize); memp += pagesize) {
		memp[0] = 'A';
		pop_count++;
	}
	gettimeofday(&ts[3], NULL);
	getrusage(RUSAGE_SELF, &u[3]);

	/*
	 * workload, with timeout
	 */
	getrusage(RUSAGE_SELF, &u[4]);
	gettimeofday(&ts[4], NULL);
	workload(mem, memsize, readmax, stride, &run_count, run_wait_us);
	gettimeofday(&ts[5], NULL);
	getrusage(RUSAGE_SELF, &u[5]);

	/*
	 * calculate and print times
	 */
	spin_us = 1000000 * (ts[1].tv_sec - ts[0].tv_sec) + (ts[1].tv_usec - ts[0].tv_usec) / 1;
	spin_usr_us = 1000000 * (u[1].ru_utime.tv_sec - u[0].ru_utime.tv_sec) + (u[1].ru_utime.tv_usec - u[0].ru_utime.tv_usec) / 1;
	spin_sys_us = 1000000 * (u[1].ru_stime.tv_sec - u[0].ru_stime.tv_sec) + (u[1].ru_stime.tv_usec - u[0].ru_stime.tv_usec) / 1;
	spin_ivcs = u[1].ru_nivcsw - u[0].ru_nivcsw;
	pop_us = 1000000 * (ts[3].tv_sec - ts[2].tv_sec) + (ts[3].tv_usec - ts[2].tv_usec) / 1;
	pop_usr_us = 1000000 * (u[3].ru_utime.tv_sec - u[2].ru_utime.tv_sec) + (u[3].ru_utime.tv_usec - u[2].ru_utime.tv_usec) / 1;
	pop_sys_us = 1000000 * (u[3].ru_stime.tv_sec - u[2].ru_stime.tv_sec) + (u[3].ru_stime.tv_usec - u[2].ru_stime.tv_usec) / 1;
	pop_minflt = u[3].ru_minflt - u[2].ru_minflt;
	run_us = 1000000 * (ts[5].tv_sec - ts[4].tv_sec) + (ts[5].tv_usec - ts[4].tv_usec) / 1;
	run_usr_us = 1000000 * (u[5].ru_utime.tv_sec - u[4].ru_utime.tv_sec) + (u[5].ru_utime.tv_usec - u[4].ru_utime.tv_usec) / 1;
	run_sys_us = 1000000 * (u[5].ru_stime.tv_sec - u[4].ru_stime.tv_sec) + (u[5].ru_stime.tv_usec - u[4].ru_stime.tv_usec) / 1;
	run_ivcs = u[5].ru_nivcsw - u[4].ru_nivcsw;
	printf("INPUT: %llu %llu %llu %d %llu\n", spin_wait_us / 1000, memsize, readmax, stride, run_wait_us / 1000);
	printf("SPIN: %llu %.3f %.3f %.3f %llu\n", spin_count, (double)spin_us / 1000000, (double)spin_usr_us / 1000000, (double)spin_sys_us / 1000000, spin_ivcs);
	printf("POP: %llu %.3f %.3f %.3f %llu\n", pop_count, (double)pop_us / 1000000, (double)pop_usr_us / 1000000, (double)pop_sys_us / 1000000, pop_minflt);
	printf("RUN: %llu %.3f %.3f %.3f %llu\n", run_count, (double)run_us / 1000000, (double)run_usr_us / 1000000, (double)run_sys_us / 1000000, run_ivcs);
	printf("RATES: %llu %llu %.1f\n", spin_us ? spin_count * 1000000 / spin_us : 0,
	    pop_us ? pop_count * 1000000 / pop_us : 0,
	    run_us ? (double)run_count * 1000000 / run_us : 0);

	return (0);
}
