#!/bin/busybox sh

die() {
    echo "fatal: $*"
    exec < /dev/console > /dev/console 2>&1
    echo "[drop to busybox shell]"
    exec sh
}

# options (kernel cmdline)
#  netboot_server=<server>  -- server ip address
#  netconsole               -- send system logs to server
#  copyfile                 -- copy snapshot into tmpfs before start (need a lot of RAM)
#  dropbear                 -- start dropbear ssh server for extra init actions (ex. mount crypted partitions)


sleep 1
echo "burunduk3's netboot"

# mount special fs
mount -t proc none /proc || die "failed to mount /proc"
mount -t sysfs none /sys || die "failed to mount /sys"
mount -t devtmpfs none /dev || die "failed to mount /dev"
mkdir /dev/pts
mount -t devpts devpts /dev/pts || die "failed to mount /dev/pts"

# setup devices
echo /sbin/mdev > /proc/sys/kernel/hotplug
mdev -s

# parse kernel command line
parse_cmd_arg() {
   key="arg_$1"; shift
   value="$*"
   [ -z "$value" ] && value='true'
   # eval "$key='$value'"  ## eval doesn't work in raspbian busybox
   case "${key}" in
       ('arg_netboot_server') arg_netboot_server="${value}";;
       ('arg_copyfile') arg_copyfile="${value}";;
       ('arg_dropbear') arg_dropbear="${value}";;
       ('arg_netconsole') arg_netconsole="${value}";;
       (*) echo "[debug] unparsed arg: key=$key, value=$value";;
   esac
}
parse_cmd_args() {
    for x in "$@"; do
        x="`echo $x | sed -e 's/=/ /'`"
        parse_cmd_arg $x
    done
}
parse_cmd() {
    line="$(cat /proc/cmdline)"
    parse_cmd_args $line
}
parse_cmd

# check for necessary variables
[ -n "$arg_netboot_server" ] || die "argument required: netboot_server"

# scan devices & local modules
# modules="configfs netconsole loop fuse squashfs aufs"
modules="fuse squashfs overlay"
for device in $(lspci | awk '{ print $4; }'); do
    case "$device" in
        ('1022:2000') modules="$modules mii pcnet32";;
        ('106b:003f') ;;
        ('1969:2048') modules="$modules atl2";; # Attansic L2 Fast Ethernet
        ('8086:10d3') modules="$modules pps_core ptp e1000e";;
        ('8086:2448') ;;
        ('8086:2641') ;; # 82801FBM (ICH6M) LPC Interface Bridge
        ('8086:2653') ;; # 82801FBM (ICH6M) SATA Controller
        ('8086:2658') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) USB UHCI #1
        ('8086:2659') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) USB UHCI #2
        ('8086:265a') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) USB UHCI #3
        ('8086:265b') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) USB UHCI #4
        ('8086:265c') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) USB2 EHCI Controller
        ('8086:2660') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) PCI Express Port 1
        ('8086:2662') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) PCI Express Port 2
        ('8086:2664') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) PCI Express Port 3
        ('8086:2668') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) High Definition Audio Controller
        ('8086:266a') ;; # 82801FB/FBM/FR/FW/FRW (ICH6 Family) SMBus Controller
        ('8086:2792') ;; # Mobile 915GM/GMS/910GML Express Graphics Controller
        ('8086:27b9') ;;
        # ('8086:3a39') modules="$modules sky2";;
        ('8086:7113') ;;
        ('80ee:beef') ;;
        ('80ee:cafe') ;;
        (*) echo "WARNING: unknown pci device: $device";;
    esac
done

if [ "$arg_netconsole" == 'true' ]; then
    modules="$modules netconsole"
fi

if [ "$arg_dropbear" == 'true' ]; then
    modules="$modules libahci ahci ata_piix"
    modules="$modules dm-mod dm-crypt af_alg xts hmac sha1_generic algif_skcipher algif_hash"
    modules="$modules crc32c_generic libcrc32c xfs"
fi

