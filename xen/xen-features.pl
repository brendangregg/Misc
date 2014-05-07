#!/usr/bin/perl -w
#
# xen-features.pl	print Linux Xen guest feature bits in human.
#
# This will get out of date. If you're a Xen developer, you are welcome to put
# this under xen/tools/misc, where others can update it.
#
# 05-May-2014	Brendan Gregg	Created this.

use strict;

open FEAT, "/sys/hypervisor/properties/features" or die "ERROR open(): $!";
my $features = <FEAT>;
close FEAT;
chomp $features;
my $decfeatures = hex $features;

print "Xen features: $features\n";

foreach (<DATA>) {
	my ($def, $feat, $bit) = split;
	$feat =~ s/^XENFEAT_//;
	print "enabled: $feat\n" if $decfeatures & (1 << $bit);
}

# The following are from include/xen/interface/features.h, and will need updating:

__DATA__
#define XENFEAT_writable_page_tables       0
#define XENFEAT_writable_descriptor_tables 1
#define XENFEAT_auto_translated_physmap    2
#define XENFEAT_supervisor_mode_kernel     3
#define XENFEAT_pae_pgdir_above_4gb        4
#define XENFEAT_mmu_pt_update_preserve_ad  5
#define XENFEAT_hvm_callback_vector        8
#define XENFEAT_hvm_safe_pvclock           9
#define XENFEAT_hvm_pirqs           10
#define XENFEAT_dom0                      11
