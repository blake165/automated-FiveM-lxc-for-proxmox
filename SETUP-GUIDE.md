# FiveM LXC on Proxmox — Setup & Migration Guide

This guide pairs with `fivem-lxc-setup.sh`. Part 1 runs on the **Proxmox host**,
Part 2 runs **inside the container**, Part 3 migrates your existing server.

---

## Part 1 — Create the container (on the Proxmox host)

Download a template if you don't have one yet:

```bash
pveam update
pveam available | grep debian-12
pveam download local debian-12-standard_12.7-1_amd64.tar.zst
```

Create the container (adjust `100`, storage names, bridge, and resources to taste —
FiveM likes 4 cores / 8 GB RAM for a populated server, more if you run lots of resources):

```bash
pct create 100 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname fivem \
  --cores 4 \
  --memory 8192 \
  --swap 1024 \
  --rootfs local-lvm:40 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1

pct start 100
```

Notes:
- An **unprivileged** container works fine for FiveM. `nesting=1` is recommended.
- Use a **static IP** (or DHCP reservation) so port forwards don't break:
  replace `ip=dhcp` with e.g. `ip=192.168.1.50/24,gw=192.168.1.1`.
- `--onboot 1` makes the container start with Proxmox; the systemd unit inside
  starts FiveM with the container — fully automated boot chain.

## Part 2 — Run the setup script (inside the container)

Push the script in and run it:

```bash
# on the Proxmox host
pct push 100 fivem-lxc-setup.sh /root/fivem-lxc-setup.sh
pct enter 100

# now inside the container
bash /root/fivem-lxc-setup.sh
```

The script installs dependencies, downloads the latest recommended FXServer
artifact, and creates a `fivem.service` systemd unit (enabled, not yet started).

## Part 3 — Migrate your existing txData and server folder

### 3.1 Copy the data in

**Option A — from the Proxmox host** (if you've copied the folders to the host first):

```bash
# tar them up on your current server, move to the Proxmox host, then:
pct push 100 txdata.tar.gz /tmp/txdata.tar.gz
pct push 100 serverdata.tar.gz /tmp/serverdata.tar.gz
pct enter 100
tar -xzf /tmp/txdata.tar.gz -C /home/fivem/txData --strip-components=1
tar -xzf /tmp/serverdata.tar.gz -C /home/fivem/server-data --strip-components=1
```

**Option B — straight over the network** (current server → container, easiest if
your current server is Linux or you have WSL/scp on Windows):

```bash
# from your current FiveM machine
scp -r ./txData root@<container-ip>:/home/fivem/txData
scp -r ./server-data root@<container-ip>:/home/fivem/server-data
```

Then fix ownership (inside the container):

```bash
chown -R fivem:fivem /home/fivem
```

### 3.2 Fix paths in txAdmin's config

txAdmin stores absolute paths from your old machine. Edit:

```bash
nano /home/fivem/txData/default/config.json
```

Find and update (Windows paths like `C:\\FXServer\\server-data` are common here):

- `"serverDataPath"` → `"/home/fivem/server-data"`
- `"cfgPath"` → `"/home/fivem/server-data/server.cfg"`

(In newer txAdmin versions these live under the `server` section of the config;
the key names are the same.)

If the folder name inside txData isn't `default` (e.g. `myserver`), either rename
it to `default` or change `serverProfile` in `/etc/systemd/system/fivem.service`
to match, then `systemctl daemon-reload`.

Also check `server.cfg` for any absolute paths or `exec` lines that referenced
your old machine's layout.

### 3.3 Database (if your server uses one)

If your resources use MySQL (oxmysql, mysql-async, ESX/QBCore), you also need to
migrate the database:

```bash
# inside the container
apt install -y mariadb-server
mysql_secure_installation

mysql -e "CREATE DATABASE fivem; CREATE USER 'fivem'@'localhost' IDENTIFIED BY 'CHANGE_ME'; GRANT ALL ON fivem.* TO 'fivem'@'localhost'; FLUSH PRIVILEGES;"

# dump on the old machine: mysqldump -u root -p yourdb > dump.sql
mysql fivem < /tmp/dump.sql
```

Then update the connection string in `server.cfg`:

```
set mysql_connection_string "mysql://fivem:CHANGE_ME@localhost/fivem?charset=utf8mb4"
```

## Part 4 — Start and verify

```bash
systemctl start fivem
journalctl -u fivem -f
```

Open **http://\<container-ip\>:40120** — if your txData migrated cleanly, your
existing txAdmin login and server config will all be there. Start the server
from the txAdmin panel (or it will auto-start if you had autostart enabled in
txAdmin previously).

### Port forwarding (for players outside your LAN)

Forward on your router to the container IP:

| Port  | Protocol | Purpose        |
|-------|----------|----------------|
| 30120 | TCP+UDP  | Game server    |
| 40120 | TCP      | txAdmin (only if you want remote admin — otherwise keep it LAN-only) |

## Maintenance

**Update FXServer artifact** (txAdmin will nag you when outdated): just re-run
the setup script — it re-downloads the newest build into `/home/fivem/artifact`
and leaves your txData/server-data untouched. Stop the server first:

```bash
systemctl stop fivem
bash /root/fivem-lxc-setup.sh
systemctl start fivem
```

**Backups**: snapshot the whole container from Proxmox (`vzdump` / Proxmox Backup
Server), or at minimum back up `/home/fivem/txData`, `/home/fivem/server-data`,
and your database dumps.
