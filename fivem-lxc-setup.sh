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

 Ports used: 30120 (TCP+UDP, game) and ${TXADMIN_PORT} (TCP, txAdmin panel)
=============================================================================
EOM
