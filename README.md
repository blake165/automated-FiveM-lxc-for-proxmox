# FiveM LXC for Proxmox — one-command install

Spin up a fully configured FiveM (FXServer + txAdmin) LXC container on Proxmox
with a single command pasted into the node shell.

## One-time repo setup

1. Create a GitHub repo (public is simplest) and upload these files to the root
   of the `main` branch:
   - `proxmox-create-fivem-lxc.sh`
   - `fivem-lxc-setup.sh`
   - `SETUP-GUIDE.md` (optional, for reference)
2. Edit `proxmox-create-fivem-lxc.sh` and set `RAW_BASE` to your repo:
   ```bash
   RAW_BASE="https://raw.githubusercontent.com/blake165/automated-FiveM-lxc-for-proxmox/main"
   ```
   Also change the default `CT_ROOT_PASSWORD`.

## Usage

Paste into the **Proxmox node shell** (as root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_GH_USER/YOUR_REPO/main/proxmox-create-fivem-lxc.sh)"
```

That single command will:
- download the Debian 12 LXC template (if missing)
- create + start an unprivileged container (onboot enabled)
- install FiveM with the latest recommended FXServer artifact inside it
- set up a systemd service so the server survives reboots
- print the container IP and txAdmin URL when done

### Customizing without editing the repo

Every setting can be overridden inline:

```bash
CTID=120 \
HOSTNAME_CT=fivem-prod \
CORES=6 MEMORY=12288 DISK_GB=60 \
IP_CONFIG="192.168.1.50/24" GATEWAY="192.168.1.1" \
CT_ROOT_PASSWORD='something-strong' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_GH_USER/YOUR_REPO/main/proxmox-create-fivem-lxc.sh)"
```

| Variable | Default | Notes |
|---|---|---|
| `CTID` | `110` | must be an unused container ID |
| `HOSTNAME_CT` | `fivem` | container hostname |
| `CORES` / `MEMORY` / `SWAP` | `4` / `8192` / `1024` | MB for memory/swap |
| `DISK_GB` | `40` | rootfs size |
| `STORAGE` | `local-lvm` | rootfs storage |
| `TEMPLATE_STORAGE` | `local` | where CT templates live |
| `BRIDGE` | `vmbr0` | network bridge |
| `IP_CONFIG` | `dhcp` | or static, e.g. `192.168.1.50/24` |
| `GATEWAY` | — | required if static IP |
| `CT_ROOT_PASSWORD` | `ChangeMe123!` | container root password |

## After install — migrating your existing server

Copy your `txData` and server folder into the container (the script prints the
exact commands), point `serverDataPath`/`cfgPath` in
`/home/fivem/txData/default/config.json` at `/home/fivem/server-data`, then:

```bash
pct exec <CTID> -- systemctl start fivem
```

txAdmin: `http://<container-ip>:40120` · Game: port `30120` TCP+UDP.
Full migration details (including MySQL) are in `SETUP-GUIDE.md`.

## Updating FXServer later

```bash
pct exec <CTID> -- systemctl stop fivem
pct exec <CTID> -- bash /root/fivem-lxc-setup.sh
pct exec <CTID> -- systemctl start fivem
```
