#!/bin/bash

function die() {
    echo "fatal: $*"
    exit 1
}
function try() {
    "$@" || die "failed: $*"
}

option_debug=''

name=''
path=''
kernel=''
kernel_suffix=''
kernel_modules=''
arch=''
lib_suffix=''
declare -a bins=('/bin/busybox' '/usr/bin/ssh' '/usr/bin/sshfs')
declare -a modules=()
declare -a libs=()

netboot_tftp="/var/netboot/tftp"

declare -A initramfs_ok
initramfs_ok['generic32']='true'
initramfs_ok['generic64']='true'
initramfs_ok['raspberry']='true'
function pack_initramfs() {
    try [ -n "${initramfs_ok["${name}"]}" ]
    try [ -n "$name" ]
    try [ -n "$path" ]
    
    ## for debug only
    # try cp -av --dereference "${path}/snapshot/usr/bin/strace" "${path}/initramfs/bin/"
    # try cp -av --dereference "${path}/snapshot/usr/bin/ldd" "${path}/initramfs/bin/"
    # try cp -av --dereference "${path}/snapshot/bin/bash" "${path}/initramfs/bin/"
    # libs=('/lib64/libreadline.so.6' '/lib64/libncurses.so.5')
    # for lib in "${libs[@]}"; do
    #     try cp -av --dereference "${path}/snapshot${lib}" "${path}/initramfs/lib64/"
    # done

    [ -d "${path}/initramfs.source" ] && [ -d "${path}/initramfs" ] && try rm -rf "${path}/initramfs"
    [ -d "${path}/initramfs.source" ] && try cp -av "${path}/initramfs.source" "${path}/initramfs"

    [ -d "${path}/initramfs/bin" ] || try mkdir "${path}/initramfs/bin"
    [ -d "${path}/initramfs/dev" ] || try mkdir "${path}/initramfs/dev"
    [ -d "${path}/initramfs/dev/pts" ] || try mkdir "${path}/initramfs/dev/pts"
    [ -d "${path}/initramfs/lib" ] || try mkdir "${path}/initramfs/lib"
    [ -d "${path}/initramfs/lib/modules" ] || try mkdir "${path}/initramfs/lib/modules"
    [ -d "${path}/initramfs/mount" ] || try mkdir "${path}/initramfs/mount"
    [ -d "${path}/initramfs/mount/root0" ] || try mkdir "${path}/initramfs/mount/root0"
    [ -d "${path}/initramfs/mount/root1" ] || try mkdir "${path}/initramfs/mount/root1"
    [ -d "${path}/initramfs/mount/root2" ] || try mkdir "${path}/initramfs/mount/root2"
    [ -d "${path}/initramfs/mount/root3" ] || try mkdir "${path}/initramfs/mount/root3"
    [ -d "${path}/initramfs/mount/root4" ] || try mkdir "${path}/initramfs/mount/root4"
    [ -d "${path}/initramfs/proc" ] || try mkdir "${path}/initramfs/proc"
    [ -d "${path}/initramfs/sbin" ] || try mkdir "${path}/initramfs/sbin"
    [ -d "${path}/initramfs/sys" ] || try mkdir "${path}/initramfs/sys"
    [ -d "${path}/initramfs/tmp" ] || try mkdir "${path}/initramfs/tmp"
    [ -d "${path}/initramfs/var" ] || try mkdir "${path}/initramfs/var"
    [ -d "${path}/initramfs/var/log" ] || try mkdir "${path}/initramfs/var/log"
    try touch "${path}/initramfs/var/log/lastlog"
    [ -f "${path}/initramfs/init" ] || echo "need for switch_root sanity check" > "${path}/initramfs/init"

    try mknod -m 600 "${path}/initramfs/dev/console" c 5 1
    try mknod -m 666 "${path}/initramfs/dev/null" c 1 3
    try mknod -m 666 "${path}/initramfs/dev/tty" c 5 0

    for module in "${modules[@]}" "${modules_extra[@]}"; do
        try cp -av --dereference "${path}/snapshot/lib/modules/${kernel_modules}/${module}" "${path}/initramfs/lib/modules/"
    done

    for file in 'lspci' 'mount' 'ping' 'sh' 'umount' 'sleep'; do
        try ln -fs 'busybox' "${path}/initramfs/bin/${file}"
    done
    for file in 'insmod' 'mdev' 'switch_root' 'udhcpc'; do
        try ln -fs '/bin/busybox' "${path}/initramfs/sbin/${file}"
    done
    
    for file in "${bins[@]}"; do
        # no need for squashfuse: kernel module is used
        try cp -av --dereference "${path}/snapshot${file}" "${path}/initramfs/bin/"
    done
    
    for lib in "${libs[@]}"; do
        try cp -av --dereference "${path}/snapshot${lib}" "${path}/initramfs/lib${lib_suffix}/"
    done 
    
    try cd "${path}/initramfs"
    find . -print0 | cpio --null -ov --format=newc | gzip -9 > "${path}/initramfs.cpio.gz"
    
    ls -lh --dereference "${path}/initramfs.cpio.gz"
    try cp -av --dereference "${path}/initramfs.cpio.gz" "${netboot_tftp}/initramfs-${name}"

    if [ -n "${kernel}" ]; then
        ls -lh --dereference "${path}/gentoo/source/linux/arch/${arch}/boot/bzImage"
        try cp -av --dereference "${path}/gentoo/source/linux/arch/${arch}/boot/bzImage" "${netboot_tftp}/vmlinuz-${name}"
    fi
}

