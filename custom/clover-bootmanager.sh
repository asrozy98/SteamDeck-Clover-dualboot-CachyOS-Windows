#!/bin/bash

# define variables here
CLOVER=$(efibootmgr | grep -i Clover | colrm 9 | colrm 1 4)
CLOVER_VERSION=5160
CLOVER_EFI=\\EFI\\clover\\cloverx64.efi
BIOS_VERSION=$(cat /sys/class/dmi/id/bios_version)
MODEL=$(cat /sys/class/dmi/id/board_name)
OS_Name=$(grep PRETTY_NAME /etc/os-release | cut -d "=" -f 2)
OS_Version_Bazzite=$(grep OSTREE_VERSION /etc/os-release | cut -d "=" -f 2)
OS_Version_SteamOS=$(grep VERSION_ID /etc/os-release | cut -d "=" -f 2)
OS_Build=$(grep BUILD_ID /etc/os-release | cut -d "=" -f 2)
KERNEL_VERSION=$(uname -r | cut -d "-" -f 1-5)
OWNER=$(grep '1000:1000' /etc/passwd | cut -d ":" -f1)
CloverStatus=/home/$OWNER/1Clover-tools/status.txt

# check if Bazzite, SteamOS or CachyOS
grep -i bazzite /etc/os-release &> /dev/null
if [ $? -eq 0 ]
then
	OS=bazzite
	EFI_PATH=/boot/efi/EFI
	EFI_NAME=\\EFI\\fedora\\shimx64.efi
	LINUX_EFI_MOUNT_REF=/boot/efi
	echo Script is running on supported OS - $OS version $OS_Version_Bazzite build $OS_Build > $CloverStatus
else
	grep -i SteamOS /etc/os-release &> /dev/null
	if [ $? -eq 0 ]
	then
		OS=SteamOS
		EFI_PATH=/esp/efi
		EFI_NAME=\\EFI\\steamos\\steamcl.efi
		LINUX_EFI_MOUNT_REF=/esp
		echo Script is running on supported OS - $OS version $OS_Version_SteamOS build $OS_Build > $CloverStatus
	else
		grep -i CachyOS /etc/os-release &> /dev/null
		if [ $? -eq 0 ]
		then
			OS=CachyOS
			EFI_PATH=/boot/EFI
			# Assuming systemd-boot as per user request
			EFI_NAME=\\EFI\\systemd\\systemd-bootx64.efi
			LINUX_EFI_MOUNT_REF=/boot
			echo Script is running on supported OS - $OS > $CloverStatus
		else
			echo This is neither Bazzite, SteamOS nor CachyOS! > $CloverStatus
			echo Exiting immediately! >> $CloverStatus
			exit
		fi
	fi
fi

# --- START: Automatic Linux EFI Device Detection ---
# Find the device associated with the Linux EFI mount point
LINUX_EFI_DEV=$(findmnt -n -o SOURCE --target $LINUX_EFI_MOUNT_REF 2>/dev/null | head -n 1)

if [ -z "$LINUX_EFI_DEV" ]; then
    echo "Error: Could not automatically detect the Linux EFI device mounted at $LINUX_EFI_MOUNT_REF." >> $CloverStatus
    LINUX_EFI_DEV="/dev/nvme0n1p1"  # Fallback to default
    echo "Using fallback: $LINUX_EFI_DEV" >> $CloverStatus
fi

# Get ESP info using detected device
ESP_PARTITION=$LINUX_EFI_DEV
ESP_MOUNT_POINT=$(findmnt -n -o TARGET --source $LINUX_EFI_DEV 2>/dev/null | head -n 1)
ESP_ALLOCATED_SPACE=$(df -h $LINUX_EFI_DEV | tail -n1 | tr -s " " | cut -d " " -f 2)
ESP_USED_SPACE=$(df -h $LINUX_EFI_DEV | tail -n1 | tr -s " " | cut -d " " -f 3)
ESP_FREE_SPACE=$(df -h $LINUX_EFI_DEV | tail -n1 | tr -s " " | cut -d " " -f 4)
LINUX_DISK=$(echo $LINUX_EFI_DEV | sed 's/p[0-9]*$//')
LINUX_PART_NUM=$(echo $LINUX_EFI_DEV | grep -oE '[0-9]+$')
# --- END: Automatic Linux EFI Device Detection ---

echo Clover $CLOVER_VERSION Boot Manager - $(date) >> $CloverStatus
echo Steam Deck Model : $MODEL with  BIOS version $BIOS_VERSION >> $CloverStatus

echo Kernel Version : $KERNEL_VERSION >> $CloverStatus

# check for dump files
dumpfiles=$(ls -l /sys/firmware/efi/efivars/dump-type* 2> /dev/null | wc -l)

if [ $dumpfiles -gt 0 ]
then
	echo EFI dump files exists - cleanup completed. >> $CloverStatus
	sudo rm -f /sys/firmware/efi/efivars/dump-type*
else
	echo EFI dump files does not exist - no action needed. >> $CloverStatus
fi

# Sanity Check - are the needed EFI entries available?
efibootmgr | grep -i Clover &> /dev/null
if [ $? -eq 0 ]
then
	echo Clover EFI entry exists! No need to re-add Clover. >> $CloverStatus
else
	echo Clover EFI entry is not found. Need to re-ad Clover. >> $CloverStatus
	efibootmgr -c -d $LINUX_DISK -p $LINUX_PART_NUM -L "Clover - GUI Boot Manager" -l "$CLOVER_EFI" &> /dev/null
fi

efibootmgr | grep -i $OS &> /dev/null
if [ $? -eq 0 ]
then
	echo $OS EFI entry exists! No need to re-add $OS. >> $CloverStatus
