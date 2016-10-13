# Linux perf

_This is a summary of Linux perf created for a USENIX LISA 2016 workshop by Brendan Gregg and Sasha Goldshtein._

The "perf" command is the official profiler and tracer for Linux. Its source is included in the Linux tree (under tools/perf).

To use perf, first check that it is installed by trying to run "perf":

```
# perf

 usage: perf [--version] [--help] [OPTIONS] COMMAND [ARGS]

 The most commonly used perf commands are:
   annotate        Read perf.data (created by perf record) and display annotated code
   archive         Create archive with object files with build-ids found in perf.data file
   bench           General framework for benchmark suites
[...]
```

It should print a usage message like that above (truncated). On Ubuntu systems, if perf is not installed it will suggest the packages to install. Something like:

```
# apt-get install linux-tools-common linux-tools-`uname -r`
```

### Operation

Perf has four basic modes of operation:

- counting: counting events in kernel context and printing a report (low overhead). Eg, "perf stat".
- capture: recording events and writing to a perf.data file. Eg, "perf record".
- reporting: reading a perf.data file and dumping or summarizing its contents. Eg, "perf report".
- live recording: recording and summarizing events live. Eg, "perf top".

Whenever the perf.data file is in use, there is overhead to write this file, which is relative to the traced event rate. perf uses ring buffers and dynamic wakeups to lower this overhead.

### One-Liners

Common perf one-liners:

```
# Listing all currently known events:
perf list

# CPU counter statistics for the entire system, for 5 seconds:
perf stat -a sleep 5

# Count ext4 events for the entire system, for 10 seconds:
perf stat -e 'ext4:*' -a sleep 10

# Show system calls by process, refreshing every 2 seconds:
perf top -e raw_syscalls:sys_enter -ns comm

# Sample CPU stack traces for the specified PID, at 99 Hertz, for 10 seconds:
perf record -F 99 -p PID -g -- sleep 10

# Sample CPU stack traces for the entire system, at 99 Hertz, for 10 seconds:
perf record -F 99 -ag -- sleep 10

# Sample CPUs at 49 Hertz, and show top addresses and symbols, live (no perf.data file):
perf top -F 49

# Show perf.data in an ncurses browser (TUI) if possible:
perf report

# Show perf.data file as a text report with a sample count column:
perf report -n --stdi

# List all raw events from perf.data:
perf script
```

More one-liners in the Tracing section, and even more are listed on http://www.brendangregg.com/perf.html .

## CPU Flame Graphs

Flame graphs are generated in three steps:

1. Capture stacks
2. Fold stacks
3. flamegraph.pl

Using Linux perf, the following samples stack traces at 99 Hertz for 30 seconds, and then generates a flame graph of all sampled stacks (except those containing "cpu_idle": the idle threads):

```
# git clone --depth 1 https://github.com/brendangregg/FlameGraph
# cd FlameGraph
# perf record -F 99 -a -g -- sleep 30
# perf script | ./stackcollapse-perf.pl | grep -v cpu_idle | ./flamegraph.pl > out.svg
```

The "out.svg" file can then be loaded in a web browser.

### Broken Stacks

Broken/incomplete stack traces are a common problem with profilers. perf has multiple ways to walk (fetch) a stack. The easiest to get working is usually frame-pointer based walking. Enabling this for different languages:

- C: gcc's -f-no-omit-frame-pointer option
- Java: -XX:+PreserveFramePointer

### Missing Symbols

Missing symbols is a common problem when profiling JIT runtimes. perf support supplemental symbol tables in /tmp/perf-PID.map. Enabling this map for different languages:

- Java: https://github.com/jrudolph/perf-map-agent
- Node.js: --perf\_basic\_prof\_only\_functions

### Customizations

See flamegraph.pl --help. A common customization is to use an alternate palette scheme: eg, "--color java" for Java profiles.

## Tracing

Example static tracing one-liners:

```
# Trace new processes, until Ctrl-C:
perf record -e sched:sched_process_exec -a

# Trace all context-switches with stack traces, for 1 second:
perf record -e context-switches –ag -- sleep 1

# Trace CPU migrations, for 10 seconds:
perf record -e migrations -a -- sleep 10

# Trace all connect()s with stack traces (outbound connections), until Ctrl-C:
perf record -e syscalls:sys_enter_connect –ag

# Trace all block device (disk I/O) requests with stack traces, until Ctrl-C:
perf record -e block:block_rq_insert -ag

# Trace all block device issues and completions (has timestamps), until Ctrl-C:
perf record -e block:block_rq_issue -e block:block_rq_complete -a

# Trace all block completions, of size at least 100 Kbytes, until Ctrl-C:
perf record -e block:block_rq_complete --filter 'nr_sector > 200'

# Trace all block completions, synchronous writes only, until Ctrl-C:
perf record -e block:block_rq_complete --filter 'rwbs == "WS"'

# Trace all block completions, all types of writes, until Ctrl-C:
perf record -e block:block_rq_complete --filter 'rwbs ~ "*W*"'

# Trace all ext4 calls, and write to a non-ext4 location, until Ctrl-C:
perf record -e 'ext4:*' -o /tmp/perf.data -a
```

Example dynamic tracing one-liners:

```
# Add a tracepoint for the kernel tcp_sendmsg() function entry ("--add" is optional):
perf probe --add tcp_sendmsg

# Remove the tcp_sendmsg() tracepoint (or use "--del"):
perf probe -d tcp_sendmsg

# Add a tracepoint for the kernel tcp_sendmsg() function return:
perf probe 'tcp_sendmsg%return'

# Add a tracepoint for tcp_sendmsg(), with size and socket state (needs debuginfo):
perf probe 'tcp_sendmsg size sk->__sk_common.skc_state'

# Add a tracepoint for the user-level malloc() function from libc:
perf probe -x /lib64/libc.so.6 malloc

# List currently available dynamic probes:
perf probe -l
```

# References

- https://perf.wiki.kernel.org/index.php/Main_Page 
- http://www.brendangregg.com/perf.html
- http://www.brendangregg.com/FlameGraphs/cpuflamegraphs.html
- http://queue.acm.org/detail.cfm?id=2927301