declare -A snapshot_ok
snapshot_ok['generic32']='true'
snapshot_ok['generic64']='true'
snapshot_ok['raspberry']='true' # not implemented yet
function pack_snapshot() {
    try [ -n "${snapshot_ok["${name}"]}" ]
    try [ -d 'snapshot' ]
    cat snapshot/root/.bash_history >> snapshot/root/.bash_history.old
    echo "echo 'hello\!'" > snapshot/root/.bash_history
    try mksquashfs snapshot snapshot.temp.sqfs -no-xattrs
    md5="`md5sum 'snapshot.temp.sqfs' | awk '{ print $1; }'`"
    snapshot="snapshot.`date '+%Y-%m-%d'`.${md5}.sqfs"
    try mv 'snapshot.temp.sqfs' "${snapshot}"
    try ln -fs "${snapshot}" "snapshot.sqfs"
}

function setup_generic() {
    modules+=(
        'kernel/drivers/net/mii.ko' 'kernel/drivers/net/ethernet/amd/pcnet32.ko'
        'kernel/drivers/net/ethernet/marvell/sky2.ko'
        'kernel/drivers/ptp/ptp.ko' 'kernel/drivers/pps/pps_core.ko'
        'kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko'
        'kernel/drivers/net/ethernet/atheros/atlx/atl2.ko'
        'kernel/fs/configfs/configfs.ko' 'kernel/drivers/net/netconsole.ko'
        'kernel/drivers/block/loop.ko' 'kernel/fs/squashfs/squashfs.ko'
        'kernel/fs/fuse/fuse.ko' 'misc/aufs.ko'
    )
    kernel='auto'
}

function setup_generic32() {
    name='generic32'
    setup_generic
    # kernel='4.1.12-gentoo-m0'
    kernel_suffix='-m0'
    arch='x86'
    libs+=(
        '/lib/ld-linux.so.2' '/lib/libc.so.6' '/usr/lib/libcrypto.so.1.0.0' '/lib/libdl.so.2'
        '/usr/lib/libfuse.so.2' '/usr/lib/libglib-2.0.so.0' '/usr/lib/libgthread-2.0.so.0'
        '/lib/libpthread.so.0' '/lib/libresolv.so.2' '/lib/libz.so.1' '/lib/libnss_files.so.2'
    )
    modules+=(
        'kernel/drivers/ata/libahci.ko' 'kernel/drivers/ata/ahci.ko'
        'kernel/drivers/ata/ata_piix.ko'
        'kernel/drivers/md/dm-mod.ko' 'kernel/drivers/md/dm-crypt.ko'
        'kernel/crypto/af_alg.ko' 'kernel/crypto/algif_skcipher.ko' 'kernel/crypto/algif_hash.ko'
        'kernel/crypto/xts.ko' 'kernel/crypto/hmac.ko' 'kernel/crypto/sha1_generic.ko'
        'kernel/fs/xfs/xfs.ko' 'kernel/crypto/crc32c_generic.ko' 'kernel/lib/libcrc32c.ko'
    )
}
function setup_generic64() {
    name='generic64'
    setup_generic
    # kernel='4.0.5-gentoo-m1'
    kernel_suffix='-m1'
    arch='x86_64'
    libs+=(
        '/usr/lib64/libfuse.so.2' '/usr/lib64/libgthread-2.0.so.0' '/usr/lib64/libglib-2.0.so.0'
        '/lib64/libpthread.so.0' '/lib64/libc.so.6' '/lib64/libdl.so.2' '/lib64/ld-linux-x86-64.so.2'
        '/usr/lib64/libcrypto.so.1.0.0' '/lib64/libz.so.1' '/lib64/libresolv.so.2'
        '/lib64/libpthread.so.0' '/lib64/libnss_files.so.2'
    )
    lib_suffix='64'
}