else
	echo SteamOS EFI entry is not found. Need to re-add $OS. >> $CloverStatus
	efibootmgr -c -d $LINUX_DISK -p $LINUX_PART_NUM -L "$OS" -l "$EFI_NAME" &> /dev/null
fi

# Helper function for safe unmount with retry (no password needed - runs as root via systemd)
safe_unmount() {
    local mount_point="$1"
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        umount "$mount_point" 2>/dev/null
        if [ $? -eq 0 ]; then
            return 0
        fi
        sleep 1
        retry=$((retry + 1))
    done
    
    # Force unmount as last resort
    umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
    return $?
}

# Helper function for safe cleanup
safe_cleanup() {
    local temp_dir="$1"
    
    # Check if still mounted
    if mountpoint -q "$temp_dir" 2>/dev/null; then
        safe_unmount "$temp_dir"
    fi
    
    # Cleanup directory
    if [ -d "$temp_dir" ]; then
        rmdir "$temp_dir" 2>/dev/null || rm -rf "$temp_dir" 2>/dev/null
    fi
}

# --- START: Automatic Windows EFI Partition Detection ---
find_win_efi_partition() {
    PART_LIST=$(lsblk -r -n -o NAME,FSTYPE 2>/dev/null | awk '$2=="vfat" {print $1}')
    
    for PART_NAME in $PART_LIST; do
        PART="/dev/$PART_NAME"
        TEMP_MOUNT_CHECK=~/temp_check_win_efi_$$
        mkdir -p $TEMP_MOUNT_CHECK 2>/dev/null
        
        MOUNT_STATUS_OUTPUT=$(mount $PART $TEMP_MOUNT_CHECK 2>&1)
        MOUNT_STATUS=$?
        
        if [ $MOUNT_STATUS -eq 0 ]; then
            if [ -f "$TEMP_MOUNT_CHECK/EFI/Microsoft/Boot/bootmgfw.efi" ] || [ -f "$TEMP_MOUNT_CHECK/EFI/Microsoft/bootmgfw.efi" ]; then
                safe_unmount "$TEMP_MOUNT_CHECK"
                safe_cleanup "$TEMP_MOUNT_CHECK"
                echo "$PART"
                return 0
            fi
            # Not Windows EFI - unmount and cleanup
            safe_unmount "$TEMP_MOUNT_CHECK"
            safe_cleanup "$TEMP_MOUNT_CHECK"
        else
            # Mount failed - cleanup folder anyway
            safe_cleanup "$TEMP_MOUNT_CHECK"
        fi
    done
    return 1
}

WIN_EFI_PART=$(find_win_efi_partition)

if [ -z "$WIN_EFI_PART" ]; then
    echo "Windows EFI partition not found. Skipping Windows boot configuration." >> $CloverStatus
else
    WIN_EFI_MOUNT_POINT=~/temp-WIN-EFI-bootmanager
    mkdir -p $WIN_EFI_MOUNT_POINT 2>/dev/null
    mount $WIN_EFI_PART $WIN_EFI_MOUNT_POINT 2>/dev/null
    
    if [ $? -eq 0 ]; then
        WIN_EFI_PATH=$WIN_EFI_MOUNT_POINT/EFI
        
        # check if Windows EFI needs to be disabled!
        if [ -e $WIN_EFI_PATH/Microsoft/Boot/bootmgfw.efi.orig ]
        then
            echo Windows EFI backup exists. Check if Windows EFI needs to be disabled. >> $CloverStatus
            if [ -e $WIN_EFI_PATH/Microsoft/Boot/bootmgfw.efi ]
            then
                mv $WIN_EFI_PATH/Microsoft/Boot/bootmgfw.efi $WIN_EFI_PATH/Microsoft/bootmgfw.efi &> /dev/null
                echo Windows EFI needs to be disabled - done. >> $CloverStatus
            else
                echo Windows EFI is already disabled - no action needed. >> $CloverStatus
            fi
        else
            echo Windows EFI backup does not exist. >> $CloverStatus
            cp $WIN_EFI_PATH/Microsoft/Boot/bootmgfw.efi $WIN_EFI_PATH/Microsoft/Boot/bootmgfw.efi.orig &> /dev/null
            mv $WIN_EFI_PATH/Microsoft/Boot/bootmgfw.efi $WIN_EFI_PATH/Microsoft/bootmgfw.efi &> /dev/null
            echo Windows EFI needs to be disabled - done. >> $CloverStatus
        fi
        
        safe_unmount "$WIN_EFI_MOUNT_POINT"
    else
        echo "Failed to mount Windows EFI partition ($WIN_EFI_PART)." >> $CloverStatus
    fi
    
    safe_cleanup "$WIN_EFI_MOUNT_POINT"
fi
# --- END: Automatic Windows EFI Partition Detection ---

# re-arrange the boot order and make Clover the priority!
Clover=$(efibootmgr | grep -i Clover | colrm 9 | colrm 1 4)
OtherOS=$(efibootmgr | grep -i $OS | colrm 9 | colrm 1 4)
efibootmgr -o $Clover,$OtherOS &> /dev/null

echo "*** Current state of EFI entries ****" >> $CloverStatus
efibootmgr | grep -iv 'Boot2\|PXE' >> $CloverStatus
echo "*** Current state of EFI partition ****" >> $CloverStatus
echo ESP partition: $ESP_PARTITION >> $CloverStatus
echo ESP mount point: $ESP_MOUNT_POINT >> $CloverStatus
echo ESP allocated space: $ESP_ALLOCATED_SPACE >> $CloverStatus
echo ESP used space: $ESP_USED_SPACE >> $CloverStatus
echo ESP free space: $ESP_FREE_SPACE >> $CloverStatus

chown $OWNER:$OWNER $CloverStatus
