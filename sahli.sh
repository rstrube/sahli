#!/bin/bash
# Simple Arch Hyprland Installer

# Configuration
#################################################

# HD Configuration
# Run "lsblk" to determine HD device name
# To check for TRIM support, run "lsblk --discard". If DISC-GRAN && DISC-MAX are > 0, your HD supports TRIM.
# If running as VM, you'll need to double check if TRIM is supported.  Newer KVM/Qemu VMs should support TRIM.
HD_DEVICE="" # /dev/sda /dev/nvme0n1 /dev/vda
TRIM_SUPPORT="true" # typically set to true if HD is an SSD, see notes above
SWAPFILE_SIZE="2048" # 4096 8912 (in MiB)

# CPU Configuration
# Note: if installing in a VM leave both set to 'false'
AMD_CPU="false"
INTEL_CPU="false"

# GPU Configuration
AMD_GPU="false"
INTEL_GPU="false"
NVIDIA_GPU="false"

# Hostname to ping to check network connection
PING_HOSTNAME="www.google.com"

# Hostname Configuration
HOSTNAME="sahli"

# Locale Configuration
# To list out all timezones in a given region run "ls -l /usr/share/zoneinfo/{region}" e.g. "ls -l /usr/share/zoneinfo/America"
# To list out all timezones run "timedatectl list-timezones"
# To examine available locales look in /etc/locale.gen, first column is used for LANG, both columns together are used for LOCALE
KEYS="us"
TIMEZONE="/usr/share/zoneinfo/America/Denver"
LOCALE="en_US.UTF-8 UTF-8"
LANG="en_US.UTF-8"

# TTY Font (Default: Terminus 24px bold)
TTY_FONT="ter-124b" #ter-124n #ter-128b #ter-128n #ter-132b #ter-132n

# Reflector Configuration
REFLECTOR_COUNTRY="United States"

# User Configuration
ROOT_PASSWORD=""
USER_NAME=""
USER_PASSWORD=""

# Additional Linux Command Line Params
CMDLINE_LINUX="" #"msr.allow_writes=on"

# Uncomment to enable the installation log
LOG_FILE="sahli.log"

# Installation Scripts
#################################################

function main() {
    check_critical_prereqs
    check_variables
    check_conflicts
    check_network

    loadkeys $KEYS

    confirm_install
    install
}

