# Portainer CE LTS automatic updater

`update.sh` installs a small host-side systemd service and timer that safely
keeps one Portainer Community Edition container on the
`portainer/portainer-ce:lts` release track.

The updater checks daily, does nothing when the image has not changed, and
backs up Portainer's data before it replaces the container. It verifies the
new instance through `/api/status` and automatically restores the prior data
and image if the update fails.

## Expected Portainer configuration

This project intentionally targets the following existing setup:

- container: `portainer`
- volume: `portainer_data`, mounted at `/data`
- Docker socket: `/var/run/docker.sock`
- HTTP port: `127.0.0.1:9000` mapped to container port `9000`
- restart policy: `always`

The recreated container uses exactly those settings. This is not a generic
configuration-preserving updater: if your Portainer container uses different
ports, TLS on `9443`, Edge Agent tunneling on `8000`, extra labels, networks,
environment variables, or bind mounts, adapt the script before installing it.

## Prerequisites

- A Linux host using systemd
- Docker Engine with a running container named `portainer`
- An existing Docker volume named `portainer_data`
- Portainer reachable locally at `http://127.0.0.1:9000/api/status`
- Root access
- `bash`, `curl`, `find`, `flock`, `grep`, `install`, `journalctl`, `sort`,
  `systemctl`, and `tar`

## Install

Download the script from a tagged release, review it, and run it as root:

```bash
curl -fLO https://github.com/mjdelro/portainer-update.sh/releases/latest/download/update.sh
chmod +x update.sh
sudo ./update.sh
```

The installer validates the expected container and volume, installs and
enables the timer, and immediately runs the first update check. Re-running the
installer safely refreshes the installed updater and systemd units.

## What gets installed

| Path | Purpose |
| --- | --- |
| `/usr/local/sbin/update-portainer` | The root-only update command |
| `/etc/systemd/system/portainer-update.service` | One-shot update service |
| `/etc/systemd/system/portainer-update.timer` | Daily scheduler |
| `/var/backups/portainer/` | Root-only, timestamped data backups |

The timer runs once per day. `Persistent=true` catches up after downtime, and
`RandomizedDelaySec=1h` spreads the check across the first hour after its
scheduled time. A lock prevents overlapping manual and scheduled runs.

## Update safety

For every check, the updater pulls `portainer/portainer-ce:lts` and compares
the running container's image ID with the pulled image ID. If they match, it
leaves the container running and only applies backup rotation.

When the image differs, it reads both Portainer versions. It refuses to
replace the container if either version cannot be verified or if the LTS
version is older than the installed version. This avoids an accidental
downgrade when moving from another release track.

For an actual update, it stops Portainer, creates and verifies a compressed
backup of `portainer_data`, removes only the `portainer` container, and starts
the LTS image with the expected configuration. The health check polls
`http://127.0.0.1:9000/api/status` for up to 60 seconds.

If container creation or the health check fails, the updater removes the
failed container, restores the just-created data backup, recreates Portainer
from the exact previous image ID, and health-checks it again. The service still
reports the failed update so the failure remains visible in systemd and the
journal. A failed update's backup is retained.

## Backups and rotation

Backups are stored as:

```text
/var/backups/portainer/portainer-data-YYYYMMDD-HHMMSS.tar.gz
```

The directory and files are root-only. After a successful update—or a check
where Portainer is already current—the updater keeps the five newest matching
archives. Rotation does not run after a failed update.

These archives protect Portainer's configuration database. They do not back
up the applications, databases, or volumes managed through Portainer.

## Operations

Run an update check now:

```bash
sudo systemctl start portainer-update.service
```

Inspect the service and next scheduled run:

```bash
systemctl status portainer-update.service
systemctl list-timers portainer-update.timer
```

Read update logs:

```bash
sudo journalctl -u portainer-update.service
```

List retained backups and check the running version:

```bash
sudo ls -lh /var/backups/portainer/
sudo docker exec portainer /portainer --version
```

## Uninstall

Disable scheduling and remove only the installed automation:

```bash
sudo systemctl disable --now portainer-update.timer
sudo rm -f /etc/systemd/system/portainer-update.timer
sudo rm -f /etc/systemd/system/portainer-update.service
sudo rm -f /usr/local/sbin/update-portainer
sudo systemctl daemon-reload
```

This leaves the running Portainer container, its image, its volume, and all
backups intact. If you explicitly want to delete the backups afterward:

```bash
sudo rm -rf /var/backups/portainer
```

## Scope and safety notes

The updater only pulls Portainer's LTS image, stops/removes/recreates the
container named `portainer`, and reads/writes the `portainer_data` volume and
its dedicated backup directory. It does not run broad Docker prune commands
and does not stop, remove, restart, or back up any other container or volume.

Because Portainer can migrate its internal database during an upgrade, keep
independent host backups as well. Test the updater and recovery process before
relying on it for production use.

## License

This project is dedicated to the public domain under [CC0 1.0](LICENSE).