for module in $modules; do
    var="module_${module/-/_}"
    value="$(eval "echo \$$var")"
    if [ -n "${value}" ]; then
        echo "[debug] duplicate module: $module (\$$var='$value')"
        continue
    fi
    eval "$var=true"
    echo "[debug] load module: $module (\$$var='$value')"
    insmod "/lib/modules/${module}.ko" || die "failed to load module: $module"
done
mount -t configfs none /sys/kernel/config || die "failed to mount configfs"

# setup network
# may be network device is not initialized yet
# TODO: replace with udevsettle https://linux.die.net/man/8/udevsettle
tries=10
while :; do
    ip link set dev eth0 up && break
    if [ "$tries" -gt 0 ]; then
        tries=$(($tries-1))
        sleep 1
        continue
    fi
    die "failed to set link 'eth0' up"
done
udhcpc -q -s '/sbin/udhcpc-helper' || die "failed to get dhcp address"

#some extra debug
dmesg -n 8
exec < /dev/null > /dev/kmsg 2>&1

if [ "$arg_netconsole" == 'true' ]; then
    # setup network console
    # use "nc -u -l -p 6666" on host machine to listen
    mkdir /sys/kernel/config/netconsole/target1 || die "failed for make netconsole/target1"
    echo "$arg_netboot_server" > /sys/kernel/config/netconsole/target1/remote_ip || die "failed for configure netconsole/target1"
    echo "1" > /sys/kernel/config/netconsole/target1/enabled || die "failed for turn on netconsole/target1"
fi

export LD_LIBRARY_PATH="/lib"

layer2="-t tmpfs root_tmp"

if [ "$arg_dropbear" == 'true' ]; then

    mkfifo /root/queue
    /bin/dropbear -R -p 220

    while read cmd args; do
        echo "[debug] cmd='$cmd' '$args'"
        if [ "$cmd" == 'boot' ]; then
            layer2="$args"
            break
        fi
    done < /root/queue
fi

# mount real root
echo "mount&copy system"
echo "[debug] \$ sshfs -o ro netboot@\"$arg_netboot_server\":/storage/netboot/raspberry /mount/root1"
sshfs -o ro netboot@"$arg_netboot_server":/storage/netboot/raspberry /mount/root1 || die "failed to mount sshfs"
snapshot='/mount/root1/snapshot.sqfs'
# aufs_xino='/.aufs.xino'
if [ "$arg_copyfile" == 'true' ]; then
    # 400 MiB
    mount -t tmpfs -o size=419430400 file_tmp /mount/root2 || die "failed to mount tmpfs (file)"
    echo "before cp"
    cp -v "$snapshot" '/mount/root2/' || die "failed to copy snapshot file"
    echo "after cp"
    umount /mount/root1 || die "failed to umount sshfs"
    snapshot='/mount/root2/snapshot.sqfs'
    # aufs_xino="/mount/root2/.aufs.xino"
fi
mount -t squashfs "$snapshot" /mount/root3 || die "failed to mount squashfs"
mount $layer2 /mount/root4 || die "failed to mount root ($layer2)"
# mount -t aufs -o br=/mount/root4=rw:/mount/root3=ro -o udba=none -o xino="$aufs_xino" root_aufs /mount/root0 || die "failed to mount aufs"
mkdir /mount/root4/overlay /mount/root4/work || die "failed to make aux dirs for overlay fs"
echo "[debug] \$ mount -t overlay -o lowerdir=/mount/root3,upperdir=/mount/root4/overlay,workdir=/mount/root4/work root_overlay /mount/root0"
mount -t overlay -o lowerdir=/mount/root3,upperdir=/mount/root4/overlay,workdir=/mount/root4/work root_overlay /mount/root0 || die "failed to mount aufs"

# mount --rbind /mount/ /mount/root0/mount/system || die "failed to mount"

# clean up and boot main system
umount /proc /sys/kernel/config /sys || die "failed to umount special fs"
umount -l /dev/ || die "failed to umount /dev"

echo "ready to switch_root"
# die "[debug] stop here"
exec switch_root -c /dev/console /mount/root0 /sbin/init

die "no way"

while :; do
   sleep 1
done