function install() {

    echo_to_log "=========================================="
    echo_to_log "1. System clock and initial reflector pass"
    echo_to_log "=========================================="
    # Update system clock
    timedatectl set-ntp true

    # Select the fastest pacman mirrors
    reflector --verbose --country "$REFLECTOR_COUNTRY" --latest 25 --sort rate --save /etc/pacman.d/mirrorlist

    echo_to_log "================================="
    echo_to_log "2. HD partitioning and formatting"
    echo_to_log "================================="
    # Partion the drive with a single 512 MB ESP partition, and the rest of the drive as the root partition
    parted -s $HD_DEVICE mklabel gpt mkpart ESP fat32 1MiB 512MiB mkpart root ext4 512MiB 100% set 1 esp on

    # Is the the hard drive an NVME SSD?
    if [[ -n "$(echo $HD_DEVICE | grep "^/dev/nvme")" ]]; then
        local BOOT_PARTITION="${HD_DEVICE}p1"
        local ROOTFS_PARTITION="${HD_DEVICE}p2"
    else
        local BOOT_PARTITION="${HD_DEVICE}1"
        local ROOTFS_PARTITION="${HD_DEVICE}2"
    fi

    # Create the filesystem for the ESP partition
    mkfs.fat -n ESP -F32 $BOOT_PARTITION

    # Create the filesystem for the root partition
    yes | mkfs.ext4 -L ROOT $ROOTFS_PARTITION

    # Mount the root partition
    mount -o defaults,noatime $ROOTFS_PARTITION /mnt

    # Create directory to support mounting ESP
    mkdir /mnt/boot

    # Mount the ESP partition
    mount -o defaults,noatime $BOOT_PARTITION /mnt/boot

    # Build out swapfile
    local SWAPFILE="/swapfile"
    fallocate --length ${SWAPFILE_SIZE}MiB /mnt"$SWAPFILE"
    chown root /mnt"$SWAPFILE"
    chmod 600 /mnt"$SWAPFILE"
    mkswap /mnt"$SWAPFILE"

    echo_to_log "====================================="
    echo_to_log "3. Initial pacstrap and core packages"
    echo_to_log "====================================="
    # Force a refresh of the archlinux-keyring package for the arch installation environment
    pacman -Sy --noconfirm --noprogressbar archlinux-keyring | tee -a "$LOG_FILE"

    # Bootstrap new environment (base)
    pacstrap /mnt

    # Install essential packages
    arch-chroot /mnt pacman -S --noconfirm --needed --noprogressbar \
        base-devel              `# Core development libraries (gcc, etc.)` \
        linux linux-headers     `# Linux kernel and headers` \
        linux-firmware          `# Linux firmawre` \
        fwupd                   `# Support for updating firmware from Linux Vendor Firmware Service [https://fwupd.org/]` \
        man-db man-pages        `# man pages` \
        texinfo                 `# GUN documentation format` \
        dosfstools exfatprogs   `# Tools and utilities for FAT and exFAT filesystems` \
        e2fsprogs               `# Tools and utiltiies for ext filesystems` \
        networkmanager          `# Networkmanager` \
        git                     `# Git` \
        vim                     `# Text editor` \
        cpupower                `# Tool for managing your CPU frequency and governor` \
        reflector               `# Utility to manage pacman mirrors` \
        terminus-font           `# Terminus font for tty` \
        | tee -a "$LOG_FILE"

    # Install additional firmware and uCode
    if [[ "$AMD_CPU" == "true" ]]; then
        arch-chroot /mnt pacman -S --noconfirm --needed --noprogressbar linux-firmware amd-ucode | tee -a "$LOG_FILE"
        local MICROCODE="amd-ucode.img"

    elif [[ "$INTEL_CPU" == "true" ]]; then
        arch-chroot /mnt pacman -S --noconfirm --needed --noprogressbar linux-firmware intel-ucode | tee -a "$LOG_FILE"
        local MICROCODE="intel-ucode.img"
    fi

    echo_to_log "============================"
    echo_to_log "4. Core system configuration"
    echo_to_log "============================"
    # Enable systemd-resolved local caching DNS provider
    # Note: NetworkManager uses systemd-resolved by default
    arch-chroot /mnt systemctl enable systemd-resolved.service

    # Enable NetworkManager.service
    # Note: NetworkManager will handle DHCP
    arch-chroot /mnt systemctl enable NetworkManager.service

    # Enable bluetooth.service
    arch-chroot /mnt systemctl enable bluetooth.service

    # Configure color support for pacman
    arch-chroot /mnt sed -i 's/#Color/Color/' /etc/pacman.conf

    # Enable multilib
    arch-chroot /mnt sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
    arch-chroot /mnt pacman -Syyu --noprogressbar | tee -a "$LOG_FILE"

    # Generate initial fstab using UUIDs
    genfstab -U /mnt > /mnt/etc/fstab

    # Create a dedicated entry for swapfile
    echo "# swapfile" >> /mnt/etc/fstab
    echo "$SWAPFILE none swap defaults 0 0" >> /mnt/etc/fstab
    echo "" >> /mnt/etc/fstab

    # Configure swappiness paramater (default=60) to improve system responsiveness
    echo "vm.swappiness=10" > /mnt/etc/sysctl.d/99-sysctl.conf

    # Enable periodic trim if the HD supports TRIM
    if [[ "$TRIM_SUPPORT" == "true" ]]; then
        arch-chroot /mnt systemctl enable fstrim.timer
    fi

    # Configure timezone and system clock
    arch-chroot /mnt ln -s -f $TIMEZONE /etc/localtime
    arch-chroot /mnt hwclock --systohc

    # Configure locale
    arch-chroot /mnt sed -i "s/#$LOCALE/$LOCALE/" /etc/locale.gen
    arch-chroot /mnt locale-gen
    echo -e "LANG=$LANG" >> /mnt/etc/locale.conf

    # Configure keymap and font for virtual console (tty)
    echo -e "KEYMAP=$KEYS" > /mnt/etc/vconsole.conf
    echo -e "FONT=$TTY_FONT" >> /mnt/etc/vconsole.conf 

    # Configure hostname and hosts files
    echo $HOSTNAME > /mnt/etc/hostname
    echo "127.0.0.1	localhost" >> /mnt/etc/hosts
    echo "::1 localhost" >> /mnt/etc/hosts
    echo "127.0.0.1	${HOSTNAME}.localdomain $HOSTNAME" >> /mnt/etc/hosts

    # Configure root password
    printf "$ROOT_PASSWORD\n$ROOT_PASSWORD" | arch-chroot /mnt passwd

    # Configure reflector
    echo "--save /etc/pacman.d/mirrorlist" > /mnt/etc/xdg/reflector/reflector.conf
    echo "--country \"$REFLECTOR_COUNTRY\"" >> /mnt/etc/xdg/reflector/reflector.conf
    echo "--protocol https" >> /mnt/etc/xdg/reflector/reflector.conf
    echo "--latest 15" >> /mnt/etc/xdg/reflector/reflector.conf
    echo "--sort rate" >> /mnt/etc/xdg/reflector/reflector.conf

    echo_to_log "=========================================="
    echo_to_log "5. Bootloader configuration (systemd-boot)"
    echo_to_log "=========================================="
    # Add KMS if using a NVIDIA GPU
    if [[ "$NVIDIA_GPU" == "true" ]]; then
        CMDLINE_LINUX="$CMDLINE_LINUX nvidia-drm.modeset=1"
    fi

    CMDLINE_LINUX=$(trim_variable "$CMDLINE_LINUX")

    # Standard hooks for /etc/mkinitcpio.conf with systemd boot support
    local MKINITCPIO_HOOKS="base systemd autodetect keyboard sd-vconsole modconf block fsck filesystems"

    # Modules for /etc/mkinitcpio.conf based on GPU
    if [[ "$INTEL_GPU" == "true" ]]; then
        local MKINITCPIO_MODULES="i915"
    fi

    if [[ "$AMD_GPU" == "true" ]]; then
        local MKINITCPIO_MODULES="amdgpu"
    fi
    
    if [[ "$NVIDIA_GPU" == "true" ]]; then
        local MKINITCPIO_MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
    fi

    # Update /etc/mkinitcpio.conf with hooks and modules
    arch-chroot /mnt sed -i "s/^HOOKS=(.*)$/HOOKS=($MKINITCPIO_HOOKS)/" /etc/mkinitcpio.conf
    arch-chroot /mnt sed -i "s/^MODULES=(.*)$/MODULES=($MKINITCPIO_MODULES)/" /etc/mkinitcpio.conf

    # Need to rebuild the initramfs after updating hooks and modules
    arch-chroot /mnt mkinitcpio -P

    # Note: removing grub support for now, standardizing on systemd-boot
    #if [[ "$BOOTLOADER" == "grub" ]]; then

        # Install and configure Grub as bootloader on ESP
        #arch-chroot /mnt pacman -S --noconfirm --needed grub efibootmgr

        #arch-chroot /mnt sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="'"$CMDLINE_LINUX"'"/' /etc/default/grub

        # Note: the '--removable' switch will also setup grub on /boot/EFI/BOOT/BOOTX64.EFI (which is the Windows default location)
        # This is neccessary because many BIOSes don't honor efivars correctly
        #arch-chroot /mnt grub-install --target=x86_64-efi --bootloader-id=grub --efi-directory=/boot --recheck --removable
        #arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

    #elif [[ "$BOOTLOADER" == "systemd" ]]; then
        
        # Get the UUID for the root partition
        local UUID_ROOTFS_PARTITION=$(blkid -s UUID -o value "$ROOTFS_PARTITION")
        local CMDLINE_LINUX_ROOT="root=UUID=$UUID_ROOTFS_PARTITION"

        arch-chroot /mnt systemd-machine-id-setup
        arch-chroot /mnt bootctl install

        arch-chroot /mnt mkdir -p /boot/loader
        arch-chroot /mnt mkdir -p /boot/loader/entries

        # Main systemd-boot config
        echo "timeout 5" >> "/mnt/boot/loader/loader.conf"
        echo "default archlinux.conf" >> "/mnt/boot/loader/loader.conf"
        echo "editor 1" >> "/mnt/boot/loader/loader.conf"

        # Config for normal boot
        echo "title Arch Linux" >> "/mnt/boot/loader/entries/archlinux.conf"
        echo "efi /vmlinuz-linux" >> "/mnt/boot/loader/entries/archlinux.conf"
        if [ -n "$MICROCODE" ]; then
            echo "initrd /$MICROCODE" >> "/mnt/boot/loader/entries/archlinux.conf"
        fi
        echo "initrd /initramfs-linux.img" >> "/mnt/boot/loader/entries/archlinux.conf"
        echo "options initrd=initramfs-linux.img $CMDLINE_LINUX_ROOT rw $CMDLINE_LINUX" >> "/mnt/boot/loader/entries/archlinux.conf"

        # Config for booting into terminal only
        echo "title Arch Linux (terminal)" >> "/mnt/boot/loader/entries/archlinux-terminal.conf"
        echo "efi /vmlinuz-linux" >> "/mnt/boot/loader/entries/archlinux-terminal.conf"
        if [ -n "$MICROCODE" ]; then
            echo "initrd /$MICROCODE" >> "/mnt/boot/loader/entries/archlinux-terminal.conf"
        fi
        echo "initrd /initramfs-linux.img" >> "/mnt/boot/loader/entries/archlinux-terminal.conf"
        echo "options initrd=initramfs-linux.img $CMDLINE_LINUX_ROOT rw $CMDLINE_LINUX systemd.unit=multi-user.target" >> "/mnt/boot/loader/entries/archlinux-terminal.conf"

        # Config for fallback boot (uses old initramfs)
        echo "title Arch Linux (fallback)" >> "/mnt/boot/loader/entries/archlinux-fallback.conf"
        echo "efi /vmlinuz-linux" >> "/mnt/boot/loader/entries/archlinux-fallback.conf"
        if [ -n "$MICROCODE" ]; then
            echo "initrd /$MICROCODE" >> "/mnt/boot/loader/entries/archlinux-fallback.conf"
        fi
        echo "initrd /initramfs-linux-fallback.img" >> "/mnt/boot/loader/entries/archlinux-fallback.conf"
        echo "options initrd=initramfs-linux-fallback.img $CMDLINE_LINUX_ROOT rw $CMDLINE_LINUX" >> "/mnt/boot/loader/entries/archlinux-fallback.conf"

    #fi

    echo "======================"
    echo "6. User configuration"
    echo "======================"
    # Setup user and allow user to use "sudo"
    arch-chroot /mnt useradd -m -G wheel,storage,optical -s /bin/bash $USER_NAME
    printf "$USER_PASSWORD\n$USER_PASSWORD" | arch-chroot /mnt passwd $USER_NAME
    arch-chroot /mnt sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    echo_to_log "=================================="
    echo_to_log "7. DE & audio system configuration"
    echo_to_log "=================================="
    # Install all prereqs for labwc
    arch-chroot /mnt pacman -S --noconfirm --needed \
        xdg-user-dirs               `# Standard directories under home (e.g. Documents, Pictures, etc.)` \
        wlroots                     `# wlroots` \
        xorg-xwayland               `# Xwayland support` \
        pipewire wireplumber        `# Pipewire and wireplumber session manager` \
        pipewire-pulse              `# Pipewire drop in replacement for PulseAudio` \
        pipewire-jack               `# Pipewire JACK support` \
        pamixer                     `# Commandline utility for controlling volume (PulseAudio)` \
        brightnessctl               `# Commandline utility for conrolling screen brightness ` \
        xdg-desktop-portal          `# Support for screensharing in pipewire for wlroots compositors` \
        xdg-desktop-portal-wlr \
        polkit-kde-agent            `# Used to prompt for elevated credentials when neccessary` \
        slurp grim                  `# Commandline utils for: setting bg, idle handling, selecting display, and screenshots` \
        mako                        `# Notification daemon` \
        qt5-wayland qt6-wayland     `# Explicit support for running Qt apps under wayland` \
        kitty                       `# Kitty terminal` \
        firefox                     `# Browser ` \
        thunar                      `# Thunar file manager` \
        gvfs                        `# Gnome Virtual Filesystem for additional mount support (smb,mtp, etc.)` \
        thunar-archive-plugin       `# Additional thunar plugins` \
        thunar-media-tags-plugin \
        thunar-volman \
        tumbler \
        ttf-liberation              `# Liberation fonts` \
        noto-fonts noto-fonts-emoji `# Noto fonts to support emojis` \
        gst-plugin-pipewire         `# Additional GStreamer plugins` \
        gst-libav \
        gst-plugins-base \
        gst-plugins-good \
        gst-plugins-bad \
        gst-plugins-ugly \
        gstreamer-vaapi \
        rust                        `# Rust for paru AUR helper` \
        | tee -a "$LOG_FILE"

    # Generate standard XDG user directories
    arch-chroot -u $USER_NAME /mnt xdg-user-dirs-update

    # Note: systemctl enable --user doesn't work via arch-chroot, performing manual creation of symlinks
    # systemctl enable --user --now pipewire.service
    # systemctl enable --user --now pipewire-pulse.service
    arch-chroot -u $USER_NAME /mnt mkdir -p /home/${USER_NAME}/.config/systemd/user/default.target.wants
    arch-chroot -u $USER_NAME /mnt mkdir -p /home/${USER_NAME}/.config/systemd/user/sockets.target.wants

    arch-chroot -u $USER_NAME /mnt ln -s /usr/lib/systemd/user/pipewire.service /home/${USER_NAME}/.config/systemd/user/default.target.wants/pipewire.service
    arch-chroot -u $USER_NAME /mnt ln -s /usr/lib/systemd/user/pipewire.socket /home/${USER_NAME}/.config/systemd/user/sockets.target.wants/pipewire.socket

    arch-chroot -u $USER_NAME /mnt ln -s /usr/lib/systemd/user/pipewire-pulse.service /home/${USER_NAME}/.config/systemd/user/default.target.wants/pipewire-pulse.service
    arch-chroot -u $USER_NAME /mnt ln -s /usr/lib/systemd/user/pipewire-pulse.socket /home/${USER_NAME}/.config/systemd/user/sockets.target.wants/pipewire-pulse.socket

    # systemctl enable --user --now wireplumber.service
    arch-chroot -u $USER_NAME /mnt mkdir -p /home/${USER_NAME}/.config/systemd/user/pipewire.service.wants

    arch-chroot -u $USER_NAME /mnt ln -s /usr/lib/systemd/user/wireplumber.service /home/${USER_NAME}/.config/systemd/user/pipewire-session-manager.service
    arch-chroot -u $USER_NAME /mnt ln -s /usr/lib/systemd/user/wireplumber.service /home/${USER_NAME}/.config/systemd/user/pipewire.service.wants/wireplumber.service


    echo_to_log "===================="
    echo_to_log "8. GPU Configuration"
    echo_to_log "===================="
    # Install GPU Drivers
    COMMON_VULKAN_PACKAGES="vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools"

    # Drivers for VM guest installations
    if [[ "$INTEL_GPU" == "false" && "$AMD_GPU" == "false" && "$NVIDIA_GPU" == "false" ]]; then
        arch-chroot /mnt pacman -S --noconfirm --needed --noprogressbar $COMMON_VULKAN_PACKAGES mesa lib32-mesa | tee -a "$LOG_FILE"
    fi
    
    if [[ "$INTEL_GPU" == "true" ]]; then
        # Note: installing newer intel-media-driver (iHD) instead of libva-intel-driver (i965)
        # Intel drivers only supports VA-API
        arch-chroot /mnt pacman -S --noconfirm --needed --noprogressbar $COMMON_VULKAN_PACKAGES mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver libva-utils | tee -a "$LOG_FILE"
        arch-chroot /mnt echo "LIBVA_DRIVER_NAME=iHD" >> /etc/environment
    fi

    if [[ "$AMD_GPU" == "true" ]]; then
        # AMDGPU supports both VA-API and VDPAU, but we're only installing support for VA-API
        arch-chroot /mnt pacman -S --noconfirm --needed --noprogressbar $COMMON_VULKAN_PACKAGES mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver lib32-libva-mesa-driver libva-utils | tee -a "$LOG_FILE"
        arch-chroot /mnt echo "LIBVA_DRIVER_NAME=radeonsi" >> /etc/environment
    fi
    
    if [[ "$NVIDIA_GPU" == "true" ]]; then
        arch-chroot /mnt pacman -S --noconfirm --needed --noprogressbar $COMMON_VULKAN_PACKAGES nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings | tee -a "$LOG_FILE"

        # Configure pacman to rebuild the initramfs each time the nvidia package is updated
        configure_pacman_nvidia_hook
    fi

    echo_to_log "===================="
    echo_to_log "9. AUR configuration"
    echo_to_log "===================="
    # Install AUR helper
    install_aur_helper

    # Install AUR packages
    # exec_as_user "paru -S --noconfirm --needed --noprogressbar xxx"

    # Install labwc and other important utilities via AUR
    exec_as_user "paru -S --noconfirm --needed --noprogressbar hyprland waybar-hyprland-git network-manager-applet ttf-nerd-fonts-symbols-1000-em | tee -a $LOG_FILE"

    # Install additional fonts to make everything look consistent
    arch-chroot /mnt pacman -S --noconfirm --needed --noprogressbar ttf-roboto ttf-roboto-mono | tee -a "$LOG_FILE"
    
    echo_to_log "==========================="
    echo_to_log "10. Additional pacman hooks"
    echo_to_log "==========================="
    # Configure pacman hook for upgrading pacman-mirrorlist package
    configure_pacman_mirrorupgrade_hook

    # Configure pacman hook for updating systemd-boot when systemd is updated
    configure_pacman_systemd_boot_hook

    echo_to_log "========================================="
    echo_to_log "11. Clone repo for additional ingredients"
    echo_to_log "========================================="
    # Clone sagi git repo so that user can run post-install recipe
    arch-chroot -u $USER_NAME /mnt git clone https://github.com/rstrube/sahli.git /home/${USER_NAME}/sahli

    if [ -n "$LOG_FILE" ]; then
        cp ./${LOG_FILE} /mnt/home/${USER_NAME}/
    fi

    echo -e "${LBLUE}Installation has completed! Run 'reboot' to reboot your machine.${NC}"
}

