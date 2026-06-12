#!/usr/bin/env bash
###############################################################################
# FiveM LXC - fully automated provisioning for Proxmox
#
# One-liner usage from the Proxmox node shell (root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/automated-FiveM-lxc-for-proxmox/main/proxmox-create-fivem-lxc.sh)"
#
# It fetches fivem-lxc-setup.sh from the same repo automatically.
# (Also still works run locally with both scripts in one directory.)
#
# What it does:
#   1. Downloads a Debian 12 template if not present
#   2. Creates and starts an unprivileged LXC container
#   3. Pushes fivem-lxc-setup.sh into the container and runs it
#   4. Prints the container IP + txAdmin URL when done
#
# After it finishes, just copy in your txData / server-data (see SETUP-GUIDE.md
# Part 3) and run:  pct exec <CTID> -- systemctl start fivem
###############################################################################
set -euo pipefail

# ----------------------------- configurable ---------------------------------
# All of these can be overridden inline when using the one-liner, e.g.:
#   CTID=120 IP_CONFIG="192.168.1.50/24" GATEWAY="192.168.1.1" \
#     bash -c "$(curl -fsSL .../proxmox-create-fivem-lxc.sh)"
CTID="${CTID:-110}"                      # container ID (must be unused)
HOSTNAME="${HOSTNAME_CT:-fivem}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"                 # MB
SWAP="${SWAP:-1024}"                     # MB
DISK_GB="${DISK_GB:-40}"
STORAGE="${STORAGE:-local-lvm}"          # storage for the container rootfs
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # storage that holds CT templates
BRIDGE="${BRIDGE:-vmbr0}"

# Network: leave IP_CONFIG="dhcp" or set a static IP like:
#   IP_CONFIG="192.168.1.50/24"  and  GATEWAY="192.168.1.1"
IP_CONFIG="${IP_CONFIG:-dhcp}"
GATEWAY="${GATEWAY:-}"

# Root password for the container (console login). Change this!
CT_ROOT_PASSWORD="${CT_ROOT_PASSWORD:-ChangeMe123!}"

# Raw GitHub base URL of your repo (where fivem-lxc-setup.sh lives).
# EDIT THIS to point at your repository:
RAW_BASE="https://raw.githubusercontent.com/blake165/automated-FiveM-lxc-for-proxmox/main"
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then echo "Run as root on the Proxmox host." >&2; exit 1; fi
if ! command -v pct &>/dev/null; then echo "pct not found - is this a Proxmox host?" >&2; exit 1; fi

# Locate the FiveM setup script: use a local copy if it exists next to this
# script, otherwise download it from the GitHub repo (one-liner mode).
LOCAL_SETUP="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")" 2>/dev/null)/fivem-lxc-setup.sh"
if [[ -f "${LOCAL_SETUP}" ]]; then
  SETUP_SCRIPT="${LOCAL_SETUP}"
  echo "==> Using local fivem-lxc-setup.sh"
else
  SETUP_SCRIPT="$(mktemp /tmp/fivem-lxc-setup.XXXXXX.sh)"
  echo "==> Downloading fivem-lxc-setup.sh from ${RAW_BASE}..."
  if ! curl -fsSL -o "${SETUP_SCRIPT}" "${RAW_BASE}/fivem-lxc-setup.sh"; then
    echo "Failed to download fivem-lxc-setup.sh - check RAW_BASE in this script." >&2
    exit 1
  fi
fi
if pct status "${CTID}" &>/dev/null; then
  echo "CTID ${CTID} already exists. Pick a free ID at the top of this script." >&2
  exit 1
fi

echo "==> Checking for Debian 12 template..."
pveam update >/dev/null
TEMPLATE=$(pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | awk '/debian-12-standard/ {print $1; exit}')
if [[ -z "${TEMPLATE}" ]]; then
  TEMPLATE_NAME=$(pveam available --section system | awk '/debian-12-standard/ {print $2; exit}')
  if [[ -z "${TEMPLATE_NAME}" ]]; then
    echo "No debian-12-standard template available from pveam." >&2
    exit 1
  fi
  echo "    Downloading ${TEMPLATE_NAME}..."
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE_NAME}"
  TEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
fi
echo "    Using template: ${TEMPLATE}"

NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG}"
if [[ "${IP_CONFIG}" != "dhcp" ]]; then
  [[ -z "${GATEWAY}" ]] && { echo "Static IP set but GATEWAY is empty." >&2; exit 1; }
  NET0+=",gw=${GATEWAY}"
fi

echo "==> Creating container ${CTID} (${HOSTNAME})..."
pct create "${CTID}" "${TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEMORY}" \
  --swap "${SWAP}" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "${NET0}" \
  --unprivileged 1 \
  --features nesting=1 \
  --password "${CT_ROOT_PASSWORD}" \
  --onboot 1

echo "==> Starting container..."
pct start "${CTID}"

echo "==> Waiting for network inside the container..."
for i in $(seq 1 30); do
  if pct exec "${CTID}" -- ping -c1 -W2 deb.debian.org &>/dev/null; then
    break
  fi
  sleep 2
  [[ $i -eq 30 ]] && { echo "Container never got network access." >&2; exit 1; }
done

echo "==> Pushing and running FiveM setup script (this downloads ~100MB)..."
pct push "${CTID}" "${SETUP_SCRIPT}" /root/fivem-lxc-setup.sh
pct exec "${CTID}" -- bash /root/fivem-lxc-setup.sh

CT_IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')

cat <<EOM

=============================================================================
 Container ${CTID} provisioned successfully!
=============================================================================
 Container IP : ${CT_IP}
 txAdmin URL  : http://${CT_IP}:40120   (after you start the service)
 Root login   : via 'pct enter ${CTID}' or console (password set in script)

 Remaining steps (migrating your existing server):

 1. Copy your data in, e.g. from this host:
      pct push ${CTID} txdata.tar.gz /tmp/txdata.tar.gz
      pct exec ${CTID} -- tar -xzf /tmp/txdata.tar.gz -C /home/fivem/txData --strip-components=1
    (same idea for server-data; or scp directly to root@${CT_IP})

 2. Fix ownership + txAdmin paths:
      pct exec ${CTID} -- chown -R fivem:fivem /home/fivem
      pct exec ${CTID} -- nano /home/fivem/txData/default/config.json
        -> serverDataPath: /home/fivem/server-data
        -> cfgPath:        /home/fivem/server-data/server.cfg

 3. Start it:
      pct exec ${CTID} -- systemctl start fivem
      pct exec ${CTID} -- journalctl -u fivem -f

 Fresh install instead of migrating? Just start the service and open the
 txAdmin URL - the setup PIN appears in the journalctl logs.
=============================================================================
EOM
