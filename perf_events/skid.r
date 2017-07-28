# skid.r	Histogram of skid latency.
#
# USAGE: R --no-save < skid.r
#
# Adjust issue_width (superscalar multiple execute) below to match your
# processor.
#
# 23-Mar-2017	Brendan Gregg	Created this.

title <- "Histogram of LLC miss skid, no PEBS, PC (Skylake)"
filename <- "skidlist07.txt"
max_cycle <- 1000	# change if needed
issue_width <- 4	# change when needed

pdf("skid.pdf", w=10, h=6)
input <- read.table(filename, header=FALSE)
input <- input / issue_width	# NOP offset -> cycles

hist(input$V1, breaks=50, xlim=c(0, max_cycle), xaxt='n', main=title, ylab="Count", xlab="Cycles")
axis(1, at=seq(0, max_cycle, 50))
