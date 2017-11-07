#!/bin/bash
#
# microbench_ubuntu.sh		Initialize and run instance micro-benchmarks.
#
# 31-Mar-2014	Brendan Gregg	Created this.
# 23-Oct-2017	   "      "	Added several more micro-benchmarks.

DATADIR=/mnt/microbench
LOGFILE=$PWD/out.microbench.$$

### run: name command [arguments ...]
function run {
	( echo ----------------------------------------
	echo BENCHMARK: $1
	echo ---------------------------------------- ) | tee -a $LOGFILE
	shift
	( echo RUN: "$@"
	echo
	sudo time "$@" 2>&1
	echo
	echo EXIT STATUS: $? ) | tee -a $LOGFILE
}

function die {
	echo >&2 "$@"
	exit 1
}

function addpkgs {
	all=1
	for pkg in "$@"; do
		if ! dpkg -s $pkg > /dev/null; then all=0; fi
	done
	if (( all )); then
		echo "All packages already installed."
	else
		sudo apt-get update
		for pkg in "$@"; do
			sudo apt-get install -y $pkg
		done
	fi
}

### determine instance paramaters
memory=$(awk '$1 == "MemTotal:" { printf "%d\n", $2 / 1024 }' /proc/meminfo)
ncpu=$(grep -c '^processor	' /proc/cpuinfo)
mntdev=$(awk '$2 == "/mnt" { print $1; exit }' /etc/fstab)

### print and log hardware
echo Logfile: $LOGFILE
> $LOGFILE
( echo Main Memory: $memory Mbytes
echo CPUs: $ncpu
echo CPU:
awk '{ print } NF == 0 { exit }' /proc/cpuinfo
echo NUMASTAT:
numastat
echo /mnt DEV: $mntdev
) | tee -a $LOGFILE
sleep 0.5
echo

### log extra details
( echo DATE: $(date)
echo UNAME: $(uname -a)
echo ENV:
env ) | tee -a $LOGFILE

### log Netflix details if available
customenv=/etc/profile.d/netflix_environment.sh
[ -e $customenv ] && cat $customenv | tee -a $LOGFILE

### add software
echo Adding packages...
addpkgs numactl lmbench sysbench fio hdparm iperf sharutils openssl p7zip-full

sudo mkdir -p $DATADIR
[[ "$USER" == "" ]] && die "ERROR: Username not found (\$USER?)"
sudo chown $USER $DATADIR
echo cd $DATADIR
cd $DATADIR
[ -e fio.data ] && sudo rm fio.data
[ -e randread.1.0 ] && sudo rm randread.*

### benchmark info
(
echo clocksource: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)
echo governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
echo sysbench: "$(sysbench --version)"
echo perl: "$(perl --version)"
echo openssl: "$(openssl version)"
echo 7za: "$(7za version)"
) | tee -a $LOGFILE

### run benchmarks
echo Running benchmarks...
# some are repeated to check for variance

# clock speed:
run C1 /usr/lib/lmbench/bin/x86_64-linux-gnu/mhz
run C1 /usr/lib/lmbench/bin/x86_64-linux-gnu/mhz
run C1 /usr/lib/lmbench/bin/x86_64-linux-gnu/mhz
run C1 /usr/lib/lmbench/bin/x86_64-linux-gnu/mhz
run C1 /usr/lib/lmbench/bin/x86_64-linux-gnu/mhz

# CPU single core performance:
run C2 sysbench --max-requests=10000000 --max-time=10 --num-threads=1 --test=cpu --cpu-max-prime=10000 run
run C2 sysbench --max-requests=10000000 --max-time=10 --num-threads=1 --test=cpu --cpu-max-prime=10000 run
run C2 sysbench --max-requests=10000000 --max-time=10 --num-threads=1 --test=cpu --cpu-max-prime=10000 run
run C2 sysbench --max-requests=10000000 --max-time=10 --num-threads=1 --test=cpu --cpu-max-prime=10000 run
run C2 sysbench --max-requests=10000000 --max-time=10 --num-threads=1 --test=cpu --cpu-max-prime=10000 run

