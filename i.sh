#!/bin/sh

# SPDX-FileCopyrightText: 2022 XADE
# SPDX-License-Identifier: GPL-3.0-or-later

## FUNCTIONS

# print
PRINT() {
  printf '\n\n\n%s\n\n\n' "$1"
}
# print the script name and all arguments to stderr
YELL() {
  printf '\033[7m\n%s\n\033[m' "($0) FAILED : $1" >&2
}
# YELL and exit
DIE() {
  YELL "$1"
  exit 1
}
# DIE if command fails
TRY() {
  "$@" || DIE "$@"
}
# warn if command fails
WRN() {
  $@ || YELL "$@"
}
# execute command inside chroot environment
EXE() {
  PRINT '' | chroot "${DIR}" sh -c "$1"
}
# show block device info
BLK() {
  lsblk -lspo name,type,fstype,uuid,rm "$@"
}
# add new user
USERADD() {
  PRINT "$1:x:501:501::/home/$1:${SHELL}" >>/etc/passwd
  PRINT "$1::::::::" >>/etc/shadow
  PRINT "$1:x:501:$1" >>/etc/group
}
# substitute string of a file in rootfs
SUB() {
  FILE="${TMP}${1##*/}"
  awk '{gsub("'"$2"'", "'"$3"'", $0);}1' "${DIR}$1" >|"${FILE}"
  cp "${FILE}" "${DIR}$1"
  # usage: SUB <path/to/file> <string> <new_string>
}
# filter out only the matched REGEX according to arguements
FLT() {
  curl -L "$2" | awk -v REGEX="$3" -v AFTER="$4" '$0 ~ AFTER {f=1}f {match($0,REGEX,m); printf substr(m[0],2,length(m[0])-2)" "}' | awk -v FIELD="$1" '{printf $FIELD}' | awk '{printf $NF}'
}
# get the file from provided url
GET() {
  curl -LC - "$1" -o "${FETCHED}"
}
# filter, get and extract file according to arguements
FGE() {
  # get the first file that matches REGEX
  FILE=$(FLT "$@")
  GET "$2/${FILE}" ||
  GET "$6${FILE}" 
  # extract the archive
  TAR="tar -xf ${FETCHED} -C ${DIR}$5"
  ${TAR} --xz   ||
  ${TAR} --gzip ||
  ${TAR} --zstd ||
  DIE "$*"
  # usage : FGE <index of match, "" for last match> <URL> <REGEX to look for> <REGEX to look ahead of> <directory to extract in> <switch domain with>
}
# set the mount point and mount, warn about failure
MNT() {
  # arguements passed
  ARG="$*"
  # last arguement
  LAST=$(printf '%s\n' "${ARG}" | awk '{printf $NF}')
  # arguements before last
  REST=${ARG%%"$LAST"}
  # set the mount point
  MPT="${DIR}${LAST}"
  mkdir -p "${MPT}"
  WRN "mount ${REST} ${MPT}"
}
# prepare devices
PREPARE() {
  # create a directory for carrying out the installation
  mkdir -p "${DIR}"
  # mount the root device
  MNT "${ROOT}" /
  # create a subvolume for rootfs
  WRN "${FS} subvolume create ${DIR}${OS}"
  # unmount root device
  umount -Rl "${DIR}"
  # mount the subvolume on ${DIR}
  mount -o noatime,compress,space_cache=v2,subvol="${OS}" "${ROOT}" "${DIR}" ||
  # mount root device again if it is not a CoW device
  MNT "${ROOT}" /
  # mount necessary dir
  MNT "${FAT}" fat
  MNT -R /sys sys
  MNT -R /dev dev
  MNT -R /run run
  MNT -R /proc proc
  # create needed directories inside rootfs
  mkdir -p "$BOOT" "${DIR}usr/src" "${TMP}" "${DIR}etc/default" "${DIR}etc/mkinitfs" "${DIR}etc/dracut.conf.d" "${DIR}run/shm" /nix /gnu
  # copy content of asset to rootfs/tmp, to from chroot environment
  cp -rp asset/. "${TMP}"
  # remove old grub.cfg
  rm "${BOOT}grub.cfg"
}
# check if grub got installed
CGRB() {
  awk 0 "${BOOT}grubenv"
}
# greet & add grub.cfg to common grub menu
GREET() {
  TRY CGRB
  PRINT "
menuentry '${OS}' {
cryptomount -u $(printf '%s' "${LUID}" | awk '{gsub("-","")}1')
search --set=root --fs-uuid ${RUID}
configfile /${OS}/boot/grub/grub.cfg}
" >>"${DIR}fat/grub.cfg"
  PRINT "${GENTRY}" >"${BOOT}custom.cfg"
  PRINT "INSTALLATION COMPLETE"
}
# chroot and exec scripts
CHROOT() {
  # specify modules to be included inside initramfs, by dracut
  PRINT 'dracutmodules+=" rootfs-block kernel-modules base crypt lvm resume "' >|"${DIR}etc/dracut.conf.d/easy.conf"
  # specify HOOKS to be included inside initramfs, by mkinitcpio
  PRINT "HOOKS=(base udev autodetect modconf block filesystems keyboard fsck keymap lvm2 encrypt resume)" >|"${DIR}etc/mkinitcpio.conf"
  # specify features to be included inside initramfs, by mkinitfs
  PRINT "features=\"base lvm raid cryptsetup resume nvme usb ata ext4 scsi ${FS}\"" >|"${DIR}etc/mkinitfs/mkinitfs.conf"
  # fstab: set of rules to mount devices
  PRINT "
# device  mount-point  fs-type  options      dump pass
UUID=${FUID}  /fat     vfat  rw,noatime,defaults  0 2
" >|"${DIR}etc/fstab"
  # copy the DNS config inside rootfs for network access
  cp /etc/resolv.conf "${DIR}etc/"
  # copy portage config inside rootfs
  cp "${TMP}make.conf" "${DIR}etc/portage/"
  # configure grub [bootloader]
  PRINT "
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_GFXMODE=auto
GRUB_TERMINAL=console
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR=\"${OS}\"
GRUB_ENABLE_CRYPTODISK=y
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_OS_PROBER=false
GRUB_EARLY_INITRD_LINUX_CUSTOM=\"initrd.img\"
GRUB_PRELOAD_MODULES=\"lvm luks luks2 part_gpt cryptodisk gcry_rijndael pbkdf2 gcry_sha256 ${FS}\"
GRUB_CMDLINE_LINUX_DEFAULT=\"root=UUID=${RUID} rd.luks.uuid=${LUID} cryptdevice=UUID=${LUID}:${OS} cryptroot=UUID=${LUID} cryptdm=${OS} rootfstype=${FS}\"
" >|"${DIR}etc/default/grub"
  # steps to install grub
  CGRB || PRINT "
dracut -N -f -m ' rootfs-block kernel-modules base crypt lvm ' /boot/initrd.img --no-kernel
# install for legacy
${GIN}=i386-pc
# install for efi
${GIN}=x86_64-efi --removable
${GIN}=x86_64-efi --bootloader-id=${OS}
grub-mkconfig -o /boot/grub/grub.cfg
" >>"${CHT}"
  # execute chroot script
  EXE "sh /tmp/CHT"
  # execute post script
  EXE "sh /tmp/post.sh"
  # enable signature checking by pacman
  SUB /etc/pacman.conf "Never" "Required DatabaseOptional"
  # empty root passwd
  SUB /etc/shadow "root:.*$" "root::::::::"
  # link init if it's not already
  ln -s "$(printf '%s\n' "${DIR}usr/bin/"*-init | awk -F '/' '{printf $NF; exit}')" "${DIR}usr/bin/init"
}
# installation begins here
MAIN() {

  ## PROMPTS

  # name this installation
  printf "
\033[2J\033[H 
 > NAME      : "
  read -r OS
  # list supported DISTRO IDs
  printf "
[ DISTRO ID ] | [ DISTRO ID ]
--------------+--------------
  ARCH        |   ALPINE
  ARTIX       |   GENTOO
  FUNTOO      |
  GUIX        |   NIXOS 
  VOID        |   VOID -musl

 > DISTRO ID : "
  # choose a distro by DISTRO ID
  read -r DID
  # list the packages to install
  printf "
 > packages  : "
  read -r PKG
  # list supported fat devices
  BLK | awk '/vfat/ {printf "\n\t"$1"\n"}'
  printf "
 > FAT  device : "
  # select fat device for grub
  read -r FAT
  # list devices
  BLK | awk '!/disk/ {printf "\n\t"$1"\n"}'
  printf "
 > ROOT device : "
  # select device for rootfs
  read -r ROOT

  ## VARIABLES

  # new rootfs directory for installation
  DIR="/tmp/${OS}/"
  # directory for grub images
  BOOT="${DIR}boot/grub/"
  # fat mount point
  TMP="${DIR}tmp/"
  # path to save fetched files
  FETCHED="${TMP}FETCHED"
  # chroot script
  CHT="${TMP}CHT"
  # memory
  MEM="0$(awk '/MemAvailable/ {printf $2}' /proc/meminfo)"
  # swap
  SWP="0$(awk 'NR==2 {printf $3}' /proc/swaps)"
  # max possible jobs = {(swap + memory)/3GB}+1GB
  MPJ=$(awk -v MEM="${MEM}" -v SWP="${SWP}" 'BEGIN{printf substr(((MEM+SWP)/3000000)+1,1,1)}')
  # cpu threads
  CPU=$(nproc)
  # feasible number of jobs according to system resources
  JOB=$(awk -v A="${MPJ}" -v B="${CPU}" 'BEGIN{printf (A>=B)*B+(B>A)*A}')
  # detect disk for boot loader installation
  DISK=$(BLK "${FAT}" | awk '/disk/ {printf $1; exit}')
  # LUKS uuid
  LUID=$(BLK "${ROOT}" | awk '/LUKS/ {printf $4; exit}')
  # root uuid
  RUID=$(BLK "${ROOT}" | awk 'NR==2 {printf $4}')
  # rootfs type
  FS=$(BLK "${ROOT}" | awk 'NR==2 {printf $3}')
  # fat uuid
  FUID=$(BLK "${FAT}" | awk 'NR==2 {printf $4}')
  # check if removable drive: empty = not
  RMD=$(lsblk -o rm "${FAT}" | awk '/1/')
  # check efi: empty = not
  CEFI=$(awk 1 /sys/firmware/efi/*)
  # command to install grub [bootloader]
  GIN="grub-install --boot-directory=/boot --efi-directory=/fat ${DISK} --target"
  # mirror to fetch files from
  MIR="https://mirrors.tuna.tsinghua.edu.cn"
  # detect architecture
  ARC=$(uname -m)
  # compression algorithm
  COMP='.*(gz|xz|zst)("|<)'
  # common grub entry
  GENTRY=" 
menuentry 'OTHER' {
search --set=root --fs-uuid ${FUID}
configfile /grub.cfg}
"
  # steps to compile and install kernel
  KIN="
cd /usr/src/linux-*/ || exit 1
cp /tmp/.config ./ || 
make localyesconfig
printf '%s' '
CONFIG_DEBUG_INFO=n
' >> .config
make oldconfig
make
make INSTALL_MOD_STRIP=1 modules_install
make install
"
  # export variable to access them from inside of chroot environment
  export PATH="${PATH}:/bin:/sbin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/run/wrappers/bin:/root/.nix-profile/bin:/etc/profiles/per-user/root/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin" LOGNAME="${OS}" MAKEOPTS="-j${JOB}" MAKEFLAGS="-j${JOB}"
  PREPARE
  # prepare rootfs of specified distro
  ${DID}
  CHROOT
  GREET
}

## DISTRO DEFINITIONS

PACMAN() {
  GET codeberg.org/zz/pacmanstrap/raw/branch/master/pacstrap.sh
  sh "${FETCHED}" "${DIR}" "${MIR}/${1}/${2}/os/x86_64"
  PRINT "
update-ca-trust
pacman -Syu --overwrite '*' pacman ${PKG}
pacman-key --init
pacman-key --populate ${1}
" >|"${CHT}"
}
ARCH() {
  PACMAN "archlinux" "core"
}
ARTIX() {
  PACMAN "artixlinux" "system"
}
ALPINE() {
  FGE 1 "${MIR}/alpine/latest-stable/releases/${ARC}" ">alpine-minirootfs.*[^a-z].-${ARC}${COMP}"
  PRINT "
apk add ${PKG}
" >|"${CHT}"
}
VOID() {
  FGE 1 "${MIR}/voidlinux/live/current" ">void-${ARC}$1-ROOTFS${COMP}"
  PRINT "
rm -rf /var /usr/share/zoneinfo
xbps-install -R ${MIR}/voidlinux/current/ -S ${PKG}
" >|"${CHT}"
}
GENTOO() {
  FGE 1 "${MIR}/gentoo/releases/amd64/autobuilds/current-stage3-amd64-hardened-openrc" ">stage3-amd64-hardened-openrc${COMP}"
  PRINT "
mkdir -p /etc/portage/repos.conf
cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf
emerge-webrsync
env-update
. /etc/profile
USE=\"device-mapper\" emerge -uqDN --exclude=rust --autounmask-continue=y --autounmask-license=y --keep-going ${PKG}
${KIN}
" >|"${CHT}"
}
FUNTOO() {
  FGE 1 "build.funtoo.org/next/x86-64bit/generic_64" ">stage3${COMP}"
  PRINT "
ego sync
USE=\"device-mapper\" emerge -uqDN --exclude=rust --autounmask-continue=y --autounmask-license=y --keep-going ${PKG}
${KIN}
" >|"${CHT}"
}
NIXOS() {
  USERADD "nixbld"
  GET nixos.org/nix/install
  sh "${FETCHED}"
  . "${HOME}/.nix-profile/etc/profile.d/nix.sh"
  nix-channel --add "${MIR}/nix-channels/nixos-unstable" nixpkgs
  nix-channel --update
  nix-env -f '<nixpkgs>' -iA nixos-install-tools
  nixos-generate-config --root "${DIR}"
  PRINT "
{ config, pkgs, ... }:
{
 imports = [ ./hardware-configuration.nix ];
 boot.loader = {
    grub = {
      enable = true;
      device = \"${DISK}\";
      efiSupport = true;
      useOSProber = true;
      enableCryptodisk = true;
      ${RMD:+efiInstallAsRemovable = true;}
      extraEntries = ''${GENTRY}'';
    };
    efi = {
      efiSysMountPoint = \"/fat\";
      ${RMD:-canTouchEfiVariables = true;}
    };
 };
 networking.nameservers = [ \"9.9.9.9\" ];
 environment.systemPackages = with pkgs; [ ${PKG} ];
 system.stateVersion = \"21.11\"; # Do not modify, before going through the manual.
}
" >|"${DIR}etc/nixos/configuration.nix"
  TRY PRINT '' | nixos-install --root "${DIR}"
}
GUIX() {
  USERADD "guixbuild"
  FGE "" "https://ftp.gnu.org/gnu/guix/" ">guix-binary.*${ARC}${COMP}"
  cp -rp "${DIR}gnu" "${DIR}var" /
  GP="/var/guix/profiles/per-user/root/current-guix"
  . "${GP}/etc/profile"
  guix-daemon --build-users-group=guixbuild &
  guix archive --authorize <"${GP}/share/guix/ci.guix.gnu.org.pub"
  guix archive --authorize <"${GP}/share/guix/bordeaux.guix.gnu.org.pub"
  PRINT "
(use-modules (gnu))
(use-service-modules networking)
(define (append-to-computed-file g text)
  #~(begin
      #\$g
      (let ((port (open-file #\$output \"a\")))
        (format port #\$text)
        (close port))))
(define %grub-other_entries \"${GENTRY}\")
(define* (grub-conf-with-custom-part fn)
  (lambda* (#:rest r)
    (let ((grubcfg-computed-file (apply fn r)))
      (computed-file
       (computed-file-name grubcfg-computed-file)
       (append-to-computed-file
        (computed-file-gexp grubcfg-computed-file)
        (string-append
         %grub-other_entries))
       #:options (computed-file-options grubcfg-computed-file)))))
(operating-system
  (host-name \"${OS}\")
  (bootloader (bootloader-configuration
    (bootloader (bootloader 
      (inherit grub-${CEFI:+efi-${RMD:+removable-}}bootloader)
      (configuration-file-generator
        (grub-conf-with-custom-part
        (bootloader-configuration-file-generator grub-${CEFI:+efi-${RMD:+removable-}}bootloader)))))
    (targets (list ${CEFI:+\"/fat\"} \"${DISK}\"))))
  (mapped-devices (list 
    (mapped-device
      (source (uuid \"${LUID:-\"\"}\"))
      (target \"${OS}\")
      (type luks-device-mapping))))
  (file-systems 
    (append (list
      (file-system
        (device (uuid \"${RUID}\"))
        (mount-point \"/\")
        (type \"${FS}\")
        (options \"subvol=${OS}\")
        ${LUID:+(dependencies mapped-devices)})
      (file-system
        (device (uuid \"${FUID}\" 'fat))
        (mount-point \"/fat\")
        (type \"vfat\")))
        %base-file-systems))
  (packages (append (map specification->package
                         '(${PKG}))
                    %base-packages))
  (services
    (append (list 
      (service dhcp-client-service-type))
      %base-services)))
" >|"${DIR}etc/config.scm"
  TRY PRINT '' | guix system init "${DIR}etc/config.scm" "${DIR}"
}

## CHECK REQUIREMENTS and START INSTALLATION

TRY chroot / sh -c "type gawk curl btrfs tar xz gzip zstd dmsetup mount lsblk"
MAIN
