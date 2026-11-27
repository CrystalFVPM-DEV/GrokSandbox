# AeroHost — infraestructura

Material de configuración de **AeroHost** (eggs de Pterodactyl e imagen de Mumble Premium). Este repositorio es **privado** a propósito, para evitar fugas de información. El panel de Pterodactyl no se modifica desde aquí: los eggs se importan a mano cuando corresponda.

## Contenido

| Ruta | Qué hay |
| --- | --- |
| `aerohost/eggs/` | Eggs PTDL_v2 listos para importar, con `IMPORT.md` |
| `aerohost/images/mumble-premium/` | Dockerfile e scripts de *Mumble Premium* (murmur + bot de música Bragi) |
| `.github/workflows/aerohost-mumble-premium.yml` | Construye y publica la imagen en GHCR |

## Eggs

Instrucciones detalladas: [`eggs/IMPORT.md`](eggs/IMPORT.md).

Nests previstos, en este orden: **AeroHost Minecraft**, **AeroHost Code**, **AeroHost Bots**, **AeroHost Web**, **AeroHost Dev** y **AeroHost Voice**.

El egg **Mumble Premium — AeroHost** (`eggs/voice/egg-mumble-premium.json`) apunta a:

```text
ghcr.io/crystalfvpm-dev/aerohost-mumble-premium:1.0
```

## Imagen Mumble Premium

Documentación del bot, calidad por defecto, limitaciones de YouTube/Spotify y pasos de importación: [`images/mumble-premium/README.md`](images/mumble-premium/README.md).

Publicación automática (tags `:1.0` y `:latest`) al cambiar archivos en `aerohost/images/mumble-premium/`, o a mano con *workflow_dispatch*. El workflow usa `GITHUB_TOKEN` con `packages: write`.

Como el repositorio es privado, el paquete en GHCR también lo es por defecto. Wings no puede hacer pull sin una de estas dos opciones:

1. **Hacer público solo el paquete** (el repositorio sigue privado): GitHub → Packages → `aerohost-mumble-premium` → Package settings → Change visibility → Public. La API de GitHub no suele permitir este cambio; hay que hacerlo en la interfaz.
2. **Dejar el paquete privado** y dar a Wings un token con permiso `read:packages`, en `/etc/pterodactyl/config.yml` de cada nodo:

```yaml
docker:
  registries:
    ghcr.io:
      username: CrystalFVPM-DEV
      password: "<token con permiso read:packages>"
```

Reiniciar Wings después (`systemctl restart wings`). No guardar ese token en este repositorio.

## Seguridad

No se deben commitear contraseñas, cookies de YouTube (`youtube-cookies.txt`), certificados `.pem` ni ficheros `.env`. El `.gitignore` de la raíz está pensado para evitarlo.
