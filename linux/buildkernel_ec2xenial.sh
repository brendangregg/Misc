#!/bin/bash
#
# buildkernel_ec2xenial.sh   linux kernel build on ubuntu-xenial/EC2.
#
# USAGE: buildkernel_ec2xenial.sh [-D] {tarball.xz | tarball.xz_URL} [patches_dir]
#
#		-D	# debuginfo
#
# eg,
#     ./buildkernel_ec2xenial.sh ../kernels/linux-3.13.tar.gz
#     ./buildkernel_ec2xenial.sh -D ../kernels/linux-3.13.tar.gz
#     ./buildkernel_ec2xenial.sh ../kernels/linux-3.13-patched.tar.gz
#     ./buildkernel_ec2xenial.sh ../kernels/linux-4.2.tar.gz mypatches01
#     ./buildkernel_ec2xenial.sh https://www.kernel.org/pub/linux/kernel/v4.x/testing/linux-4.2-rc5.tar.xz
#
# Can get kernel tar.xz URL from https://www.kernel.org
# Can get patches from https://patchwork.kernel.org/project/LKML/list/
#
# Kernel is built under /mnt/src/linux... . Kernel build output is written to
# build.{stdout,stderr}. Install output to install.{stdout,stderr}.
#
# See fixapt_xenial for some of the xenial specifics.
#
# 24-Aug-2016	Brendan Gregg	Created this.

### usage
function usage {
	echo "USAGE: $0 [-D] {tarball.xz | tarball.xz_URL} [patches_dir]"
	exit
}

### process options
opt_debuginfo=0
while getopts D opt
do
	case $opt in
	D)	opt_debuginfo=1 ;;
	h|?)	usage ;;
	esac
