#!/bin/bash

clear

echo "========================================="
echo "Clover Dual Boot Configuration Checker by asrozy98"
echo "https://github.com/asrozy98/SteamDeck-Clover-dualboot-CachyOS-Windows"
echo "========================================="
echo ""

# Get device information
BIOS_VERSION=$(cat /sys/class/dmi/id/bios_version)
MODEL=$(cat /sys/class/dmi/id/board_name)
PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
PRODUCT_FAMILY=$(cat /sys/class/dmi/id/product_family 2>/dev/null)
KERNEL_VERSION=$(uname -r)

# Display device information
echo "Device Information:"
echo "  Model: $MODEL"
if [ -n "$PRODUCT_NAME" ]; then
    echo "  Product: $PRODUCT_NAME ($PRODUCT_FAMILY)"
fi
echo "  BIOS Version: $BIOS_VERSION"
echo "  Kernel: $KERNEL_VERSION"
echo ""

# Check if Bazzite, SteamOS, or CachyOS
echo "Detecting Operating System..."
grep -i bazzite /etc/os-release &> /dev/null
if [ $? -eq 0 ]
then
	OS=bazzite
	EFI_PATH=/boot/efi/EFI
	BOOTX64=$EFI_PATH/BOOT/BOOTX64.EFI
	LINUX_EFI_MOUNT_REF=/boot/efi
	OS_Version=$(grep OSTREE_VERSION /etc/os-release | cut -d "=" -f 2)
	OS_Build=$(grep BUILD_ID /etc/os-release | cut -d "=" -f 2)
	echo "  OS: $OS"
	echo "  Version: $OS_Version"
	echo "  Build: $OS_Build"
else
	grep -i SteamOS /etc/os-release &> /dev/null
	if [ $? -eq 0 ]
	then
		OS=SteamOS
		EFI_PATH=/esp/efi
		BOOTX64=$EFI_PATH/boot/bootx64.efi
		LINUX_EFI_MOUNT_REF=/esp
		OS_Version=$(grep VERSION_ID /etc/os-release | cut -d "=" -f 2)
		OS_Build=$(grep BUILD_ID /etc/os-release | cut -d "=" -f 2)
		echo "  OS: $OS"
		echo "  Version: $OS_Version"
		echo "  Build: $OS_Build"
	else
		grep -i CachyOS /etc/os-release &> /dev/null
		if [ $? -eq 0 ]
		then
			OS=CachyOS
			EFI_PATH=/boot/EFI
			BOOTX64=$EFI_PATH/BOOT/BOOTX64.EFI
			LINUX_EFI_MOUNT_REF=/boot
			OS_Build=$(grep BUILD_ID /etc/os-release | cut -d "=" -f 2)
			echo "  OS: $OS"
			echo "  Build: $OS_Build"
		else
			echo "  ERROR: This is neither Bazzite, SteamOS nor CachyOS!"
			echo "  Exiting immediately!"
			exit
		fi
	fi
fi
echo ""

# Check sudo password
if [ "$(passwd --status $(whoami) | tr -s " " | cut -d " " -f 2)" == "P" ]
then
	read -s -p "Please enter current sudo password: " current_password ; echo
	echo "Checking if the sudo password is correct..."
	echo -e "$current_password\n" | sudo -S ls &> /dev/null

	if [ $? -eq 0 ]
	then
		echo "  Sudo password verified!"
	else
		echo "  ERROR: Sudo password is wrong!"
		exit
	fi
else
	echo "  ERROR: Sudo password is blank! Setup a sudo password first!"
	passwd
	exit
fi
echo ""

# --- START: Automatic Linux EFI Device Detection ---
echo "========================================="
echo "Linux EFI Partition Detection"
echo "========================================="
echo "Detecting Linux EFI device from mount point: $LINUX_EFI_MOUNT_REF"

# Find the device associated with the Linux EFI mount point
LINUX_EFI_DEV=$(findmnt -n -o SOURCE --target $LINUX_EFI_MOUNT_REF 2>/dev/null | head -n 1)

if [ -z "$LINUX_EFI_DEV" ]; then
    echo "  ERROR: Could not automatically detect the Linux EFI device."
    echo "  Expected mount point: $LINUX_EFI_MOUNT_REF"
    exit
fi

# Extract disk and partition information
LINUX_DISK=$(echo $LINUX_EFI_DEV | sed 's/p[0-9]*$//')
LINUX_EFI_PART_NUM=$(echo "$LINUX_EFI_DEV" | grep -oE '[0-9]+$')

if [ -z "$LINUX_EFI_PART_NUM" ]; then
    echo "  ERROR: Could not extract partition number from $LINUX_EFI_DEV."
    exit
fi