function echo_to_log()
{
    echo "$@" 
    echo "$@" >> "$LOG_FILE"
}

function check_critical_prereqs() {
    check_variables_value "HD_DEVICE" "$HD_DEVICE"
    
    if [[ ! -e "$HD_DEVICE" ]]; then
        echo -e "${RED}Error: HD_DEVICE="$HD_DEVICE" does not exist.${NC}"
        exit 1
    fi

    if [[ ! -d /sys/firmware/efi ]]; then
        echo -e "${RED}Error: installation can only be run on UEFI systems.${NC}"
        echo "If running in a VM, make sure the VM is configured to use UEFI instead of BIOS."
        exit 1
    fi
}

function check_variables() {
    check_variables_value "HD_DEVICE" "$HD_DEVICE"
    check_variables_boolean "TRIM_SUPPORT" "$TRIM_SUPPORT"
    check_variables_value "SWAPFILE_SIZE" "$SWAPFILE_SIZE"
    check_variables_boolean "AMD_CPU" "$AMD_CPU"
    check_variables_boolean "INTEL_CPU" "$INTEL_CPU"
    check_variables_boolean "AMD_GPU" "$AMD_GPU"
    check_variables_boolean "INTEL_GPU" "$INTEL_GPU"
    check_variables_boolean "NVIDIA_GPU" "$NVIDIA_GPU"
    check_variables_value "PING_HOSTNAME" "$PING_HOSTNAME"
    check_variables_value "HOSTNAME" "$HOSTNAME"
    check_variables_value "TIMEZONE" "$TIMEZONE"
    check_variables_value "KEYS" "$KEYS"
    check_variables_value "LOCALE" "$LOCALE"
    check_variables_value "LANG" "$LANG"
    check_variables_value "REFLECTOR_COUNTRY" "$REFLECTOR_COUNTRY"
    check_variables_value "ROOT_PASSWORD" "$ROOT_PASSWORD"
    check_variables_value "USER_NAME" "$USER_NAME"
    check_variables_value "USER_PASSWORD" "$USER_PASSWORD"
}

