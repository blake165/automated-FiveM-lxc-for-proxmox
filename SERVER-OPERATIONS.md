# Server Operations — Reboots, Outages & Recovery

How the server starts, what happens when things go down, and the commands to
bring it all back. Run commands on the **Proxmox node shell** unless stated
otherwise. Replace `110` with your container ID.

---

## How startup works (the automatic chain)

When everything is healthy, you should never need to start anything by hand:

```
Proxmox host boots
  └─> container 110 auto-starts        (created with --onboot 1)
        └─> MariaDB auto-starts        (systemd: mariadb.service)
        └─> FXServer/txAdmin auto-start (systemd: fivem.service)
              └─> txAdmin auto-starts the game server
                  (if "autostart" is enabled in txAdmin settings)
```

The last link is the one to check: in txAdmin go to **Settings → FXServer**
and make sure server autostart is enabled. Without it, txAdmin comes up after
a reboot but waits for you to press Start.

**Test the chain once** so you trust it: reboot the Proxmox host from the web
UI and time how long until players can connect. Expect roughly 2–5 minutes.

---

## Scenario 1: Proxmox host was shut down / lost power

1. Power the machine back on. Proxmox boots on its own.
2. Wait ~2–5 minutes. The chain above runs automatically.
3. Verify from any browser on your network: `http://<container-ip>:40120`
   — if txAdmin loads and shows the server online, you're done.

If the server is **not** up after 5 minutes, walk the chain:

```bash
pct status 110                          # expect: status: running
pct start 110                           # if it wasn't running
pct exec 110 -- systemctl status fivem  # expect: active (running)
pct exec 110 -- systemctl start fivem   # if it wasn't
pct exec 110 -- journalctl -u fivem -n 50   # read errors if it won't start
```

Then check txAdmin in the browser and press **Start** if the panel is up but
the server isn't.

## Scenario 2: Internet went out (server machine still on)

Nothing crashes — but FiveM needs the internet for more than player traffic:

- **Players obviously can't connect** while you're offline.
- **License validation:** FXServer validates your `sv_licenseKey` with
  Cfx.re. A running server usually rides out short outages, but a server that
  *starts* without internet may fail to come online until connectivity is back.
- **LAN players** can often still play via Direct Connect to the container's
  local IP, since txAdmin/voice/database are all inside your network.

When the internet returns: usually nothing to do. If the server got stuck in
a weird state during the outage, restart it from txAdmin, or:

```bash
pct exec 110 -- systemctl restart fivem
```

If your public IP changed after the outage (common on home connections
without a static IP), players using a saved IP will fail to connect — update
whatever you publish (Discord, server listing). Consider a free dynamic-DNS
hostname so the address never changes for players.

## Scenario 3: Just the container is stopped

```bash
pct start 110
```

Everything inside auto-starts. Done.

## Scenario 4: Server crashed / frozen but container is fine

txAdmin usually restarts a crashed server on its own. If it's truly wedged:

```bash
pct exec 110 -- systemctl restart fivem      # restarts txAdmin + server
```

Nuclear option (reboots the whole container, including MariaDB):

```bash
pct reboot 110
```

---

## Command cheat sheet

| What | Command (on Proxmox node) |
|---|---|
| Container running? | `pct status 110` |
| Start / stop container | `pct start 110` / `pct shutdown 110` |
| Reboot container | `pct reboot 110` |
| FiveM service status | `pct exec 110 -- systemctl status fivem` |
| Start / stop / restart FiveM | `pct exec 110 -- systemctl <start\|stop\|restart> fivem` |
| Live logs | `pct exec 110 -- journalctl -u fivem -f` |
| MariaDB status | `pct exec 110 -- systemctl status mariadb` |
| Shell inside container | `pct enter 110` (exit with `exit`) |
| Container IP | `pct exec 110 -- hostname -I` |

txAdmin panel: `http://<container-ip>:40120` · Game port: `30120` TCP+UDP

---

## Planned shutdowns (doing it cleanly)

Before powering off the Proxmox host for maintenance:

1. txAdmin → **Stop** the server (gives players the shutdown warning and
   saves cleanly), or `pct exec 110 -- systemctl stop fivem`
2. Shut down the host from the Proxmox web UI (**Node → Shutdown**) — this
   gracefully stops all containers, including MariaDB, avoiding database
   corruption from a hard power cut

A UPS (battery backup) on the Proxmox machine is the single best upgrade for
a home-hosted server — it turns power blips from "possible database
corruption" into a non-event.

## Backups (do this before you need it)

In the Proxmox web UI: **Datacenter → Backup → Add**. Schedule a weekly (or
nightly) `vzdump` of the container to your backup storage. One job captures
the entire server — FXServer, txData, resources, *and* the database —
restorable in a couple of clicks from **the container → Backup → Restore**.

For an extra layer, dump the database on a schedule inside the container:

```bash
pct exec 110 -- bash -c "mysqldump YOUR_DB_NAME > /root/db-backup-\$(date +%F).sql"
```

## Updating FXServer artifacts

When txAdmin nags that your artifact is outdated:

```bash
pct exec 110 -- systemctl stop fivem
pct exec 110 -- bash /root/fivem-lxc-setup.sh
pct exec 110 -- systemctl start fivem
```

The setup script re-downloads the recommended build and touches nothing else.
