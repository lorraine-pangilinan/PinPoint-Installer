# PinPoint update catalog

Appliances download the list of approved Nagios update sets from this folder:

```
https://raw.githubusercontent.com/lorraine-pangilinan/PinPoint-Installer/main/catalog/
```

The address is set in `/etc/pinpoint/updates/updater.conf` on each appliance. Only
`raw.githubusercontent.com` is accepted.

## Why an appliance trusts this folder

Decision of 14 November 2026 (plan §2.1). Manifests are not signed. They are trusted because:

1. Appliances download them only from this repository, over HTTPS with certificate checks.
2. Everyone who can change this repository uses GitHub two-factor authentication, and changes to
   `main` need a second person's review (branch protection).
3. `index.json` lists every manifest with its SHA-256. If one file does not match, the appliance refuses
   the whole download and changes nothing.
4. A manifest that an appliance has already recorded can never change. A correction needs a new ID.
5. Nothing is installed until an admin on that appliance approves the exact update set.

The Nagios source files themselves are downloaded only from the official sites listed in the manifest
(`assets.nagios.com`, `nagios-plugins.org`, GitHub releases) and checked against the SHA-256 in the
manifest.

Ubuntu packages (nginx, Apache, Python, OpenSSL and the rest) are not in this catalog. Ubuntu signs and
installs their security updates itself; `configure-monitoring-updates.sh` turns that on.

## Publishing an update set

1. Copy the newest file in `manifests/` to a new ID, for example `pp-mon-2027.01-1.json`.
2. Change the versions, download URLs and SHA-256 values. Get each SHA-256 from the official download,
   and check that the second official source gives the same value.
3. Set `upgrade_from` to the update sets it may be installed over, and `compatibility.state`
   (`verified` only with staging evidence; otherwise `conditional` with the limitations listed).
4. Run `python3 scripts/catalog-index.py`. It checks every manifest with the appliances' own rules
   and rewrites `index.json`.
5. Open a pull request. A second person reviews it before it is merged into `main`.

Never edit a published manifest. To withdraw one, run
`python3 scripts/catalog-index.py --revoke MANIFEST_ID` and commit the new `index.json`.
