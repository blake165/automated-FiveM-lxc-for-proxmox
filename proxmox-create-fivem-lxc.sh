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
# Prompts will ask for CTID, resources, network, and root password.
# Skip prompts: NONINTERACTIVE=1 CT_ROOT_PASSWORD=x bash -c "$(curl ...)"
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

# Root password for the container (console login).
CT_ROOT_PASSWORD="${CT_ROOT_PASSWORD:-}"

# Set NONINTERACTIVE=1 to skip all prompts and use defaults/env values only.
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# SSH: allow root login with password inside the container (needed for scp
# file transfers from another machine). 1 = enable, 0 = skip.
ENABLE_SSH_ROOT="${ENABLE_SSH_ROOT:-1}"

# MariaDB: install a database for ESX/QBCore/oxmysql resources.
INSTALL_MARIADB="${INSTALL_MARIADB:-1}"
DB_NAME="${DB_NAME:-fivem}"
DB_USER="${DB_USER:-fivem}"
DB_PASSWORD="${DB_PASSWORD:-}"

# Raw GitHub base URL of your repo (where fivem-lxc-setup.sh lives).
RAW_BASE="https://raw.githubusercontent.com/blake165/automated-FiveM-lxc-for-proxmox/main"
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then echo "Run as root on the Proxmox host." >&2; exit 1; fi
if ! command -v pct &>/dev/null; then echo "pct not found - is this a Proxmox host?" >&2; exit 1; fi

# --------------------------- interactive wizard -----------------------------
ask() { # ask "Question" "default" -> echoes answer
  local q="$1" def="$2" ans
  read -r -p "  ${q} [${def}]: " ans </dev/tty
  echo "${ans:-$def}"
}