function setup_raspberry() {
    name='raspberry'
    kernel_modules='4.4.50-v7+'
    modules+=(
        # '/kernel/kernel/configs.ko'
        '/kernel/drivers/net/netconsole.ko'
        '/kernel/fs/fuse/fuse.ko'
        '/kernel/fs/squashfs/squashfs.ko'
        '/kernel/fs/overlayfs/overlay.ko'
    )
    libs+=(
        # extra libs for ssh
        '/lib/arm-linux-gnueabihf/libnss_files.so.2'
        # libs for ssh
        '/usr/lib/arm-linux-gnueabihf/libarmmem.so' '/lib/arm-linux-gnueabihf/libselinux.so.1'
        '/usr/lib/arm-linux-gnueabihf/libcrypto.so.1.0.0' '/lib/arm-linux-gnueabihf/libdl.so.2'
        '/lib/arm-linux-gnueabihf/libz.so.1' '/lib/arm-linux-gnueabihf/libresolv.so.2'
        '/usr/lib/arm-linux-gnueabihf/libgssapi_krb5.so.2' '/lib/arm-linux-gnueabihf/libc.so.6'
        '/lib/ld-linux-armhf.so.3' '/lib/arm-linux-gnueabihf/libpcre.so.3'
        '/usr/lib/arm-linux-gnueabihf/libkrb5.so.3' '/usr/lib/arm-linux-gnueabihf/libk5crypto.so.3'
        '/lib/arm-linux-gnueabihf/libcom_err.so.2' '/usr/lib/arm-linux-gnueabihf/libkrb5support.so.0'
        '/lib/arm-linux-gnueabihf/libkeyutils.so.1' '/lib/arm-linux-gnueabihf/libpthread.so.0'
        # extra libs for sshfs
        '/lib/arm-linux-gnueabihf/libfuse.so.2' '/usr/lib/arm-linux-gnueabihf/libgthread-2.0.so.0'
        '/lib/arm-linux-gnueabihf/libglib-2.0.so.0'
    )
}

function setup_debug() {
    bins+=('/usr/bin/strace' '/usr/bin/ldd')
    # libs+=()
}

while [ "$#" -gt 0 ]; do
    option='true'
    case "$1" in
        ('--debug') option_debug='true';;
        (*) option='false';;
    esac
    [ "${option}" == 'true' ] || break;
    shift
done

if [ "$#" -ne 2 ]; then
    echo "bad usage: $0 $*"
    echo "usage: $0 <name> <target>"
    echo "    names: generic32, generic64, raspberry"
    echo "    targets: snapshot, initramfs, all"
    exit 1
fi

case "$1" in
    ('generic32') setup_generic32;;
    ('generic64') setup_generic64;;
    ('raspberry') setup_raspberry;;
    (*) die "unknown name: '$1'";;
esac

if [ "${option_debug}" ]; then
    setup_debug
fi

path="/storage/netboot/${name}"

try cd "$path"

if [ "${kernel}" == 'auto' ]; then
    kernel="`readlink gentoo/source/linux`${kernel_suffix}"
    kernel="${kernel#linux-}"
    kernel_modules="${kernel_modules:-"${kernel}"}"
fi

case "$2" in
    ('all') pack_snapshot; pack_initramfs;;
    ('initramfs') pack_initramfs;;
    ('snapshot') pack_snapshot;;
    (*) die "unknown target: '$2'";;
esac

