#!/bin/bash
#
# series_s1bench.sh	Harness for running s1bench microbenchmark.
#
# This is a quick hack, written as a one-off for benchamrking Meltdown/Spectre
# overheads. It should be rewritten in a different language.
#
# This runs s1bench many times, stepping up the working set reads to lower
# the syscall rate. Each configuration is run $iters times, and the runs
# are printed in the "OUT:" line, sorted in order from fastest to slowest.
# Various measures are taken to lower variance: numactl is used to bind to
# a CPU and node, and the difference between the fastest and second fastest
# runs is compared, and more runs are executed until this satisfies $maxvarpct.
# Debug information is included in the output with different prefixes.
#
# DEPENDENCIES: Apart from the s1bench microbenchmark binary, the
# local directory tools listed under "debug tools" in the source should be
# present. They may use /proc, MSRs, and PMCs, and are from:
# - https://github.com/brendangregg/msr-cloud-tools
# - https://github.com/brendangregg/pmc-cloud-tools
#
# 04-Jan-2018	Brendan Gregg	Created this.

debugfile=/tmp/out.benchdebug.$$
rawfile=/tmp/out.benchtmp.$$

### benchmark config
wssize=$(( 100 * 1024 * 1024 ))
spintime_ms=300
runtime_ms=3000
stride=64
iters=20

### variance tunables
maxvarpct=0.20		# max variation percent; "" to disable
iterstep=5		# extra iters until maxvarpct satisfied
maxiters=100		# the give up point

### run configuration
readmax=2000000
start=256
preruns="0 1 8 16 32 64 128"

### build range of syscall counts to test
count=$start
sizes="$preruns "
while (( count < readmax )); do
	if (( count == 1 )); then
		sizes="0 "
	fi
	sizes="$sizes $count"
	(( count2 = count * 2 ))
	(( count1 = (count + count2) / 2 ))
	(( count1 != count )) && sizes="$sizes $count1"
	count=$count2
done

### choose a CPU and memory node to benchmark on: the last one
cpu=$(awk '$1 == "processor" { cpu = $3 } END { print cpu }' /proc/cpuinfo)
node=$(echo /sys/devices/system/cpu/cpu$cpu/node*)
node=${node##*node}
if [[ "$cpu" != [0-9]* || "$node" != [0-9]* ]]; then
	echo >&2 "ERROR: choosing a CPU and memory node (got $cpu, $node). Exiting."
	exit
fi

### debug tools
debugsecs=5
debug[0]="mpstat -P $cpu 1 $debugsecs"
debug[1]="./showboost -C$cpu 1 $debugsecs"
debug[2]="./pmcarch -C$cpu 1 $debugsecs"
debug[3]="./tlbstat -C$cpu 1 $debugsecs"
# these will get early SIGINTs

### header
echo "OUT: working-set-size working-set-reads working-set-stride runtime(ms) fastest_run_rate/s [next_fastest_run_rate/s ...]"

### main
for wsreads in $sizes; do
	# clear debug file
	> $debugfile
	debugidx=0

	spinrates=""
	poprates=""
	runrates=""
	i=0
	imax=$iters
	while :; do
		(( i++ ))
		# if present, launch one debug tool for each iter
		dpid=0
		if (( d < ${#debug[@]} )); then
			${debug[$debugidx]} >> $debugfile &
			dpid=$!
			(( debugidx++ ))
		fi

		# benchmark
		cmd="./s1bench $spintime_ms $wssize $wsreads $stride $runtime_ms"
		# let STDERR run free
		numactl --membind=$node --physcpubind=$cpu $cmd > $rawfile
		while read category num1 num2 num3; do
			[[ "$category" != "RATES:" ]] && continue
			spinrates="$spinrates $num1"
			poprates="$poprates $num2"
			runrates="$runrates $num3"
		done < $rawfile
		(( dpid )) && [ -d /proc/$dpid ] && kill -INT $dpid
		wait	# for debug tool if necessary

		# print raw output
		[ -e $rawfile ] && awk -v w=$wsreads -v i=$i '$1 !~ /INPUT/ { print "RAW:", w, i, $0 }' $rawfile

		# check if enough iterations have been done
		if (( i >= imax )); then
			# sort and calculate variance (uses sort(1) and awk(1))
			set -- $spinrates
			spinsorted=$(while [[ "$1" != "" ]]; do echo $1; shift; done | sort -rn)
			spinvar=$(echo $spinsorted | awk '{ first=$1; i=1; while (i++ < NF) { printf("%.2f ", 100 * (1 - $i / first)); } printf("\n"); }')
			set -- $poprates
			popsorted=$(while [[ "$1" != "" ]]; do echo $1; shift; done | sort -rn)
			popvar=$(echo $popsorted | awk '{ first=$1; i=1; while (i++ < NF) { printf("%.2f ", 100 * (1 - $i / first)); } printf("\n"); }')
			set -- $runrates
			runsorted=$(while [[ "$1" != "" ]]; do echo $1; shift; done | sort -rn)
			runvar=$(echo $runsorted | awk '{ first=$1; i=1; while (i++ < NF) { printf("%.2f ", 100 * (1 - $i / first)); } printf("\n"); }')

			# check if variance is satisfactory
			if [[ "$maxvarpct" != "" ]]; then
				set -- $runvar
				# borrowing awk for float comparisons
				var1=$1
				if awk -v var1=$var1 -v maxvarpct=$maxvarpct 'BEGIN { if (var1 < maxvarpct) { exit(0) } else { exit(1) } }'; then
					# within max variance
					break
				fi
				# not within max variance
				(( imax += iterstep ))
				if (( imax > maxiters )); then
					echo "MESSAGE: Too many attempts to lower variance, aborting."
					break
				fi
				echo "MESSAGE: Variance too high ($var1 > $maxvarpct). Continuing..."
			else
				break
			fi
		fi
	done

	# final output
	echo OUT: $wssize $wsreads $stride $runtime_ms $runsorted
	echo SPINRATES: $spinsorted
	echo SPINVAR%: $spinvar
	echo POPRATES: $popsorted
	echo POPVAR%: $popvar
	echo RUNRATES: $runsorted
	echo RUNVAR%: $runvar
	set -- $runvar
	echo RUNS: $(( i - 1 )) for $1

	[ -e $debugfile ] && awk -v w=$wsreads '{ print "DEBUG" NR ":", w, $0 }' $debugfile
done

### cleanup
[ -e $rawfile ] && rm $rawfile
[ -e $debugfile ] && rm $debugfile
