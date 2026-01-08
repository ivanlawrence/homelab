#!/bin/bash

#!/bin/bash

# Define our cluster metadata
# Indices: 0, 1, 2 map to m700a, m700b, m700c
HOSTNAMES=("m700a" "m700b" "m700c")
IPS=("192.168.110.11" "192.168.110.12" "192.168.110.13")

# Function to find index by hostname
get_index_by_name() {
    for i in "${!HOSTNAMES[@]}"; do
        if [[ "${HOSTNAMES[$i]}" == "$1" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# Input Logic: Determine if input is an integer or a string
INPUT=$1
if [[ "$INPUT" =~ ^[0-2]$ ]]; then
    INDEX=$INPUT
else
    INDEX=$(get_index_by_name "$INPUT")
fi

# Validation
if [[ -z "$INDEX" || $INDEX -lt 0 || $INDEX -gt 2 ]]; then
    echo "Error: Please provide 0, 1, 2 or m700a, m700b, m700c"
    exit 1
fi

TARGET_HOSTNAME=${HOSTNAMES[$INDEX]}
TARGET_IP=${IPS[$INDEX]}

echo "Configuring node as $TARGET_HOSTNAME with IP $TARGET_IP..."

# 1. Update Hostname
echo "$TARGET_HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$TARGET_HOSTNAME"

# 2. Update /etc/apt/sources.list (Your Sed command)
echo "Updating APT sources..."
sudo sed -i '/^deb/{/contrib/!s/$/ contrib/; /non-free/!s/$/ non-free/}' /etc/apt/sources.list

# 2. Install ZFS & Dependencies
echo "Installing Kernel Headers and ZFS..."
apt update
apt install -y curl gpg tmux
apt install -y linux-headers-amd64
# Install zfsutils-linux and zfs-dkms (DKMS builds the module for your kernel)
apt install -y zfsutils-linux zfs-dkms

# 3. Load ZFS Kernel Module
modprobe zfs
echo "zfs" >> /etc/modules

# 2. Add Zabbly Stable Repository for Incus
echo "Adding Zabbly GPG key and repository..."
curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --show-keys --fingerprint
mkdir -p /etc/apt/keyrings/
curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc

# Create the sources file using the modern deb822 format
cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF

# 3. Configure /etc/hosts for the Cluster
# This ensures every node knows how to find the others by name (crucial for Incus)
echo "Configuring /etc/hosts..."
for i in "${!HOSTNAMES[@]}"; do
    # Remove existing entry for this hostname to prevent duplicates
    sed -i "/ ${HOSTNAMES[$i]}$/d" /etc/hosts
    # Append fresh entry
    echo "${IPS[$i]} ${HOSTNAMES[$i]}" >> /etc/hosts
done

# --- Networking Configuration ---
# 1. Identify the primary interface (excluding loopback)
INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n1)

echo ">>> Configuring Static IP on $INTERFACE..."

# 2. Backup the old config
cp /etc/network/interfaces /etc/network/interfaces.bak

# 3. Write the new static configuration
# Note: We assume a /24 network and a .1 gateway. Adjust if your setup differs.
cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet static
    address $TARGET_IP/24
    gateway 192.168.110.1
    dns-nameservers 1.1.1.1 8.8.8.8
EOF

# 4. Apply the changes
# Warning: This may drop your current SSH connection if the IP changes!
systemctl restart networking

# 4. Final System Update
apt update && apt install -y incus

echo "Success: $TARGET_HOSTNAME is ready."
