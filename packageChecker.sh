#!/bin/sh
# OPENWRT PACKAGE CHECKER AND AUS-COMPATIBLE LIST GENERATOR
# THIS SCRIPT COMPARES INSTALLED PACKAGES AGAINST THOSE AVAILABLE
# IN OPENWRT REPOSITORIES, IDENTIFIES UPGRADES AND REMOVED PACKAGES,
# AND OPTIONALLY GENERATES AN AUS-COMPATIBLE PACKAGE LIST.
#
# REQUIREMENTS: OPKG, WGET, GZIP, AWK, SED

# OPENWRT REPOSITORY CONFIGURATION
OPENWRT_VERSION="24.10.0"
TARGET_ARCH="x86/64"
PACKAGE_ARCH="x86_64"
FEEDS="base luci packages routing telephony"

# TEMPORARY FILE PATHS AND LOG FILE
TMP_DIR="/tmp/openwrt_packages"
INSTALLED_PACKAGES="/tmp/installed_packages.txt"
AVAILABLE_PACKAGES="/tmp/available_packages.txt"
AUS_PACKAGE_LIST="/tmp/aus_package_list.json"
LOG_FILE="/tmp/openwrt_update.log"

# FUNCTION: CHECK FOR REQUIRED DEPENDENCIES
check_dependencies() {
    for cmd in opkg wget gzip awk sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "\nError: required command '$cmd' not found. Please install it." | tee -a "$LOG_FILE"
            exit 1
        fi
    done
}

# FUNCTION: CLEANUP TEMPORARY FILES (AUTOMATICALLY CALLED ON SCRIPT EXIT)
cleanup() {
    echo -e "\nCleaning up temporary files..." | tee -a "$LOG_FILE"
    rm -rf "$TMP_DIR" "$INSTALLED_PACKAGES" "$AVAILABLE_PACKAGES"
}
trap cleanup EXIT

# CHECK DEPENDENCIES BEFORE PROCEEDING
check_dependencies

# CREATE TEMPORARY DIRECTORY AND INITIALIZE LOG FILE
mkdir -p "$TMP_DIR"
echo -e "\nStarting package check at $(date)" > "$LOG_FILE"

# READ OUT THE SELECTED OPENWRT VERSION AND TARGET ARCHITECTURE
echo -e "\nSelected OpenWrt version: $OPENWRT_VERSION, Target architecture: $TARGET_ARCH" | tee -a "$LOG_FILE"

# FETCH LIST OF INSTALLED PACKAGES USING OPKG
echo -e "\nFetching list of installed packages..." | tee -a "$LOG_FILE"
opkg list-installed | awk '{print $1, $2}' > "$INSTALLED_PACKAGES"

INSTALLED_COUNT=$(wc -l < "$INSTALLED_PACKAGES")
echo -e "\nFound $INSTALLED_COUNT installed packages." | tee -a "$LOG_FILE"

# FUNCTION: DOWNLOAD PACKAGE LIST WITH RETRY MECHANISM (UP TO 3 ATTEMPTS)
download_package_list() {
    local url="$1"
    local file="$2"
    local attempt=1
    while [ $attempt -le 3 ]; do
        echo -e "\nDownloading: $url" | tee -a "$LOG_FILE"
        wget -q -O "$file" "$url"
        if [ $? -eq 0 ]; then
            FILE_SIZE=$(wc -c < "$file")
            echo "Downloaded successfully ($FILE_SIZE bytes)" | tee -a "$LOG_FILE"
            return 0
        fi
        echo -e "\nAttempt $attempt failed for $url, retrying..." | tee -a "$LOG_FILE"
        attempt=$((attempt + 1))
        sleep 2
    done
    echo -e "\nFailed to fetch package list from $url after 3 attempts. Skipping." | tee -a "$LOG_FILE"
    return 1
}

# RETRIEVE THE LATEST KERNEL VERSION FROM THE KMODS DIRECTORY
echo -e "\nRetrieving latest kernel version from OpenWrt repository..." | tee -a "$LOG_FILE"
KERNEL_PAGE_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/$TARGET_ARCH/kmods/"
KERNEL_VERSION=$(wget -qO- "$KERNEL_PAGE_URL" | grep -oE '[0-9.]+-[0-9]+-[a-f0-9]+' | sort -V | tail -n 1)
if [ -z "$KERNEL_VERSION" ]; then
    echo -e "\nError: failed to retrieve kernel version from $KERNEL_PAGE_URL. Exiting." | tee -a "$LOG_FILE"
    exit 1
fi
echo -e "\nDetected kernel version for kmods: $KERNEL_VERSION" | tee -a "$LOG_FILE"

# DEFINE URLS AND FILE PATHS FOR KMODS PACKAGE LIST
KMODS_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/$TARGET_ARCH/kmods/$KERNEL_VERSION/Packages"
KMODS_FILE="$TMP_DIR/Packages_kmods"