done
shift $(( $OPTIND - 1 ))
(( $# == 0 )) && usage
kernel=$1
src=/mnt/src

### functions
function run {
	"$@"
	e=$?
	if (( $e != 0 )); then
		echo >&2 "CMD   : $@"
		echo >&2 "ERROR : exit status: $e, quitting"
		exit
	fi
}

function die {
	echo >&2 "$@"
	exit 1
}

did_update=0
function addpkgs {
	all=1
	for pkg in "$@"; do
		if ! dpkg -s $pkg > /dev/null 2>&1; then all=0; fi
	done
	if (( all )); then
		echo "Packages already installed."
	else
		if (( ! did_update )); then
			sudo apt-get update
			did_update=1
		fi
		for pkg in "$@"; do
			sudo apt-get install -y $pkg
		done
	fi
}

function fixapt_xenial {
	aptsrc=/etc/apt/sources.list
	sudo perl -p -i -e 's/^/#/' $aptsrc
	sudo sh -c 'echo "
# Ubuntu xenial:
deb [arch=amd64,i386] http://us-west-1.ec2.archive.ubuntu.com/ubuntu/ xenial main restricted universe multiverse
deb-src http://us-west-1.ec2.archive.ubuntu.com/ubuntu/ xenial main restricted universe multiverse
deb [arch=amd64,i386] http://us-west-1.ec2.archive.ubuntu.com/ubuntu/ xenial-updates main restricted universe multiverse
deb-src http://us-west-1.ec2.archive.ubuntu.com/ubuntu/ xenial-updates main restricted universe multiverse
deb [arch=amd64,i386] http://security.ubuntu.com/ubuntu xenial-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu xenial-security main restricted universe multiverse
	" >> '$aptsrc
}

### timestamp
echo $0 Begin.
start=$(date)
echo $start

### fetch kernel source
if [[ "$kernel" == http* ]]; then
	echo Fetching source: $url...
	run wget $1
	file=${1##*/}
else
	file=$kernel
fi
if [[ ! -e $file ]]; then
	echo >&2 "ERROR: kernel source file ($file) missing?"
	ls $file
	exit 2
fi
filepath=$PWD/$file

### check for patches
if [[ "$2" != "" ]]; then
	patchdir=$2
	[[ "$patchdir" != /* ]] && patchdir=$PWD/$patchdir
	if [ ! -d $patchdir ]; then
		echo >&2 "Patch directory $patchdir doesn't exist"
		exit 2
	fi
fi

### fix apt if needed
echo Setting apt sources...
fixapt_xenial

### add packages (both necessary and convenient)
echo Adding packages...
addpkgs gcc make ncurses-dev libssl-dev bc
echo Adding packages for perf...
addpkgs flex bison libelf-dev libdw-dev libaudit-dev
echo Adding packages for perf TUI...
addpkgs libnewt-dev libslang2-dev
echo Adding packages for convenience...
addpkgs sharutils sysstat bc

### remove some packages to un-complicate kernel builds
echo Removing ZFS and SPL kernel components
sudo dpkg -r zfs-dkms ubuntu-zfs spl-dkms

### expand source
echo Prepping build environment: $src...
sudo mkdir -p $src
run sudo chown $USER $src
cd $src
run tar xf $filepath

echo Build prep...
dir=${file%.tar.*}
echo directory: $src/$dir
cd $dir

### apply patches
if [[ "$patchdir" != "" ]]; then
	echo APPLYING PATCHES from $patchdir
	for patch in $patchdir/*; do
		echo Applying patch: $patch
		run patch -p1 < $patch
	done
fi

### kernel config
run make olddefconfig
#
# for manual setup, run "make menuconfig" and EC2 customizations are:
# Processor type and features -> Linux guest support -> Enable paravirtualization code (PARAVIRT)
# 	Paravirtualization layer for spinlocks (PARAVIRT_SPINLOCKS)
# 	Xen guest support, Support for running as a PVH guest (XEN_PVH)
# 	Paravirtual steal time accounting (PARAVIRT_TIME_ACCOUNTING)
# Device Drivers -> Block devices -> Xen virtual block device support (XEN_BLKDEV_FRONTEND)
# Device Drivers -> Network device support devices -> Xen virtual network frontend driver (XEN_NETDEV_FRONTEND)
# Device Drivers -> Generic driver options -> Maintain a devtmpfs filesystem ..., and Automount (DEVTMPFS, DEVTMPFS_MOUNT)
# Kernel Hacking -> Compile-time checks and compiler options -> Configure kernel debug info (DEBUG_INFO)
# General setup -> Configure standard kernel features (expert users) -> (BPF_SYSCALL)
# On Linux 3.2, just copy /boot/config...
#
echo Running scripts/config ...
run ./scripts/config -e CONFIG_PARAVIRT \
    -e CONFIG_PARAVIRT_SPINLOCKS \
    -e CONFIG_PARAVIRT_TIME_ACCOUNTING \
    -e CONFIG_PARAVIRT_CLOCK \
    -e CONFIG_HYPERVISOR_GUEST \
    -e CONFIG_XEN \
    -e CONFIG_XEN_PVHVM \
    -e CONFIG_XEN_PVH \
    -e CONFIG_XEN_BLKDEV_FRONTEND \
    -e CONFIG_XEN_NETDEV_FRONTEND \
    -e CONFIG_DEVTMPFS \
    -e CONFIG_DEVTMPFS_MOUNT \
    -e CONFIG_BPF_EVENTS \
    -e CONFIG_BPF_SYSCALL \
    -e CONFIG_HIST_TRIGGERS \
    -d CONFIG_SOUND
#
# The following is necessary for update-grub-legacy-ec2 to recognize
# this as a valid kernel and add it to menu.lst; the call path is
# arch/x86/boot/install.sh -> /sbin/installkernel ->
# run-parts /etc/kernel/postinst.d -> .../x-grub-legacy-ec2 ->
# /usr/sbin/update-grub-legacy-ec2 (the latter two are added by
# the grub-legacy-ec2 package).
#
run ./scripts/config --set-str CONFIG_LOCALVERSION "-virtual"

if (( opt_debuginfo )); then
	run ./scripts/config -e CONFIG_DEBUG_INFO
else
	run ./scripts/config -d CONFIG_DEBUG_INFO
fi

### kernel build
echo Kernel build...
cpus=$(grep -c '^processor.:' /proc/cpuinfo)
(time make -j $cpus) > build.stdout 2> build.stderr
cat build.stderr

### extra builds
echo Extra builds...
cd tools/perf
make >> build.stdout 2>> build.stderr
cd ../..

### kernel install
echo Install...
sudo make modules_install > install.stdout 2> install.stderr
sudo make install >> install.stdout 2>> install.stderr	# calls update-grub
cat install.stderr
release=$(make kernelrelease)

### boot config
echo Grub1...		# rewrite the following when grub2 is in use
# check boot files, and add a fallback entry to grub
menu=/boot/grub/menu.lst
tmp=/tmp/menu.lst.$$
if [ ! -e /boot/vmlinuz-$release ]; then
	echo >&2 "ERROR: Can't find boot files for $release." \
	    "Build or install failed? Exiting without updating grub."
	exit 3
fi
awk '{ out = 1 }
	/^default/ { print $0; print "fallback\t2"; out = 0 }
	/^fallback/ { out = 0 }
	out == 1 { print }
' $menu > $tmp
if ! egrep -v '^(#|$)' $tmp >/dev/null; then
	echo >&2 "ERROR: generated grub file failure. Exiting without" \
	    "updating grub."
	exit 5
fi
sudo bash -c "cat $tmp > $menu"

### really fix grub (update-grub doesn't update properly on xenial)
sudo update-grub-legacy-ec2
sudo update-grub
sudo sync

### done
echo Done. Built and installed $release.
echo $start Started.
date
echo $0 Done.
echo Rebooting...
sudo reboot
