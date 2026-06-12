#!/usr/bin/env bash
###############################################################################
# FiveM (FXServer + txAdmin) automated setup for a Proxmox LXC container
#
# Run this INSIDE the container as root:
#   bash fivem-lxc-setup.sh
#
# What it does:
#   1. Installs dependencies
#   2. Creates a 'fivem' service user
#   3. Downloads the latest recommended FXServer Linux artifact
#   4. Sets up directory layout that can host your existing txData + server folder
#   5. Creates a systemd service so the server autostarts with the container
###############################################################################
set -euo pipefail

# ----------------------------- configurable ---------------------------------
FIVEM_USER="fivem"
FIVEM_HOME="/home/${FIVEM_USER}"
ARTIFACT_DIR="${FIVEM_HOME}/artifact"      # FXServer binaries live here
TXDATA_DIR="${FIVEM_HOME}/txData"          # drop your existing txData here
SERVERDATA_DIR="${FIVEM_HOME}/server-data" # drop your existing server folder here
TXADMIN_PORT="40120"
# Pin a specific artifact by setting this to a full fx.tar.xz URL from
# https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/
# or leave empty to auto-detect the recommended build.
ARTIFACT_URL=""

# These are normally passed in by proxmox-create-fivem-lxc.sh:
ENABLE_SSH_ROOT="${ENABLE_SSH_ROOT:-0}"   # 1 = allow root SSH login w/ password
INSTALL_MARIADB="${INSTALL_MARIADB:-0}"   # 1 = install MariaDB + create db/user
DB_NAME="${DB_NAME:-fivem}"
DB_USER="${DB_USER:-fivem}"
DB_PASSWORD="${DB_PASSWORD:-}"
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

echo "==> Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget xz-utils tar git ca-certificates jq >/dev/null

echo "==> Creating service user '${FIVEM_USER}'..."
if ! id "${FIVEM_USER}" &>/dev/null; then
  useradd -m -d "${FIVEM_HOME}" -s /bin/bash "${FIVEM_USER}"
fi
mkdir -p "${ARTIFACT_DIR}" "${TXDATA_DIR}" "${SERVERDATA_DIR}"

echo "==> Resolving FXServer artifact..."
BASE_URL="https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master"
if [[ -z "${ARTIFACT_URL}" ]]; then
  # Preferred: official JSON API for the recommended build
  VERSION=$(curl -fsSL "${BASE_URL}/recommended.json" 2>/dev/null | jq -r '.version' 2>/dev/null || true)
  if [[ -z "${VERSION}" || "${VERSION}" == "null" ]]; then
    # Fallback: scrape the build listing page for the newest build
    PAGE=$(curl -fsSL "${BASE_URL}/" 2>/dev/null || true)
    VERSION=$(echo "${PAGE}" | grep -oE '[0-9]+-[a-f0-9]{40}' | sort -t- -k1,1n | tail -1)
  fi
  if [[ -z "${VERSION}" ]]; then
    echo "Could not auto-detect the FXServer build version." >&2
    echo "Set ARTIFACT_URL at the top of this script manually, e.g.:" >&2
    echo "  ${BASE_URL}/<BUILD>/fx.tar.xz" >&2
    exit 1
  fi
  ARTIFACT_URL="${BASE_URL}/${VERSION}/fx.tar.xz"
fi
echo "    Using: ${ARTIFACT_URL}"

echo "==> Downloading and extracting FXServer..."
TMP=$(mktemp -d)
curl -fSL --progress-bar -o "${TMP}/fx.tar.xz" "${ARTIFACT_URL}"
tar -xf "${TMP}/fx.tar.xz" -C "${ARTIFACT_DIR}"
rm -rf "${TMP}"
chmod +x "${ARTIFACT_DIR}/run.sh"

echo "==> Setting ownership..."
chown -R "${FIVEM_USER}:${FIVEM_USER}" "${FIVEM_HOME}"

if [[ "${ENABLE_SSH_ROOT}" == "1" ]]; then
  echo "==> Enabling SSH root login..."
  apt-get install -y -qq openssh-server >/dev/null
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-fivem-root.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
fi

if [[ "${INSTALL_MARIADB}" == "1" ]]; then
  echo "==> Installing MariaDB..."
  if [[ -z "${DB_PASSWORD}" ]]; then
    echo "INSTALL_MARIADB=1 but DB_PASSWORD is empty - aborting." >&2
    exit 1
  fi
  apt-get install -y -qq mariadb-server >/dev/null
  systemctl enable --now mariadb >/dev/null

  echo "==> Creating database '${DB_NAME}' and user '${DB_USER}'..."
  mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

  # Basic hardening (same spirit as mysql_secure_installation, no prompts)
  mysql <<'EOF'
DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
EOF
fi

echo "==> Creating systemd service..."
cat > /etc/systemd/system/fivem.service <<EOF
[Unit]
Description=FiveM FXServer (txAdmin)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${FIVEM_USER}
Group=${FIVEM_USER}
WorkingDirectory=${ARTIFACT_DIR}
ExecStart=${ARTIFACT_DIR}/run.sh +set serverProfile default +set txAdminPort ${TXADMIN_PORT} +set txDataPath ${TXDATA_DIR}
Restart=on-failure
RestartSec=5
# txAdmin needs a pseudo-terminal-free environment; plain simple service is fine
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fivem.service

cat <<EOM

=============================================================================
 Setup complete!
=============================================================================
 Next steps:

 1. Copy your existing data into the container (see SETUP-GUIDE.md):
      txData      -> ${TXDATA_DIR}
      server data -> ${SERVERDATA_DIR}
    then fix ownership:
      chown -R ${FIVEM_USER}:${FIVEM_USER} ${FIVEM_HOME}

 2. Update paths inside ${TXDATA_DIR}/default/config.json
    (serverDataPath and cfgPath must point at ${SERVERDATA_DIR})

 3. Start the server:
      systemctl start fivem
      journalctl -u fivem -f      # watch the logs

 4. Open txAdmin in a browser:
      http://<container-ip>:${TXADMIN_PORT}
    On first launch txAdmin prints a PIN in the logs (journalctl -u fivem)
    unless your migrated txData already contains your admin login.

EOM
if [[ "${INSTALL_MARIADB}" == "1" ]]; then
  cat <<EOM
 MariaDB is installed. Connection string for your server.cfg:
   set mysql_connection_string "mysql://${DB_USER}:<your-db-password>@localhost/${DB_NAME}?charset=utf8mb4"
 Import your old database dump with:
   mysql ${DB_NAME} < /path/to/dump.sql

EOM
fi
if [[ "${ENABLE_SSH_ROOT}" == "1" ]]; then
  echo " SSH root login is enabled - transfer files with scp/sftp as root."
  echo ""
fi
cat <<EOM
 Ports used: 30120 (TCP+UDP, game) and ${TXADMIN_PORT} (TCP, txAdmin panel)
=============================================================================
EOM
