#!/usr/bin/env bash

set -e

VERSION=$(date +'%y'.'%m')
STORAGE_DIR='manjaro'
PKG_CACHE_DIR="${STORAGE_DIR}/pkg-cache"
RESOURCES_DIR="./resources"
IMG_TEMP_DIR="${STORAGE_DIR}/tmp"
ROOTFS_DIR="${STORAGE_DIR}/rootfs"
ROOTFS_TARBALL='Manjaro-ARM-aarch64-latest.tar.gz'
ROOTFS_DOWNLOAD_URL="https://osdn.net/projects/manjaro-arm/storage/.rootfs/${ROOTFS_TARBALL}"
CUSTOM_KERNEL='linux-rpi4-4.19.122-1-aarch64.pkg.tar.xz'
CUSTOM_KERNEL_HEADERS='linux-rpi4-headers-4.19.122-1-aarch64.pkg.tar.xz'
NETWORK_CONFIG='10-dhcp-eth.network'
NSPAWN="systemd-nspawn -q --resolv-conf=copy-host --timezone=off -D ${ROOTFS_DIR}"
IMG_NAME="Manjaro-ARM-minimal-rpi4-${VERSION}"



build_rootfs() {
    msg "Downloading latest aarch64 rootfs..."
    if [[ ! -f ${ROOTFS_TARBALL} ]]; then
        wget -q --show-progress ${ROOTFS_DOWNLOAD_URL} -O ${ROOTFS_TARBALL}
    fi

    msg "Extracting aarch64 rootfs..."
    rm -rf ${ROOTFS_DIR} && mkdir -p ${ROOTFS_DIR}
    bsdtar -xpf ${ROOTFS_TARBALL} -C ${ROOTFS_DIR}

    msg "Setting up keyrings..."
    ${NSPAWN} pacman-key --init 1> /dev/null 2>&1
    ${NSPAWN} pacman-key --populate archlinux archlinuxarm manjaro manjaro-arm 1> /dev/null 2>&1

    msg "Generating mirrorlist..."
    ${NSPAWN} pacman-mirrors -c China 1> /dev/null 2>&1

    msg "Installing packages..."
    rm -rf ${PKG_CACHE_DIR} && mkdir -p ${PKG_CACHE_DIR}
    mount -o bind ${PKG_CACHE_DIR} ${ROOTFS_DIR}/var/cache/pacman/pkg
    ${NSPAWN} pacman -Syyu base systemd systemd-libs dialog manjaro-arm-oem-install manjaro-system \
                            manjaro-release sudo parted openssh haveged inxi ncdu nano man-pages \
                            man-db ntfs-3g zswap-arm iwd linux-rpi4 linux-rpi4-headers raspberrypi-bootloader \
                            raspberrypi-bootloader-x bootsplash-theme-manjaro bootsplash-systemd \
                            firmware-raspberrypi pi-bluetooth wpa_supplicant brcm-patchram-plus \
                            rpi4-post-install --noconfirm

    msg "Installing other packages(custom add)..."
    ${NSPAWN} pacman -Syyu zsh htop vim wget which git make net-tools dnsutils inetutils iproute2 \
                            sysstat nload lsof --noconfirm

    msg "Installing custom build kernel..."
    cp -ap ${RESOURCES_DIR}/${CUSTOM_KERNEL} ${RESOURCES_DIR}/${CUSTOM_KERNEL_HEADERS} ${ROOTFS_DIR}/var/cache/pacman/pkg/
    ${NSPAWN} pacman -U /var/cache/pacman/pkg/${CUSTOM_KERNEL} --noconfirm
    ${NSPAWN} pacman -U /var/cache/pacman/pkg/${CUSTOM_KERNEL_HEADERS} --noconfirm

    msg "Configure system network..."
    cp -ap ${RESOURCES_DIR}/${NETWORK_CONFIG} ${ROOTFS_DIR}/etc/systemd/network/

    msg "Enabling services..."
    ${NSPAWN} systemctl enable getty.target haveged.service systemd-networkd.service systemd-resolved.service
    ${NSPAWN} systemctl enable sshd.service zswap-arm.service bootsplash-hide-when-booted.service bootsplash-show-on-shutdown.service
    # fix manjaro-arm-oem-install always disable systemd-resolved.service
    echo "systemctl enable systemd-resolved.service" >> ${ROOTFS_DIR}/root/.bash_profile

    msg "Applying overlay for minimal edition..."
    echo "Overlay file, just so each edition has one." > ${ROOTFS_DIR}/overlay.txt

    msg "Setting up system settings..."
    echo "manjaro-arm" | tee --append ${ROOTFS_DIR}/etc/hostname 1> /dev/null 2>&1
    # Enabling SSH login for root user for headless setup...
    sed -i s/"#PermitRootLogin prohibit-password"/"PermitRootLogin yes"/g ${ROOTFS_DIR}/etc/ssh/sshd_config
    sed -i s/"#PermitEmptyPasswords no"/"PermitEmptyPasswords yes"/g ${ROOTFS_DIR}/etc/ssh/sshd_config
    # Enabling autologin for first setup...
    mv ${ROOTFS_DIR}/usr/lib/systemd/system/getty\@.service ${ROOTFS_DIR}/usr/lib/systemd/system/getty\@.service.bak
    cp ${RESOURCES_DIR}/getty\@.service ${ROOTFS_DIR}/usr/lib/systemd/system/getty\@.service

    msg "Correcting permissions from overlay..."
    chown -R root:root ${ROOTFS_DIR}/etc

    msg "Cleaning rootfs for unwanted files..."
    umount ${ROOTFS_DIR}/var/cache/pacman/pkg
    rm -f ${ROOTFS_DIR}/usr/bin/qemu-aarch64-static
    rm -rf ${ROOTFS_DIR}/var/log/*
    rm -rf ${ROOTFS_DIR}/etc/*.pacnew
    rm -rf ${ROOTFS_DIR}/usr/lib/systemd/system/systemd-firstboot.service
    rm -rf ${ROOTFS_DIR}/etc/machine-id

    echo "rpi4 - minimal - ${VERSION}" | tee --append ${ROOTFS_DIR}/etc/manjaro-arm-version 1> /dev/null 2>&1

    msg "rpi4 minimal rootfs complete."
}

create_img() {
    EXTRA_SIZE=300
    SIZE=$(du -s --block-size=MB ${ROOTFS_DIR} | awk '{print $1}' | sed -e 's/MB//g')
    REAL_SIZE=$(echo "$((${SIZE}+${EXTRA_SIZE}))")

    msg "Create blank img file..."
    dd if=/dev/zero of=${IMG_NAME}.img bs=1M count=${REAL_SIZE} 1> /dev/null 2>&1

    msg "Probing loop into the kernel..."
    modprobe loop 1> /dev/null 2>&1

    msg "Set up loop device..."
    LDEV=$(losetup -f)
    DEV=$(echo ${LDEV} | cut -d "/" -f 3)

    msg "Mount image to loop device..."
    losetup ${LDEV} ${IMG_NAME}.img 1> /dev/null 2>&1

    msg "Create partitions..."
    info "Clear first 32mb..."
    dd if=/dev/zero of=${LDEV} bs=1M count=32 1> /dev/null 2>&1

    info "Partition with boot and root..."
    parted -s ${LDEV} mklabel msdos 1> /dev/null 2>&1
    parted -s ${LDEV} mkpart primary fat32 32M 256M 1> /dev/null 2>&1
    START=$(cat /sys/block/${DEV}/${DEV}p1/start)
    SIZE=$(cat /sys/block/${DEV}/${DEV}p1/size)
    END_SECTOR=$(expr ${START} + ${SIZE})
    parted -s ${LDEV} mkpart primary ext4 "${END_SECTOR}s" 100% 1> /dev/null 2>&1
    partprobe ${LDEV} 1> /dev/null 2>&1
    mkfs.vfat "${LDEV}p1" -n BOOT_MNJRO 1> /dev/null 2>&1
    mkfs.ext4 -O ^metadata_csum,^64bit "${LDEV}p2" -L ROOT_MNJRO 1> /dev/null 2>&1

    msg "Copy rootfs contents over to the FS..."
    rm -rf ${IMG_TEMP_DIR} && mkdir ${IMG_TEMP_DIR}
    mkdir -p ${IMG_TEMP_DIR}/root
    mkdir -p ${IMG_TEMP_DIR}/boot
    mount ${LDEV}p1 ${IMG_TEMP_DIR}/boot
    mount ${LDEV}p2 ${IMG_TEMP_DIR}/root
    cp -ra ${ROOTFS_DIR}/* ${IMG_TEMP_DIR}/root/
    mv ${IMG_TEMP_DIR}/root/boot/* ${IMG_TEMP_DIR}/boot

    msg "Cleaning up image..."
    umount ${IMG_TEMP_DIR}/root
    umount ${IMG_TEMP_DIR}/boot
    rm -r ${IMG_TEMP_DIR}/root ${IMG_TEMP_DIR}/boot
    partprobe ${LDEV} 1> /dev/null 2>&1
    losetup -d ${LDEV} 1> /dev/null 2>&1
    chmod 666 ${IMG_NAME}.img
}

msg() {
    ALL_OFF="\e[1;0m"
    BOLD="\e[1;1m"
    GREEN="${BOLD}\e[1;32m"
    local message=${1}; shift
    printf "${GREEN}==>${ALL_OFF}${BOLD} ${message}${ALL_OFF}\n" "$@" >&2
}

info() {
    ALL_OFF="\e[1;0m"
    BOLD="\e[1;1m"
    BLUE="${BOLD}\e[1;34m"
    local message=${1}; shift
    printf "${BLUE}  ->${ALL_OFF}${BOLD} ${message}${ALL_OFF}\n" "$@" >&2
}

build_rootfs
create_img
