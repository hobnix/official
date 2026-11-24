# Portainer: look after your Docker containers

Run Portainer inside the Docker container of your server to see and manage its containers, images and stacks in a browser. It is an admin page for the home network and never gets a public route.

## Before you start
- Docker is on: `sudo hs docker enable` (see [Containers and apps](containers-and-apps.md)).
- Portainer is optional. The Docker page of the web interface works without it.

## Set up Portainer
```bash
sudo hs recipe portainer
```

The recipe runs Portainer as a compose project in the share `apps` (folder `recipes/portainer`, mounted at `/shares/apps` in the container `docker`) and prints the address of the page (port 9000). Open it right away: Portainer asks for the admin account at the first visit and waits only about 5 minutes after it starts.

Not tested on hardware yet.

## Take over an existing install
A server that got Portainer from the old Docker setting keeps it running through `hs update`. Run the recipe to let it look after that install:

```bash
sudo hs recipe portainer
```

The recipe finds `/opt/portainer` in the container `docker` and uses it where it is: the same data, the same port (usually 80). It keeps the old compose file once as `docker-compose.yml.before-recipe`. The project belongs to the recipe from then on.

Not tested on hardware yet.

## Check that it worked
- `hs services list` shows Portainer, never public.
- The address answers in the browser and the login page appears.

## Update and remove
- Update: run the recipe again; it pulls the image it pins and restarts. Your data stays.
- Remove: stop the project and keep the data in the volume `portainer-data`:

```bash
sudo hs ct docker exec bash -c 'cd /shares/apps/recipes/portainer && docker compose -p portainer down'
```

For a taken-over install the folder is `/opt/portainer` instead. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| The page says it timed out | Portainer waits only 5 minutes for the first account | `sudo hs ct docker exec docker restart portainer`, then open the page again |
| The recipe says Docker is not on | The container `docker` is off | `sudo hs docker enable` |
| The recipe says the port is used | Another Docker app has port 9000 | Run it again and give another port |
| Logs | | `sudo hs ct docker exec docker logs portainer --tail 30` |

## Next
- [Containers and apps](containers-and-apps.md)