# Get partition information
ESP_MOUNT_POINT=$(findmnt -n -o TARGET --source $LINUX_EFI_DEV 2>/dev/null | head -n 1)
ESP_ALLOCATED_SPACE=$(df -h $LINUX_EFI_DEV 2>/dev/null | tail -n1 | tr -s " " | cut -d " " -f 2)
ESP_USED_SPACE=$(df -h $LINUX_EFI_DEV 2>/dev/null | tail -n1 | tr -s " " | cut -d " " -f 3)
ESP_FREE_SPACE=$(df -h $LINUX_EFI_DEV 2>/dev/null | tail -n1 | tr -s " " | cut -d " " -f 4)
ESP_USE_PERCENT=$(df -h $LINUX_EFI_DEV 2>/dev/null | tail -n1 | tr -s " " | cut -d " " -f 5)

echo ""
echo "Linux EFI Partition Details:"
echo "  Device: $LINUX_EFI_DEV"
echo "  Disk: $LINUX_DISK"
echo "  Partition Number: $LINUX_EFI_PART_NUM"
echo "  Mount Point: $ESP_MOUNT_POINT"
echo "  Total Size: $ESP_ALLOCATED_SPACE"
echo "  Used Space: $ESP_USED_SPACE ($ESP_USE_PERCENT)"
echo "  Free Space: $ESP_FREE_SPACE"
echo ""
# --- END: Automatic Linux EFI Device Detection ---

# --- START: Automatic Windows EFI Partition Detection ---
echo "========================================="
echo "Windows EFI Partition Detection"
echo "========================================="
echo "Searching for Windows EFI partition..."
echo ""

# Helper function for safe unmount with retry
safe_unmount() {
    local mount_point="$1"
    local password="$2"
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        if [ -n "$password" ]; then
            echo -e "$password\n" | sudo -S umount "$mount_point" 2>/dev/null
        else
            umount "$mount_point" 2>/dev/null
        fi
        
        if [ $? -eq 0 ]; then
            return 0
        fi
        
        # Wait and retry
        sleep 1
        retry=$((retry + 1))
    done
    
    # Force unmount as last resort
    if [ -n "$password" ]; then
        echo -e "$password\n" | sudo -S umount -f "$mount_point" 2>/dev/null || \
        echo -e "$password\n" | sudo -S umount -l "$mount_point" 2>/dev/null
    else
        umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
    fi
    
    return $?
}

# Helper function for safe cleanup
safe_cleanup() {
    local temp_dir="$1"
    local password="$2"
    
    # Check if still mounted
    if mountpoint -q "$temp_dir" 2>/dev/null; then
        safe_unmount "$temp_dir" "$password"
    fi
    
    # Cleanup directory
    if [ -d "$temp_dir" ]; then
        rmdir "$temp_dir" 2>/dev/null || rm -rf "$temp_dir" 2>/dev/null
    fi
}

# Function to find the Windows EFI partition
find_win_efi_partition() {
    PART_LIST=$(lsblk -r -n -o NAME,FSTYPE 2>/dev/null | awk '$2=="vfat" {print $1}')
    
    # Create temporary file to store partition info
    TEMP_WIN_INFO=/tmp/win_efi_info_$$
    
    for PART_NAME in $PART_LIST; do
        PART="/dev/$PART_NAME"

        TEMP_MOUNT_CHECK=~/temp_check_win_efi_$$
        mkdir -p $TEMP_MOUNT_CHECK 2>/dev/null
        
        # Mount READ-ONLY to prevent any data corruption
        MOUNT_STATUS_OUTPUT=$(echo -e "$current_password\n" | sudo -S mount -o ro $PART $TEMP_MOUNT_CHECK 2>&1)
        MOUNT_STATUS=$?

        if [ $MOUNT_STATUS -eq 0 ]; then
            if [ -f "$TEMP_MOUNT_CHECK/EFI/Microsoft/Boot/bootmgfw.efi" ] || [ -f "$TEMP_MOUNT_CHECK/EFI/Microsoft/bootmgfw.efi" ]; then
                # Get Windows partition details before unmounting
                WIN_ALLOCATED=$(df -h $PART 2>/dev/null | tail -n1 | tr -s " " | cut -d " " -f 2)
                WIN_USED=$(df -h $PART 2>/dev/null | tail -n1 | tr -s " " | cut -d " " -f 3)
                WIN_FREE=$(df -h $PART 2>/dev/null | tail -n1 | tr -s " " | cut -d " " -f 4)
                WIN_PERCENT=$(df -h $PART 2>/dev/null | tail -n1 | tr -s " " | cut -d " " -f 5)
                
                # Save partition info to temp file
                echo "WIN_ALLOCATED=$WIN_ALLOCATED" > $TEMP_WIN_INFO
                echo "WIN_USED=$WIN_USED" >> $TEMP_WIN_INFO
                echo "WIN_FREE=$WIN_FREE" >> $TEMP_WIN_INFO
                echo "WIN_PERCENT=$WIN_PERCENT" >> $TEMP_WIN_INFO
                
                # Safe unmount and cleanup
                safe_unmount "$TEMP_MOUNT_CHECK" "$current_password"
                if [ $? -ne 0 ]; then
                    echo "  Warning: Failed to unmount $PART properly" >&2
                fi
                safe_cleanup "$TEMP_MOUNT_CHECK" "$current_password"
                
                echo "$PART"
                return 0
            fi
            # Not Windows EFI - unmount and cleanup
            safe_unmount "$TEMP_MOUNT_CHECK" "$current_password"
            safe_cleanup "$TEMP_MOUNT_CHECK" "$current_password"
        else
            # Mount failed - cleanup folder anyway
            safe_cleanup "$TEMP_MOUNT_CHECK" "$current_password"
        fi
    done

    return 1
}