ERROR_VARS_MESSAGE="${RED}Error: you must edit sagi.sh (e.g. with vim) and configure the required variables.${NC}"

function check_variables_value() {
    local NAME=$1
    local VALUE=$2
    if [[ -z "$VALUE" ]]; then
        echo -e $ERROR_VARS_MESSAGE
        echo "$NAME must have a value."
        exit 1
    fi
}

function check_variables_boolean() {
    local NAME=$1
    local VALUE=$2
    case $VALUE in
        true )
            ;;
        false )
            ;;
        * )
            echo -e $ERROR_VARS_MESSAGE
            echo "$NAME must be {true|false}."
            exit 1
            ;;
    esac
}

function trim_variable() {
    local VARIABLE="$1"
    local VARIABLE=$(echo "$VARIABLE" | sed 's/^[[:space:]]*//') # trim leading
    local VARIABLE=$(echo "$VARIABLE" | sed 's/[[:space:]]*$//') # trim trailing
    echo "$VARIABLE"
}

function print_variables_value() {
    local NAME=$1
    local VALUE=$2
    echo -e "$NAME = ${WHITE}${VALUE}${NC}"
}

function print_variables_boolean() {
    local NAME=$1
    local VALUE=$2
    if [[ "$VALUE" == "true" ]]; then
        echo -e "$NAME = ${GREEN}${VALUE}${NC}"
    else
        echo -e "$NAME = ${RED}${VALUE}${NC}"
    fi
}

