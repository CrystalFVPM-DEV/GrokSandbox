# Importar eggs en Pterodactyl 1.15.2

Copias listas para importar en Pterodactyl 1.15.2. En este repositorio viven en `aerohost/eggs/`.

Todos los archivos son **PTDL_v2**. Scripts de instalación e imágenes Docker quedan igual que en upstream.

## Antes de importar

1. En Admin → Nests, crea estos nests con estos nombres exactos (en este orden):
   1. AeroHost Minecraft
   2. AeroHost Code
   3. AeroHost Bots
   4. AeroHost Web
   5. AeroHost Dev
   6. AeroHost Voice
2. Entra en cada nest → **Import Egg** y sube los JSON de la carpeta indicada, en el orden de la lista (así quedan ordenados de forma coherente en el panel).
3. Al crear un servidor **Redis** o **PostgreSQL**, el panel exigirá una contraseña: no hay valor por defecto.
4. Comprueba que Wings puede hacer pull de `ghcr.io/ptero-eggs/yolks`, `ghcr.io/pelican-eggs/*`, `ghcr.io/parkervcp/yolks` y `ghcr.io/ym0t/pterodactyl-nginx-egg`.
5. Para **Mumble Premium**, Wings también necesita `ghcr.io/crystalfvpm-dev/aerohost-mumble-premium`. Ese paquete es privado por defecto: ver la sección AeroHost Voice más abajo.

## Nests y archivos

### 1. AeroHost Minecraft

Carpeta: `aerohost/eggs/minecraft/`

| Orden | Archivo | Egg (nombre original) |
| ---: | --- | --- |
| 1 | `egg-paper.json` | Paper |
| 2 | `egg-purpur.json` | Purpur |
| 3 | `egg-fabric.json` | Fabric |
| 4 | `egg-forge-enhanced.json` | Forge Enhanced |
| 5 | `egg-neoforge.json` | NeoForge |
| 6 | `pterodactyl-egg-vanilla-minecraft.json` | Vanilla Minecraft |
| 7 | `egg-velocity.json` | Velocity |
| 8 | `pterodactyl-egg-bungeecord.json` | Bungeecord |
| 9 | `egg-vanilla-bedrock.json` | Vanilla Bedrock |
| 10 | `egg-pocketmine-m-p.json` | PocketmineMP |

### 2. AeroHost Code

Carpeta: `aerohost/eggs/code/`

| Orden | Archivo | Egg (nombre original) |
| ---: | --- | --- |
| 1 | `egg-python-generic.json` | python generic |
| 2 | `egg-node-js-generic.json` | node.js generic |
| 3 | `egg-java.json` | Generic Java |
| 4 | `egg-golang-generic.json` | golang generic |
| 5 | `egg-bun.json` | Bun |

### 3. AeroHost Bots

Carpeta: `aerohost/eggs/bots/`

| Orden | Archivo | Egg (nombre original) |
| ---: | --- | --- |
| 1 | `egg-pterodactyl-red.json` | Red |

Los bots a medida (Discord.js, discord.py, Telegram, etc.) se crean con los eggs del nest **AeroHost Code**.

### 4. AeroHost Web

Carpeta: `aerohost/eggs/web/`

| Orden | Archivo | Egg (nombre original) |
| ---: | --- | --- |
| 1 | `egg-nginx-v3.json` | Pterodactyl Nginx Egg v3 |

Para un sitio estático o SPA, pon `PHP_STATUS=0` al crear el servidor.

### 5. AeroHost Dev

Carpeta: `aerohost/eggs/dev/`

| Orden | Archivo | Egg (nombre original) |
| ---: | --- | --- |
| 1 | `egg-pterodactyl-uptime-kuma.json` | Uptime Kuma |
| 2 | `egg-redis-7.json` | Redis-7 |
| 3 | `egg-pterodactyl-maria-d-b10-3.json` | MariaDB 10.3 |
| 4 | `egg-postgres16.json` | Postgres 16 |

## Cambios aplicados en estas copias

- **Descripción** de los 21 eggs: una línea corta en español, con «— AeroHost».
- **Author:** no se cambió. El panel valida este campo como email (`required|email`). El valor `support@aerohost` no tiene TLD y puede hacer fallar la importación. Se dejaron los autores originales (crédito upstream).
- **Generic Java:** `JARFILE` por defecto `sneakyhub.jar` → `server.jar`.
- **Postgres 16:** usuario por defecto `pelican` → `aerohost`. `PGPASSWORD` sin valor por defecto y con regla `required|string|max:20` (el límite de 20 caracteres es del egg original). La descripción avisa que PostgreSQL escucha en `0.0.0.0` y que hay que restringirlo en el firewall.
- **Redis 7:** `SERVER_PASSWORD` sin valor por defecto (antes `P@55w0rd`) y sigue siendo `required|string`.
- **MariaDB 10.3:** el egg upstream **no tiene variables** (tampoco de contraseña). No se añadió ninguna, porque habría que tocar el script de instalación y el startup, que deben quedar intactos. El arranque original termina en `mysql -u root` sin contraseña. Trátalo como riesgo y no lo expongas a internet.

Scripts de instalación e imágenes: sin cambios.

### 6. AeroHost Voice

Carpeta: `aerohost/eggs/voice/`

| Orden | Archivo | Egg |
| ---: | --- | --- |
| 1 | `egg-mumble-premium.json` | Mumble Premium — AeroHost |

Este egg usa la imagen propia `ghcr.io/crystalfvpm-dev/aerohost-mumble-premium:1.0` (murmur + bot Bragi). El workflow `.github/workflows/aerohost-mumble-premium.yml` la publica en GHCR con las etiquetas `:1.0` y `:latest`.

El repositorio es privado a propósito. Un paquete GHCR creado desde un repo privado queda **privado** por defecto, así que Wings no podrá hacer pull hasta que ocurra una de estas dos cosas:

1. Cambiar **solo** la visibilidad del paquete a Public (el repositorio puede seguir privado): en GitHub → Packages → `aerohost-mumble-premium` → Package settings → Change visibility → Public.
2. Dejar el paquete privado y configurar credenciales de registro en cada nodo Wings, en `/etc/pterodactyl/config.yml`:

```yaml
docker:
  registries:
    ghcr.io:
      username: CrystalFVPM-DEV
      password: "<token con permiso read:packages>"
```

Luego `systemctl restart wings`. El token no debe guardarse en este repositorio.

La allocation de Mumble debe ser **TCP y UDP en el mismo puerto**. Al crear el servidor, la SuperUser Password es obligatoria (mínimo 8 caracteres). El panel no se importa desde este documento: hay que subir el JSON a mano.