if [[ "${NONINTERACTIVE}" != "1" && -e /dev/tty ]]; then
  echo ""
  echo "============================================"
  echo "      FiveM LXC - interactive setup"
  echo "============================================"
  echo "Press Enter to accept the [default] value."
  echo ""

  # Container ID - keep asking until we get a free, numeric one
  while :; do
    CTID=$(ask "Container ID" "${CTID}")
    if ! [[ "${CTID}" =~ ^[0-9]+$ ]]; then
      echo "  ! Must be a number."
    elif pct status "${CTID}" &>/dev/null; then
      echo "  ! CTID ${CTID} is already in use, pick another."
    else
      break
    fi
  done

  HOSTNAME=$(ask "Hostname" "${HOSTNAME}")
  CORES=$(ask "CPU cores" "${CORES}")
  MEMORY=$(ask "Memory (MB)" "${MEMORY}")
  DISK_GB=$(ask "Disk size (GB)" "${DISK_GB}")
  STORAGE=$(ask "Storage for container disk" "${STORAGE}")
  BRIDGE=$(ask "Network bridge" "${BRIDGE}")

  NET_CHOICE=$(ask "Network: dhcp or static?" "$([[ ${IP_CONFIG} == dhcp ]] && echo dhcp || echo static)")
  if [[ "${NET_CHOICE}" == "static" ]]; then
    while :; do
      IP_CONFIG=$(ask "Static IP with CIDR (e.g. 192.168.1.50/24)" "$([[ ${IP_CONFIG} == dhcp ]] && echo '' || echo "${IP_CONFIG}")")
      [[ "${IP_CONFIG}" =~ ^[0-9.]+/[0-9]+$ ]] && break
      echo "  ! Format must be IP/prefix, e.g. 192.168.1.50/24"
    done
    while :; do
      GATEWAY=$(ask "Gateway (e.g. 192.168.1.1)" "${GATEWAY}")
      [[ -n "${GATEWAY}" ]] && break
      echo "  ! Gateway is required for a static IP."
    done
  else
    IP_CONFIG="dhcp"
    GATEWAY=""
  fi

  # Root password - hidden input, confirmed, required
  if [[ -z "${CT_ROOT_PASSWORD}" ]]; then
    while :; do
      read -r -s -p "  Container root password: " PW1 </dev/tty; echo
      read -r -s -p "  Confirm password: " PW2 </dev/tty; echo
      if [[ -z "${PW1}" ]]; then
        echo "  ! Password cannot be empty."
      elif [[ "${PW1}" != "${PW2}" ]]; then
        echo "  ! Passwords do not match, try again."
      else
        CT_ROOT_PASSWORD="${PW1}"
        break
      fi
    done
  fi

  # SSH access
  SSH_CHOICE=$(ask "Enable SSH root login (for scp file transfers)? (yes/no)" "yes")
  [[ "${SSH_CHOICE}" =~ ^[Yy] ]] && ENABLE_SSH_ROOT=1 || ENABLE_SSH_ROOT=0

  # MariaDB
  DB_CHOICE=$(ask "Install MariaDB (needed for ESX/QBCore/oxmysql)? (yes/no)" "yes")
  if [[ "${DB_CHOICE}" =~ ^[Yy] ]]; then
    INSTALL_MARIADB=1
    DB_NAME=$(ask "Database name" "${DB_NAME}")
    DB_USER=$(ask "Database user" "${DB_USER}")
    if [[ -z "${DB_PASSWORD}" ]]; then
      while :; do
        read -r -s -p "  Database password: " DBPW1 </dev/tty; echo
        read -r -s -p "  Confirm database password: " DBPW2 </dev/tty; echo
        if [[ -z "${DBPW1}" ]]; then
          echo "  ! Password cannot be empty."
        elif [[ "${DBPW1}" != "${DBPW2}" ]]; then
          echo "  ! Passwords do not match, try again."
        else
          DB_PASSWORD="${DBPW1}"
          break
        fi
      done
    fi
  else
    INSTALL_MARIADB=0
  fi

  echo ""
  echo "--------------------------------------------"
  echo "  CTID      : ${CTID}"
  echo "  Hostname  : ${HOSTNAME}"
  echo "  Cores     : ${CORES}"
  echo "  Memory    : ${MEMORY} MB"
  echo "  Disk      : ${DISK_GB} GB on ${STORAGE}"
  echo "  Network   : ${BRIDGE}, ${IP_CONFIG}${GATEWAY:+ gw ${GATEWAY}}"
  echo "  SSH root  : $([[ ${ENABLE_SSH_ROOT} == 1 ]] && echo enabled || echo disabled)"
  echo "  MariaDB   : $([[ ${INSTALL_MARIADB} == 1 ]] && echo "yes (db=${DB_NAME}, user=${DB_USER})" || echo no)"
  echo "--------------------------------------------"
  CONFIRM=$(ask "Create this container? (yes/no)" "yes")
  [[ "${CONFIRM}" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  echo ""
else
  # Non-interactive mode still needs passwords supplied via env vars
  if [[ -z "${CT_ROOT_PASSWORD}" ]]; then
    echo "Non-interactive mode: set CT_ROOT_PASSWORD env var." >&2
    exit 1
  fi
  if [[ "${INSTALL_MARIADB}" == "1" && -z "${DB_PASSWORD}" ]]; then
    echo "Non-interactive mode: set DB_PASSWORD env var (or INSTALL_MARIADB=0)." >&2
    exit 1
  fi
fi
# -----------------------------------------------------------------------------

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
pct exec "${CTID}" -- env \
  ENABLE_SSH_ROOT="${ENABLE_SSH_ROOT}" \
  INSTALL_MARIADB="${INSTALL_MARIADB}" \
  DB_NAME="${DB_NAME}" \
  DB_USER="${DB_USER}" \
  DB_PASSWORD="${DB_PASSWORD}" \
  bash /root/fivem-lxc-setup.sh

CT_IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')

cat <<EOM

=============================================================================
 Container ${CTID} provisioned successfully!
=============================================================================
 Container IP : ${CT_IP}
 txAdmin URL  : http://${CT_IP}:40120   (after you start the service)
 Root login   : 'pct enter ${CTID}' or console
EOM
if [[ "${ENABLE_SSH_ROOT}" == "1" ]]; then
  echo " SSH          : ssh root@${CT_IP}  (password you chose in the wizard)"
fi
if [[ "${INSTALL_MARIADB}" == "1" ]]; then
  cat <<EOM
 MariaDB      : db '${DB_NAME}', user '${DB_USER}' (localhost only)
                Add to your server.cfg:
                set mysql_connection_string "mysql://${DB_USER}:YOUR_DB_PASSWORD@localhost/${DB_NAME}?charset=utf8mb4"
                Import your old data: mysql ${DB_NAME} < dump.sql
EOM
fi
cat <<EOM

 Remaining steps (migrating your existing server):

 1. Copy your data in, e.g. from another machine:
      scp -r ./txData root@${CT_IP}:/home/fivem/txData
      scp -r ./server-data root@${CT_IP}:/home/fivem/server-data
    (or from this host: pct push ${CTID} <tarball> /tmp/ and extract)

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
