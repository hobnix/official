# SABnzbd: the Usenet downloader

Set up SABnzbd so that Radarr and Sonarr can send their downloads to it and it unpacks them into your library share.

## Before you start
- A Usenet provider (an account you pay for yourself) and an indexer ([Prowlarr](prowlarr.md)). A VPN is not needed for Usenet.
- The share `media` and the overview of the film apps: [Films and series on autopilot](jellyfin.md).
- What you download is your decision and your responsibility: the recipe installs the tool only.

## Set up SABnzbd
```bash
sudo hs recipe sabnzbd
```

The recipe creates the container `sabnzbd`, mounts the share `media` read-write at `/media` and prints the address of the page (port 8080 unless you chose another). Finished downloads land in `/media/downloads/usenet/complete`, the same path Radarr and Sonarr use, so they move a finished download into the library by a hard link. Unfinished downloads stay in `/var/tmp/sab-incomplete` inside the container (SSD pool), which the backup skips. This is an admin page for the home network: never give it a public route.

## Connect your provider
Open SABnzbd. The first-run wizard asks for your provider: server, port 563, SSL, user, password, connections (20 to 30). Press **Test Server**. The recipe never asks for the provider's login.

The recipe has already set these through SABnzbd's API (the first run only; later changes of yours stay):
- The folders. Check them under **Config > Folders**. Note the **API Key** under **Config > General**.
- The categories `movies` and `tv` exist already; Radarr and Sonarr name them.
- The host name of the container goes into `host_whitelist`. For other names use **Config > Special > host_whitelist**.
- Encrypted RAR files are aborted, so Radarr and Sonarr try another release (**Config > Switches > Action when encrypted RAR is downloaded**).
- A notification script (`hs-media-notify.py`) posts queued, finished and failed downloads to ntfy and Matrix. Disk full, errors and warnings: tick them yourself under **Config > Notifications**.

## Connect Radarr and Sonarr
In each app add the download client under **Settings > Download Clients > SABnzbd**: the address of `sabnzbd`, its port, the API key, category `movies` (Radarr) or `tv` (Sonarr). See [Radarr](radarr.md) and [Sonarr](sonarr.md).

## Check that it worked
- `hs services list` shows SABnzbd with its container and port.
- A test download shows in the queue and ends in `/media/downloads/usenet/complete`.

## Update and remove
- Update: run the recipe again (`sudo hs recipe sabnzbd`); it fetches the newer image and restarts. Your settings stay.
- Remove: `sudo hs ct sabnzbd remove` asks you to type the container's name and deletes the container with its settings and databases. The share `media` and your files are not touched. Restore from the backup with `hs backup`.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Download does not start | Provider not reachable | **Test Server** in the wizard; SABnzbd **Status** |
| Finished download stays in `downloads` | Radarr or Sonarr and SABnzbd do not see `/media` the same way | **Activity > Queue** in the app shows the import error |
| The page answers on the address only | The domain name is not in `host_whitelist` | **Config > Special > host_whitelist** |
| Folders or messages not set | The API call failed at setup | The recipe printed the manual steps: **Config > Folders** and **Config > Notifications** |
| Logs | | `sudo hs ct sabnzbd logs 100` |

## Next
- [Films: Radarr](radarr.md)
- [Series: Sonarr](sonarr.md)
- [Films and series on autopilot](jellyfin.md)
