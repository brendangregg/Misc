/*
 * skidtest
 *
 * COMPILE: gcc -O0 -o skidtest skidtest.c
 *
 * USAGE: ./skidtest size_kb
 *    eg,
 *        perf record -e r412e -c 1000 ./skidtest 1000000	# sample every 1000 LLC-miss
 *
 * Choose a size greater than the LLC cache to induce misses.
 *
 * hits vs skids:
 * perf script --header -F comm,pid,tid,time,event,ip,sym,symoff,dso |\
 *    awk '/noprunway/ { skid++ } /memreader/ { hit++ } END { printf "hits %d, skid %d\n", hit, skid }'
 *
 * skid offset list:
 * perf script --header -F comm,pid,tid,time,event,ip,sym,symoff,dso |\
 *     awk '/noprunway/ { sub(/noprunway\+/, "", $6); print $6 }' | perl -ne 'print hex($_) . "\n"' | sort -n
 * This can also be input into skid.r for plotting.
 *
 * skid offset histogram (as text):
 * perf script --header -F comm,pid,tid,time,event,ip,sym,symoff,dso |\
 *     awk '/noprunway/ { sub(/noprunway\+/, "", $6); print $6 }' | perl -e 'while (<>) { $idx = int(hex($_)/10); @a[$idx]++; $m = $idx if $idx > $m; } for ($i = 0; $i < $m; $i++) { $a[$i] += 0; print $i * 10 . " " . $a[$i] . "\n"; }'
 *
 * Newer kernel's "perf script" default output is sufficient (has symoff by default).
 *
 * 23-Mar-2017	Brendan Gregg	Created this.
 */
 
#include <stdio.h>
#include <stdlib.h>

void
memreader(char *p, unsigned long long j) {
	char c;
	c = p[j];
}

#define NOP10	"nop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\n"
#define NOP100	NOP10 NOP10 NOP10 NOP10 NOP10 NOP10 NOP10 NOP10 NOP10 NOP10
#define NOP1000	NOP100 NOP100 NOP100 NOP100 NOP100 NOP100 NOP100 NOP100 NOP100 NOP100

void
noprunway() {
	/*
	 * A nop runway that is 5000 nops long.
	 * The aim is to span 1000 cycles on a 5-wide.
	 * Reduce to keep within one page if desired.
	 */
	asm(
		NOP1000
		NOP1000
		NOP1000
		NOP1000
		NOP1000
	);
}

int
main(int argc, char *argv[])
{
	unsigned long long size, j;
	char *p, c;

	if (argc != 2) {
		printf("USAGE: memstride size_KB\n");
		exit(1);
	}	

	size = atoi(argv[1]) * 1024ULL;

	if ((p = malloc(size)) == NULL) {
		printf("ERROR: malloc failed\n");
		exit(1);
	}

	printf("Populate...\n");
	for (j = 0; j < size; j += 32) {
		p[j] = 'a';
	}

	printf("Stride...\n");
	for (;;) {
		// 1 Kbyte stride, to walk past pages quickly
		for (j = 0ULL; j < size; j += 1024) {
			memreader(p, j);
			noprunway();
		}
	}

	return (0);
}
