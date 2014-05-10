#!/usr/bin/python
#
# xen-features.py	print Linux Xen guest feature bits in human.
#
# This will get out of date. If you're a Xen developer, you are welcome to put
# this under xen/tools/misc, where others can update it.
#
# 05-May-2014	Brendan Gregg	Created this.

try:
  with open("/sys/hypervisor/properties/features", "r") as infile:
    features = infile.read().rstrip()
except IOError as msg:
  print 'ERROR: reading Xen features (not a Xen guest?):', msg

print "Xen features:", features
decfeatures = int(features, 16)

with open(__file__) as data:
  for line in data:
    if line.startswith('# __DATA__'):
      for line in data:
        a = line[1:].split()
        name = a[1]
        bit = int(a[2])
        if decfeatures & (1 << bit):
          print "enabled:", name[8:]

# __DATA__
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