# CPU single core performance, CPU bound:
run C3 numactl --physcpubind=0 sysbench --max-requests=10000000 --max-time=10 --num-threads=1 --test=cpu --cpu-max-prime=10000 run

# CPU total capacity:
run C4 sysbench --max-requests=10000000 --max-time=10 --num-threads=$ncpu --test=cpu --cpu-max-prime=10000 run

# CPU performance, different workload (more to sanity check earlier results):
run C5 openssl speed rsa4096 -multi $ncpu

# CPU performance, different workload (more to sanity check earlier results):
run C6 7za b

# system call performance:
run S1 dd if=/dev/zero of=/dev/null bs=1 count=10000000

# TSC performance:
run S2 perl -e 'use Time::HiRes; for (;$i++ < 10_000_000;) { Time::HiRes::gettimeofday(); }'

# memory access latency across ranges, exposing CPU cache and memory subsystem hierarchy:
run M1 /usr/lib/lmbench/bin/x86_64-linux-gnu/lat_mem_rd 256m 128
run M1 /usr/lib/lmbench/bin/x86_64-linux-gnu/lat_mem_rd 256m 128
run M1 /usr/lib/lmbench/bin/x86_64-linux-gnu/lat_mem_rd 256m 128

# memory access latency with a different stride:
run M2 /usr/lib/lmbench/bin/x86_64-linux-gnu/lat_mem_rd 1024m 1024

# memory access latency, CPU and memory node bound:
run M3 numactl --membind=0 --physcpubind=0 /usr/lib/lmbench/bin/x86_64-linux-gnu/lat_mem_rd 1024m 1024

# memory bandwidth:
run M4 /usr/lib/lmbench/bin/x86_64-linux-gnu/bw_mem 250m cp

# different memory micro-benchmark:
run M4 sysbench --test=memory --num-threads=$ncpu run

# file system writes, ending with an fsync to flush:
run F1 fio --name=seqwrite --rw=write --filename=fio.data --bs=128k --size=4g --end_fsync=1 --loops=4

# file system random reads, cached:
run F2 fio --name=randread --rw=randread --pre_read=1 --norandommap --bs=4k --size=256m --runtime=30 --loops=1000

# file system multi-threaded random reads, cached:
run F3 fio --numjobs=$ncpu --name=randread --rw=randread --pre_read=1 --norandommap --bs=4k --size=$((256 / ncpu))m --runtime=30 --loops=1000

# file system multi-threaded random reads, partial cache:
run F4 bash -c 'echo 3 > /proc/sys/vm/drop_caches; fio --numjobs='$ncpu' --name=partial --rw=randread --filename=fio.data --norandommap --random_distribution=pareto:0.9 --bs=4k --size=4g --runtime=60 --loops=1000'

# disk read, cached (first 512 byte sector only):
run D1 fio --name=iops --rw=read --bs=512 --size=512 --io_size=1g --filename=$mntdev --direct=1 --ioengine=libaio --runtime=15

# disk random reads:
run D2 fio --name=iops --rw=randread --norandommap --bs=512 --size=4g --filename=$mntdev --direct=1 --ioengine=libaio --runtime=15

# disk random reads, with a queue depth:
run D3 fio --name=iops --rw=randread --norandommap --bs=512 --size=4g --filename=$mntdev --direct=1 --ioengine=libaio --iodepth=32 --runtime=15

# disk large sequential reads (1 Mbyte):
run D4 fio --name=iops --rw=read --bs=1m --size=4g --filename=$mntdev --direct=1 --ioengine=libaio --runtime=15

# disk large sequential reads (1 Mbyte), with a queue depth:
run D5 fio --name=iops --rw=read --bs=1m --size=4g --filename=$mntdev --direct=1 --ioengine=libaio --iodepth=4 --runtime=15

# network, loopback throughput:
run N1 bash -c 'iperf -s & sleep 1; iperf -c 127.0.0.1 -i 1 -t 15; pkill iperf'

# other network tests needs a remote host...

echo Done.
echo DATE: $(date) | tee -a $LOGFILE
echo
echo "Now run network benchmarks manually and analyze (active benchmarking)"
echo NOTE: benchmark files are left in $DATADIR.
