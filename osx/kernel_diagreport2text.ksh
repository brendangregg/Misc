#!/bin/ksh
#
# kernel_diagreport2text.ksh 
#
# Prints the stack trace from an OS X kernel panic diagnostic report, along
# with as much symbol translation as your mach_kernel version provides.
# By default, this is some, but with the Kernel Debug Kit, it should be a lot
# more. This is not an official Apple tool. 
#
# USAGE:
# 	./kernel_diagreport2text.ksh [-f kernel_file] Kernel_report.panic [...]
#
# Note: The Kernel Debug Kit currently requires an Apple ID to download. It
# would be great if this was not necessary.
#
# This script calls atos(1) for symbol translation, and also some sed/awk
# to decorate remaining untranslated symbols with kernel extension names,
# if the ranges match.
#
# This uses your current kernel, /mach_kernel, to translate symbols. If you run
# this on kernel diag reports from a different kernel version, it will print
# a "kernel version mismatch" warning, as the translation may be incorrect. Find
# a matching mach_kernel file and use the -f option to point to it.
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

function usage {
	print "USAGE: $0 [-f kernel_file] Kernel_diag_report.panic [...]"
	print "   eg, $0 /Library/Logs/DiagnosticReports/Kernel_2014-05-26-124827_bgregg.panic"
	exit
}
(( $# == 0 )) && usage
[[ $1 == "-h" || $1 == "--help" ]] && usage

if [[ $1 == "-f" ]]; then
	kernel=$2
	if [[ ! -e $kernel ]]; then
		print -u2 "ERROR: Kernel $kernel not found. Quitting."
		exit 2
	fi
	shift 2
fi

if [[ ! -x /usr/bin/atos ]]; then
	print -u2 "ERROR: Couldn't find, and need, /usr/bin/atos. Is this part of Xcode? Quitting..."
	exit 2
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

	# Print panic line
	grep '^panic' $file

	# Check kernel version match (uname -v string)
	kernel_ver=$(strings -a $kernel | grep 'Darwin Kernel Version')
	panic_ver=$(grep 'Darwin Kernel Version' $file)
	warn=""
	if [[ "$kernel_ver" != "$panic_ver" ]]; then
		print "WARNING: kernel version mismatch (use -f):"
		printf "%14s: %s\n" "$kernel" "$kernel_ver"
		printf "%14s: %s\n" "panic file" "$panic_ver"
		warn=" (may be incorrect due to mismatch)"
	fi

	# Find kernel extension ranges
	i=0
	unset name start end
	awk 'ext == 1 && /0x.*->.*0x/ {
		    gsub(/\[.*\]/, ""); gsub(/@/, " "); gsub(/->/, " ")
		    print $0
		}
		/Kernel Extensions in backtrace/ { ext = 1 }
		/^$/ { ext = 0 }
	' < $file | while read n s e; do
		# the awk gsub's convert this line:
		#   com.apple.driver.AppleUSBHub(666.4)[CD9B71FF-2FDD-3BC4-9C39-5E066F66D158]@0xffffff7f84ed2000->0xffffff7f84ee9fff
		# into this:
		#   com.apple.driver.AppleUSBHub(666.4) 0xffffff7f84ed2000 0xffffff7f84ee9fff
		# which can then be read as three fields
		name[i]=$n
		start[i]=$s
		end[i]=$e
		(( i++ ))
	done

	# Print and translate stack
	print "Stack$warn:"
	awk 'backtrace == 1 && /^[^ ]/ { print $3 }
		/Backtrace.*Return Address/ { backtrace = 1 }
		/^$/ { backtrace = 0 }
	' < $file | atos -d -o $kernel -s $slide | while read line; do
		# do extensions
		if [[ $line =~ 0x* ]]; then
			i=0
			while (( i <= ${#name[@]} )); do
				[[ "${start[i]}" == "" ]] && break
				# assuming fixed width addresses, use string comparison:
				if [[ $line > ${start[$i]} && $line < ${end[$i]} ]]; then
					line="$line (in ${name[$i]})"
					break
				fi
				(( i++ ))
			done
		fi
		print "	$line"
	done

	# Print other key details
	awk '/^BSD process name/ { gsub(/ corresponding to current thread/, ""); print $0 }
		ver == 1 { print "Mac OS version:", $0; ver = 0 }
		/^Mac OS version/ { ver = 1 }
	' < $file
done
