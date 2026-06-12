# Troubleshooting Guide

Real fixes for real problems, collected from an actual Windows → Proxmox LXC
migration of a Qbox server. Commands run on the **Proxmox node shell** unless
stated otherwise. Replace `110` with your container ID.

---

## Installer problems

### "Failed to download fivem-lxc-setup.sh ... 404"
The `RAW_BASE` variable inside `proxmox-create-fivem-lxc.sh` doesn't point at
this repo (or the repo/branch name changed). Edit the script on GitHub and fix:

```bash
RAW_BASE="https://raw.githubusercontent.com/<user>/<repo>/main"
```

Note: raw.githubusercontent.com caches for a few minutes — wait 2-3 min after
committing before re-running.

### "Resolving FXServer artifact... curl: (22) 404"
The FiveM artifact URL changed. The correct Linux listing is:
`https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/`
The setup script uses the `recommended.json` API at that path. If FiveM moves
it again, set `ARTIFACT_URL` at the top of `fivem-lxc-setup.sh` to a full
`fx.tar.xz` URL manually.

### "CTID 110 already exists"
A previous (possibly failed) run created the container. Either pick a new ID
at the wizard prompt, or remove the old attempt:

```bash
pct stop 110; pct destroy 110
```

### perl/locale warnings during install
`Can't set locale`, `Falling back to the standard locale` — harmless Debian
container noise. Ignore.

### "Sum of all thin volume sizes exceeds the size of thin pool"
Proxmox thin provisioning warning: your containers/VMs are *promised* more
disk than physically exists, but only used space counts. Fine — just watch
the storage usage in the Proxmox UI so the pool never actually fills.

---

## txAdmin / server start problems

### txAdmin says "no server.cfg" when starting
Three usual causes, in order of likelihood:

**1. Folders nested one level too deep.** Dragging the `txData` folder *into*
`/home/fivem/txData` in WinSCP creates `/home/fivem/txData/txData/...`.
Find where the file actually is:

```bash
pct exec 110 -- find /home/fivem -maxdepth 4 -name server.cfg
```

If you see a doubled path, flatten it:

```bash
pct exec 110 -- bash -c "mv /home/fivem/txData/txData/* /home/fivem/txData/ && rmdir /home/fivem/txData/txData && chown -R fivem:fivem /home/fivem"
```

**2. txAdmin's data path still points at the old machine** (e.g. `C:/Users/...`).
Fix it in the panel: txAdmin → **Settings → FXServer** → set
**Server Data Folder** to your server folder (e.g.
`/home/fivem/txData/YourProfile.base`) and **CFG File Path** to `server.cfg`.
The panel validates the path live.

**3. You edited config.json while the service was running.** txAdmin keeps its
config in memory and writes it back over your hand-edits. Either use the
Settings page, or stop the service first (`systemctl stop fivem`), edit, start.

Also remember Linux paths are **case-sensitive**: `Qbox_44DACB.base` and
`qbox_44dacb.base` are different folders.

---

## Database problems

### oxmysql: "Access denied for user 'root'@'localhost'" (ER_ACCESS_DENIED_NO_PASSWORD_ERROR)
Your `server.cfg` still has the Windows connection string using `root`. On
Debian, MariaDB's root account uses socket authentication and **cannot** log
in with a password. Use the dedicated user the installer created:

```
set mysql_connection_string "mysql://fivem:YOUR_DB_PASSWORD@localhost/YOUR_DB_NAME?charset=utf8mb4"
```

server.cfg is re-read on every server start — restart from txAdmin after editing.

### qbx_core: "Table 'yourdb.bans' doesn't exist"
The database exists but is empty — you haven't imported your dump yet. Export
from the old machine (HeidiSQL: right-click DB → *Export database as SQL* →
Tables: Create, Data: Insert, single file), copy it over, then:

```bash
pct exec 110 -- bash -c "mysql YOUR_DB_NAME < '/root/dump.sql'"
```

Quote the path if the filename contains spaces.

### Import fails: "ERROR 1062 Duplicate entry ... for key 'PRIMARY'"
A previous partial import already inserted some rows, and `mysql` stops at the
first conflict — everything after that line never imported. Wipe and re-import
into a clean database (stop the FiveM server first):

```bash
pct exec 110 -- bash -c "mysql -e 'DROP DATABASE YOUR_DB_NAME; CREATE DATABASE YOUR_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL ON YOUR_DB_NAME.* TO \"fivem\"@\"localhost\"; FLUSH PRIVILEGES;'"
pct exec 110 -- bash -c "mysql YOUR_DB_NAME < '/root/dump.sql'"
```

### Import fails: "errno: 121 Duplicate key on write or update" (ERROR 1005)
HeidiSQL exports foreign keys with bare numeric names (`CONSTRAINT '1'`), and
MariaDB requires constraint names to be unique per database — two tables using
the same number collide. Strip the names (MariaDB auto-generates unique ones)
and re-import into a clean DB:

```bash
pct exec 110 -- bash -c "sed -i -E 's/CONSTRAINT .[0-9]+. FOREIGN KEY/FOREIGN KEY/g' '/root/dump.sql'"
```

Then drop/recreate/import as above.

### Verify the import worked

```bash
pct exec 110 -- bash -c "mysql -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = \"YOUR_DB_NAME\";'"
```

Compare against the table count HeidiSQL shows on the old machine.

---

## In-game problems

### No voice chat after migration (game sounds fine)
Your voice resource (pma-voice etc.) probably has the **old server's IP**
hardcoded in `voice.cfg` (`voice_externalAddress` / mumble settings), or your
router is forwarding 30120 **TCP only** — mumble voice travels over **UDP**.

1. Check `voice.cfg` in your server data folder for hardcoded IPs and update
   or remove them
2. Confirm the router forwards 30120 **TCP and UDP** to the container IP

### Players can't connect from the internet
Update your router's port forward: 30120 TCP+UDP → the container's IP. Set a
DHCP reservation (or use a static IP) so the container's address never changes.

### Resources error about missing tables for one specific script
That resource's tables weren't in your dump (some scripts create their own on
first run — start the server once and check again) or the dump was partial —
re-export including all tables.

---

## General debugging

```bash
pct exec 110 -- systemctl status fivem        # is the service running?
pct exec 110 -- journalctl -u fivem -f        # live server logs
pct exec 110 -- journalctl -u fivem -n 200    # last 200 log lines
pct enter 110                                  # shell inside the container
```

txAdmin's own live console (web panel → Live Console) shows resource-level
errors that journalctl may truncate.
