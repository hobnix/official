# Arcane: keep an existing install running

Arcane is no longer maintained upstream. This recipe only takes over an Arcane that already runs on your server and keeps it updated. For a new setup use [Portainer](portainer.md).

## Before you start
- Docker is on, with an Arcane from the old Docker setting in `/opt/arcane` of the container `docker`.
- A fresh install is refused: the recipe says so and points to Portainer.

## Take over Arcane
```bash
sudo hs recipe arcane
```

The recipe uses `/opt/arcane` where it is: the same data, the same keys (`.env`) and the same port (usually 80). It keeps the old compose file once as `docker-compose.yml.before-recipe` and never writes new keys over stored data. If it finds data but no key, it stops and says how to restore the old compose file. The project belongs to the recipe from then on.

Not tested on hardware yet.

## Check that it worked
- `hs services list` shows Arcane, never public.
- The login of before still works and the projects in `/opt/projects` are still there.

## Update and remove
- Update: run the recipe again; it pulls the image it pins (Arcane 2.17.3) and restarts. Your data stays.
- Remove: stop the project and keep the data in the volume `arcane_arcane-data`:

```bash
sudo hs ct docker exec bash -c 'cd /opt/arcane && docker compose -p arcane down'
```

Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| The recipe says a new install is refused | Arcane is deprecated and there is no install to take over | `sudo hs recipe portainer` |
| The recipe stops with "no ENCRYPTION_KEY" | Stored data but no key to carry over | Restore the old compose file from a snapshot (`incus snapshot list docker`) and run again |
| Logs | | `sudo hs ct docker exec docker logs arcane --tail 30` |

## Next
- [Portainer](portainer.md)