# DOWNLOAD AND PROCESS TARGET PACKAGE LIST (COMPRESSED)
TARGET_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/$(echo $TARGET_ARCH | sed 's#/#/#g')/packages/Packages.gz"
TARGET_FILE="$TMP_DIR/Packages_target.gz"
if download_package_list "$TARGET_URL" "$TARGET_FILE"; then
    gzip -dc "$TARGET_FILE" | awk '/^Package:/ {pkg=$2} /^Version:/ {ver=$2; print pkg, ver}' >> "$AVAILABLE_PACKAGES"
    rm -f "$TARGET_FILE"
fi

# LOOP THROUGH EACH FEED AND DOWNLOAD ITS PACKAGE LIST
for FEED in $FEEDS; do
    URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/packages/$PACKAGE_ARCH/$FEED/Packages.gz"
    FILE="$TMP_DIR/Packages_$FEED.gz"
    
    if download_package_list "$URL" "$FILE"; then
        gzip -dc "$FILE" | awk '/^Package:/ {pkg=$2} /^Version:/ {ver=$2; print pkg, ver}' >> "$AVAILABLE_PACKAGES"
        rm -f "$FILE"
    fi
done

# DOWNLOAD AND PROCESS THE KMODS PACKAGE LIST
if download_package_list "$KMODS_URL" "$KMODS_FILE"; then
    awk '/^Package:/ {pkg=$2} /^Version:/ {ver=$2; print pkg, ver}' "$KMODS_FILE" >> "$AVAILABLE_PACKAGES"
    rm -f "$KMODS_FILE"
fi

AVAILABLE_COUNT=$(wc -l < "$AVAILABLE_PACKAGES")
echo -e "\nTotal available packages after download: $AVAILABLE_COUNT" | tee -a "$LOG_FILE"

# COMPARE INSTALLED PACKAGES WITH AVAILABLE PACKAGES TO IDENTIFY UPGRADES
UPGRADE_COUNT=0
echo -e "\nComparing installed packages with available versions..." | tee -a "$LOG_FILE"
while read -r PKG OLD_VER; do
    NEW_VER=$(awk -v pkg="$PKG" '$1 == pkg {print $2}' "$AVAILABLE_PACKAGES")
    if [ -n "$NEW_VER" ] && [ "$OLD_VER" != "$NEW_VER" ]; then
        UPGRADE_COUNT=$((UPGRADE_COUNT + 1))
    fi
done < "$INSTALLED_PACKAGES"
echo -e "Packages with available upgrades: $UPGRADE_COUNT" | tee -a "$LOG_FILE"

# LIST DETAILED UPGRADE INFORMATION FOR EACH PACKAGE (IF ANY)
if [ $UPGRADE_COUNT -gt 0 ]; then
    echo -e "\nListing packages with available upgrades:" | tee -a "$LOG_FILE"
    while read -r PKG OLD_VER; do
        NEW_VER=$(awk -v pkg="$PKG" '$1 == pkg {print $2}' "$AVAILABLE_PACKAGES")
        if [ -n "$NEW_VER" ] && [ "$OLD_VER" != "$NEW_VER" ]; then
            echo " - $PKG: $OLD_VER -> $NEW_VER" | tee -a "$LOG_FILE"
        fi
    done < "$INSTALLED_PACKAGES"
fi

# IDENTIFY PACKAGES THAT ARE NO LONGER AVAILABLE IN THE REPOSITORY
REMOVED_COUNT=0
REMOVED_PACKAGES=""
while read -r PKG _; do
    if ! grep -q "^$PKG " "$AVAILABLE_PACKAGES"; then
        REMOVED_PACKAGES="$REMOVED_PACKAGES,$PKG"
        REMOVED_COUNT=$((REMOVED_COUNT + 1))
    fi
done < "$INSTALLED_PACKAGES"
# REMOVE LEADING COMMA FROM THE LIST
REMOVED_PACKAGES=${REMOVED_PACKAGES#,}
echo -e "\nPackages no longer available in the repository: $REMOVED_COUNT ($REMOVED_PACKAGES)" | tee -a "$LOG_FILE"

# PROMPT USER TO GENERATE AN AUS-COMPATIBLE PACKAGE LIST (JSON FORMAT)
echo -e "\nWould you like to generate an AUS-compatible package list? (y/n)"
read -r RESPONSE
if [ "$RESPONSE" = "y" ]; then
    echo "[" > "$AUS_PACKAGE_LIST"
    # INCLUDE ONLY PACKAGES THAT ARE STILL AVAILABLE IN THE REPOSITORY
    awk -v removed="$REMOVED_PACKAGES" '{ if (index(removed, $1) == 0 ) print "  \"" $1 "\"," }' "$INSTALLED_PACKAGES" | sed '$ s/,$//' >> "$AUS_PACKAGE_LIST"
    echo "]" >> "$AUS_PACKAGE_LIST"
    echo "AUS-compatible package list saved to: $AUS_PACKAGE_LIST" | tee -a "$LOG_FILE"
else
    echo "Skipping AUS-compatible package list generation." | tee -a "$LOG_FILE"
fi

echo "Package check completed at $(date)." | tee -a "$LOG_FILE"