function check_conflicts() {
    if [[ "$AMD_CPU" == "true" && "$INTEL_CPU" == "true" ]]; then
        echo -e "${RED}Error: AMD_CPU and INTEL_CPU are mutually exclusve and can't both be set to 'true'.${NC}"
        exit 1
    fi
}

function check_network() {
    ping -c 1 -i 2 -W 5 -w 30 $PING_HOSTNAME
    
    if [ $? -ne 0 ]; then
        echo "Error: Network ping check failed. Cannot continue."
        exit 1
    fi
}

function confirm_install() {
    clear

    echo -e "${LBLUE}Sagi (Simple Arch Labwc Installer)${NC}"
    echo ""
    echo -e "${RED}Warning"'!'"${NC}"
    echo -e "${RED}This script will destroy all data on ${HD_DEVICE}${NC}"
    echo ""

    echo -e "${LBLUE}HD Configuration:${NC}"
    print_variables_value "HD_DEVICE" "$HD_DEVICE"
    print_variables_boolean "TRIM_SUPPORT" "$TRIM_SUPPORT"
    print_variables_value "SWAPFILE_SIZE" "$SWAPFILE_SIZE"
    echo ""

    echo -e "${LBLUE}CPU Configuration:${NC}"
    print_variables_boolean "AMD_CPU" "$AMD_CPU"
    print_variables_boolean "INTEL_CPU" "$INTEL_CPU"
    echo ""

    echo -e "${LBLUE}GPU Configuration:${NC}"
    print_variables_boolean "AMD_GPU" "$AMD_GPU"
    print_variables_boolean "INTEL_GPU" "$INTEL_GPU"
    print_variables_boolean "NVIDIA_GPU" "$NVIDIA_GPU"
    echo ""

    echo -e "${LBLUE}Host Configuration:${NC}"
    print_variables_value "HOSTNAME" "$HOSTNAME"
    print_variables_value "TIMEZONE" "$TIMEZONE"
    print_variables_value "KEYS" "$KEYS"
    print_variables_value "LOCALE" "$LOCALE"
    print_variables_value "LANG" "$LANG"
    print_variables_value "REFLECTOR_COUNTRY" "$REFLECTOR_COUNTRY"
    echo ""

    echo -e "${LBLUE}User Configuration:${NC}"
    print_variables_value "ROOT_PASSWORD" "$ROOT_PASSWORD"
    print_variables_value "USER_NAME" "$USER_NAME"
    print_variables_value "USER_PASSWORD" "$USER_PASSWORD"
    echo ""

    echo -e "${LBLUE}Linux Command Line Params:${NC}"
    print_variables_value "CMDLINE_LINUX" "$CMDLINE_LINUX"
    echo ""

    read -p "Do you want to continue? [y/N] " yn
    case $yn in
        [Yy]* )
            ;;
        [Nn]* )
            exit
            ;;
        * )
            exit
            ;;
    esac
    echo ""
}