WIN_EFI_PART=$(find_win_efi_partition)

# Load Windows partition info if found
if [ -n "$WIN_EFI_PART" ] && [ -f "/tmp/win_efi_info_$$" ]; then
    source /tmp/win_efi_info_$$
    rm -f /tmp/win_efi_info_$$
fi

if [ -z "$WIN_EFI_PART" ]; then
    echo "Windows EFI partition: NOT FOUND"
    echo "  Windows is not installed or not detected on this system."
else
    # Extract disk and partition information for Windows EFI
    WIN_DISK=$(echo $WIN_EFI_PART | sed 's/p[0-9]*$//')
    WIN_EFI_PART_NUM=$(echo "$WIN_EFI_PART" | grep -oE '[0-9]+$')
    
    # Check if Windows EFI is currently mounted
    WIN_MOUNT_POINT=$(findmnt -n -o TARGET --source $WIN_EFI_PART 2>/dev/null | head -n 1)
    
    echo ""
    echo "Windows EFI Partition Details:"
    echo "  Device: $WIN_EFI_PART"
    echo "  Disk: $WIN_DISK"
    echo "  Partition Number: $WIN_EFI_PART_NUM"
    if [ -n "$WIN_MOUNT_POINT" ]; then
        echo "  Mount Point: $WIN_MOUNT_POINT"
    else
        echo "  Mount Point: Not currently mounted"
    fi
    echo "  Total Size: $WIN_ALLOCATED"
    echo "  Used Space: $WIN_USED ($WIN_PERCENT)"
    echo "  Free Space: $WIN_FREE"
fi
echo ""
# --- END: Automatic Windows EFI Partition Handling ---

# --- START: Check Clover Installation ---
echo "========================================="
echo "Clover Installation Status"
echo "========================================="

# Check for Clover EFI entries
CLOVER=$(efibootmgr 2>/dev/null | grep -i Clover | colrm 9 | colrm 1 4)

if [ -n "$CLOVER" ]; then
    echo "Clover EFI Entry: FOUND"
    echo "  Boot Entry ID: $CLOVER"
    
    # Check if Clover files exist
    if echo -e "$current_password\n" | sudo -S test -e $EFI_PATH/clover/cloverx64.efi; then
        echo "  Clover EFI File: EXISTS"
        CLOVER_SIZE=$(echo -e "$current_password\n" | sudo -S du -h $EFI_PATH/clover/cloverx64.efi 2>/dev/null | cut -f1)
        echo "  File Size: $CLOVER_SIZE"
    else
        echo "  Clover EFI File: MISSING"
    fi
    
    # Check systemd service
    if systemctl is-enabled clover-bootmanager.service &>/dev/null; then
        SERVICE_STATUS=$(systemctl is-active clover-bootmanager.service 2>/dev/null)
        echo "  Systemd Service: ENABLED ($SERVICE_STATUS)"
    else
        echo "  Systemd Service: DISABLED or NOT INSTALLED"
    fi
else
    echo "Clover EFI Entry: NOT FOUND, Clover is not installed on this system."
fi
echo ""
# --- END: Check Clover Installation ---

# --- START: Summary ---
echo "========================================="
echo "Configuration Summary"
echo "========================================="
echo "Device: $MODEL"
echo "OS: $OS"
echo "Linux EFI: $LINUX_EFI_DEV ($ESP_FREE_SPACE free)"
if [ -n "$WIN_EFI_PART" ]; then
    echo "Windows EFI: $WIN_EFI_PART ($WIN_FREE free)"
else
    echo "Windows EFI: NOT DETECTED"
fi
if [ -n "$CLOVER" ]; then
    echo "Clover Status: INSTALLED"
else
    echo "Clover Status: NOT INSTALLED"
fi
echo "========================================="
echo ""
# --- END: Summary ---