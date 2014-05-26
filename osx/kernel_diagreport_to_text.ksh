#!/bin/ksh
#
# kernel_diagreport_to_text.ksh 
#
# Prints the stack trace from an OS X kernel panic diagnostic report, along
# with as much symbol translation as your mach_kernel version provides.
# By default, this is some, but with the Kernel Debug Kit, it should be a lot
# more. This is not an official Apple tool. 
#
# Note: The Kernel Debug Kit currently requires an Apple ID to download. It
# would be great if this was not necessary.
#
# This script calls atos(1) for symbol translation, and some awk(1) for
# easier text processing (this could just be shell).
#
# Copyright 2014 Brendan Gregg.  All rights reserved.
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at docs/cddl1.txt or
# http://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at docs/cddl1.txt.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END

kernel=/mach_kernel

if (( $# == 0 )); then
	print "USAGE: $0 Kernel_diag_report.panic [...]"
	print "   eg, $0 /Library/Logs/DiagnosticReports/Kernel_2014-05-26-124827_bgregg.panic"
	exit
fi

while (( $# != 0 )); do
	if [[ "$file" != "" ]]; then print; fi
	file=$1
	shift
	echo "File $file"

	if [[ ! -e $file ]]; then
		print "ERROR: File $file not found. Skipping."
		continue
	fi

	# Find slide address
	slide=$(awk '/^Kernel slide:.*0x/ { print $3 }' $file)
	if [[ "$slide" == "" ]]; then
		print -n "ERROR: Missing \"Kernel slide:\" line, so can't process $file. "
		print "This is needed for atos -s. Is this really a Kernel diag panic file?"
		continue
	fi

	# Print and translate stack
	print "Stack:"
	awk 'backtrace == 1 { print $3 }
		/Backtrace.*Return Address/ { backtrace=1 }
		/^$/ { backtrace=0 }
	' < $file | atos -d -o $kernel -s $slide | while read line; do
		print "	$line"
	done

	# Print key details
	awk '/^BSD process name/ { print "BSD process name:", $NF }
		ver == 1 { print "Mac OS version:", $0; ver = 0 }
		/^Mac OS version/ { ver=1 }
	' < $file
done