function install_aur_helper() {
    local COMMAND="rm -rf /home/$USER_NAME/.paru-makepkg && mkdir -p /home/$USER_NAME/.paru-makepkg && cd /home/$USER_NAME/.paru-makepkg && git clone https://aur.archlinux.org/paru.git && (cd paru && makepkg -si --noconfirm) && rm -rf /home/$USER_NAME/.paru-makepkg"
    exec_as_user "$COMMAND"
}

function exec_as_user() {
    local COMMAND="$1"
    arch-chroot /mnt sed -i 's/^%wheel ALL=(ALL:ALL) ALL$/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
    arch-chroot /mnt bash -c "echo -e \"$USER_PASSWORD\n$USER_PASSWORD\n$USER_PASSWORD\n$USER_PASSWORD\n\" | su $USER_NAME -s /usr/bin/bash -c \"$COMMAND\""
    arch-chroot /mnt sed -i 's/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL$/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
}

function configure_pacman_systemd_boot_hook() {	
    if [[ ! -d "/mnt/etc/pacman.d/hooks" ]]; then	
        arch-chroot /mnt mkdir -p /etc/pacman.d/hooks	
    fi	

    cat <<EOT > "/mnt/etc/pacman.d/hooks/sytemd-boot.hook"
[Trigger]
Type=Package
Operation=Upgrade
Target=systemd

[Action]
Description=Gracefully upgrading systemd-boot...
When=PostTransaction
Exec=/usr/bin/systemctl restart systemd-boot-update.service
EOT

}

