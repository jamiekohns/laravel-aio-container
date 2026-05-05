For daily development of Laravel projects, this builds an image on `php-fpm` (v8.3),
adding `nginx`, and including Node/npm, Microsoft SQL Server support, mailparse and LDAP.

Together with Portainer and Traefik, you can build a multi-project local development environment.

# Build Project Container
```bash
  docker build \
  -t laravel-php83-fpm-nginx-mailparse \
  --build-arg INSTALL_MAILPARSE=true \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  .
```

# Run Traefik
```bash
docker network create web 2>/dev/null || true

docker run -d \
  --name traefik \
  --restart unless-stopped \
  -p 80:80 \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --network web \
  traefik:v3.6.2 \
  --api.dashboard=true \
  --api.insecure=true \
  --providers.docker=true \
  --providers.docker.exposedbydefault=false \
  --entrypoints.web.address=:80
```

# Run Docker GUI Container

A local GUI for Docker control can be useful. Two options are Portainer and Dockhand.

The `docker run` coommands below include labels for Traefik, so that they will be available on
`portainer.localhost` and `dockhand.localhost`, respectively (run both if you like).

## Portainer
```bash
docker run -d \
  --name portainer \
  --restart always \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  --network web \
  -l 'traefik.enable=true' \
  -l 'traefik.http.routers.portainer.rule=Host("portainer.localhost")' \
  -l 'traefik.http.routers.portainer.entrypoints=web' \
  -l 'traefik.http.services.portainer.loadbalancer.server.port=9000' \
  portainer/portainer-ce:latest
 ```

## Dockhand
```bash
docker run -d \
  --name dockhand \
  --restart unless-stopped \
  -p 3123:3000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v dockhand_data:/app/data \
  --network web \
  -l 'traefik.enable=true' \
  -l 'traefik.http.routers.portainer.rule=Host("dockhand.localhost")' \
  -l 'traefik.http.routers.portainer.entrypoints=web' \
  -l 'traefik.http.services.portainer.loadbalancer.server.port=3000' \
  fnsys/dockhand:latest
 ```

# Run Project Container
See also ".bashrc docker wrapper", below.

## Set APP_DIR and APP_SUBDOMAIN for your Laravel project on host
```bash
APP_DIR="/path/to/your/laravel-app"
APP_PORT=32770
APP_SUBDOMAIN="your-subdomain"

docker run -d \
  --name "$APP_SUBDOMAIN" \
  --network web \
  -p "$APP_PORT:80" \
  -v "$APP_DIR:/var/www/html" \
  -l traefik.enable=true \
  -l traefik.docker.network=web \
  -l "traefik.http.routers.${APP_SUBDOMAIN}.rule=Host(\`${APP_SUBDOMAIN}.localhost\`)" \
  -l traefik.http.routers.${APP_SUBDOMAIN}.entrypoints=web \
  -l traefik.http.services.${APP_SUBDOMAIN}.loadbalancer.server.port=80 \
  laravel-php83-fpm-nginx
```

# (Optional) Run MS SQL Server (2022 linux)
```
docker run -d \
  --name sql2022 \
  -e ACCEPT_EULA=Y \
  -e MSSQL_SA_PASSWORD='SuperSecretPassword!1' \
  -p 1433:1433 \
  -v sql2022data:/var/opt/mssql \
  mcr.microsoft.com/mssql/server:2022-latest
```

- Connect SQL Server Management Studio from Windows on: `Server Name: tcp:[::1],1433`



# docker wrapper script
The docker wrapper adds some basic orchestration functions to your bash environment.

> To use, include the `bash/docker.sh` script in your `.bashrc` file

This will add the `doctrl` function, providing interactive control of docker containers.

- `doctrl enter`: enter interactive shell as `dev` user
- `doctrl run`: start new container instance
- `doctrl build`: build the default docker image (`laravel-php83-fpm-nginx-mailparse`)
- `doctrl reload`: reload container after image rebuild

`doctrl` without arguments will provide basic start/stop and enter functionality