function configure_pacman_mirrorupgrade_hook() {	
    if [[ ! -d "/mnt/etc/pacman.d/hooks" ]]; then	
        arch-chroot /mnt mkdir -p /etc/pacman.d/hooks	
    fi	

    cat <<EOT > "/mnt/etc/pacman.d/hooks/mirrorupgrade.hook"	
[Trigger]
Operation=Upgrade
Type=Package
Target=pacman-mirrorlist

[Action]
Description=Updating pacman-mirrorlist with reflector and removing pacnew...
When=PostTransaction
Depends=reflector
Exec=/bin/sh -c 'systemctl start reflector.service && rm -f /etc/pacman.d/mirrorlist.pacnew'
EOT

}

function configure_pacman_nvidia_hook() {
    if [[ ! -d "/mnt/etc/pacman.d/hooks" ]]; then
        arch-chroot /mnt mkdir -p /etc/pacman.d/hooks
    fi

    cat <<EOT > "/mnt/etc/pacman.d/hooks/nvidia.hook"
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia
Target=linux
# Change the linux part above and in the Exec line if a different kernel is used

[Action]
Description=Update NVIDIA module in initcpio
Depends=mkinitcpio
When=PostTransaction
NeedsTargets
Exec=/bin/sh -c 'while read -r trg; do case \$trg in linux) exit 0; esac; done; /usr/bin/mkinitcpio -P'
EOT

}

# Console Colors
NC='\033[0m'

RED='\033[00;31m'
GREEN='\033[00;32m'
YELLOW='\033[00;33m'
BLUE='\033[00;34m'
PURPLE='\033[00;35m'
CYAN='\033[00;36m'
LIGHTGRAY='\033[00;37m'

LRED='\033[01;31m'
LGREEN='\033[01;32m'
LYELLOW='\033[01;33m'
LBLUE='\033[01;34m'
LPURPLE='\033[01;35m'
LCYAN='\033[01;36m'
WHITE='\033[01;37m'

main "$@"
