# Mumble Premium — AeroHost

Egg PTDL_v2 de Pterodactyl que arranca **mumble-server (murmur)** y un bot de música **en el mismo contenedor**. El bot responde en **inglés**.

- Egg listo para importar: `aerohost/eggs/voice/egg-mumble-premium.json`
- Imagen: este directorio (`Dockerfile`).
- Publicación: workflow `.github/workflows/aerohost-mumble-premium.yml` → `ghcr.io/crystalfvpm-dev/aerohost-mumble-premium:1.0` y `:latest`.
- El panel **no** se toca desde este repositorio.

## Bot elegido: Bragi (storm/bragi, etiqueta `2026.08.31`)

Se comparó el estado de mantenimiento y las funciones reales (búsqueda + enlace):

| Proyecto | Estado (nov 2026) | Por qué se aceptó o se descartó |
| --- | --- | --- |
| **Bragi** (fork de botamusique, git.stormux.org/storm/bragi) | Etiquetas hasta **2026.08.31**, Python 3.13, yt-dlp | **Elegido.** `!yplay` / `!ysearch` (YouTube por búsqueda), `!url` / `!play` (enlace), SoundCloud y otras webs que soporte yt-dlp, radio, volumen, canal, idioma `en_US`, stereo, ducking. |
| botamusique (azlux) | Archivado (~2024); última release 7.2.3 (jun 2023) | Funcional, pero sin mantenimiento. Bragi es su sucesor activo. |
| mumzic (iotku) | Commits hasta **2026-11-09**, imagen Docker oficial | Muy vivo, ligero (Go). `!play` acepta URL de YouTube/SoundCloud, pero **`!search` es solo para archivos locales**, no hay búsqueda en YouTube. No cubre el requisito de “reproducir buscando”. |
| MumbleDJ y forks | El original está archivado (2021). Forks recientes suelen pedir API key de YouTube | Peor experiencia de búsqueda y más fricción de claves. |
| TS3AudioBot y similares | Pensados para TeamSpeak | No es un bot de Mumble. |
| Mumtify | Solo Spotify Connect | No sirve como bot general de búsqueda/enlace. |

Comandos principales del bot (prefijo `!`, respuestas en inglés):

- `!yplay <búsqueda>` — busca en YouTube y reproduce el primer resultado
- `!ysearch <consulta>` — muestra una lista corta para elegir
- `!url <enlace>` o `!play <enlace>` — YouTube, SoundCloud u otra URL de yt-dlp
- `!volume 0-100`, `!pause`, `!stop`, `!skip`, `!queue`, `!radio`, `!rbquery`, `!help`

## Imagen Docker

No hay un yolk público que combine murmur + un bot de música mantenido. El egg de Mumble existente usa `ghcr.io/parkervcp/yolks:voice_mumble` (solo el servidor). Por eso hay un **Dockerfile propio** en este directorio:

- Base: `debian:trixie-slim`
- `mumble-server` 1.5.x (paquete Debian), ffmpeg, libopus, Python 3
- Bragi `2026.08.31` en `/opt/bragi` con venv; yt-dlp se instala/actualiza en ese venv
- Entrypoint estilo Pterodactyl (usuario `container`, `/home/container`)
- `start-premium.sh` aplica las variables del panel, reescribe `port=$SERVER_PORT` en `/home/container/murmur.ini` (y quita duplicados u overrides en `murmur.sqlite`), arranca murmur con **`-ini /home/container/murmur.ini`**, comprueba que escucha en `$SERVER_PORT`, espera a que acepte TLS, y arranca Bragi contra **`127.0.0.1:$SERVER_PORT`** (nunca `SERVER_IP` ni un fallback a `64738` si `SERVER_PORT` está definido). El host y el puerto de conexión se registran en consola.

La imagen se publica en:

```text
ghcr.io/crystalfvpm-dev/aerohost-mumble-premium:1.0
ghcr.io/crystalfvpm-dev/aerohost-mumble-premium:latest
```

Ese es el tag que ya apunta el egg. Construcción local (opcional):

```bash
cd aerohost/images/mumble-premium
docker build -t ghcr.io/crystalfvpm-dev/aerohost-mumble-premium:1.0 .
```

En un repositorio privado el paquete GHCR queda privado por defecto. Ver las opciones de pull para Wings en `aerohost/README.md`.

Calidad por defecto:

- Murmur: `bandwidth=558000` (máximo / default oficial), `opusthreshold=0` (Opus siempre), `users=40`
- Bot: `bandwidth=200000`, `stereo=True`, volumen 80, ducking activado

Las contraseñas **no** van hardcodeadas en el egg ni en la imagen. `SERVER_PASSWORD` puede quedar vacía (servidor abierto). `SUPERUSER_PASSWORD` es obligatoria al crear el servidor (mínimo 8 caracteres) y se aplica en cada arranque.

## Pasos exactos de importación (cuando la imagen esté publicada)

1. Construye y publica `ghcr.io/crystalfvpm-dev/aerohost-mumble-premium:1.0`, o carga esa imagen en **cada** nodo Wings (`docker load` / `docker pull`).
2. En el panel: **Admin → Nests**. Si no existe, crea el nest **AeroHost Voice**.
3. Entra en **AeroHost Voice → Import Egg** y sube  
   `aerohost/eggs/voice/egg-mumble-premium.json`.
4. Crea un servidor con este egg.
5. Asigna una allocation **TCP y UDP en el mismo puerto** (Mumble usa ambos). El puerto del egg (`SERVER_PORT`) debe coincidir con esa allocation; no es editable por el usuario.
6. En variables, pon una **SuperUser Password** (obligatoria). Opcional: contraseña del servidor, nombre del bot, volumen (1–100) y canal del bot (déjalo vacío para Root; si pones p. ej. `Music`, crea ese canal en Mumble antes).
7. Arranca el servidor. El arranque está listo cuando el log muestra `Server listening on`. El bot se conecta a continuación a `127.0.0.1`.
8. Conecta con el cliente Mumble, entra como `SuperUser` con la contraseña, registra tu usuario y ajusta ACLs si hace falta.

Esta tarea no importó el egg ni tocó el panel.

## Cómo usar el bot y límites de las plataformas

- **YouTube y SoundCloud** (y la mayoría de sitios que soporta [yt-dlp](https://github.com/yt-dlp/yt-dlp)): búsqueda (`!yplay` / `!ysearch`) y enlace (`!url` / `!play`).
- **Spotify: no hay streaming nativo.** No existe una API oficial de stream utilizable aquí, y el audio de Spotify va con DRM. Un enlace `open.spotify.com` **no** se va a descargar con yt-dlp. La forma honesta de usarlo es copiar el nombre del tema/artista y lanzar `!yplay never gonna give you up rick astley` (se resuelve como búsqueda en YouTube). No se ha implementado un “traductor” automático de enlaces Spotify → YouTube; si se añade más adelante, seguiría siendo una búsqueda, no el audio de Spotify.
- **YouTube vs IPs de datacenter:** YouTube suele bloquear o pedir captcha/cookies a IPs de hosting. Si `!yplay` / `!ysearch` fallan, exporta cookies de un navegador ya logueado (formato Netscape) a `youtube-cookies.txt` en la raíz de archivos del servidor y reinicia. Bragi tomará ese archivo automáticamente. Esto puede dejar de funcionar si Google rota las cookies o endurece el bloqueo; no hay garantía en un VPS.
- Radio: `!radio` (emisora configurada) y `!rbquery` (radio-browser.info).
- Archivos locales: sube audio a la carpeta `music/` y usa `!play` / `!file`.

## Prueba local

Script: `./local-test.sh` en este directorio (requiere Docker). Comprueba que la imagen construye, que murmur escucha, que Bragi se conecta a `127.0.0.1` y que `yt-dlp` completa una búsqueda `ytsearch1:`.


## Resultado de la prueba local (26 nov 2026, America/Santiago)

Docker 26.1.5 se instaló en la caja y se construyó `aerohost-mumble-premium:test` (sin push).

- **murmur** 1.5.735 escuchó en `0.0.0.0:26438` (`Server listening on`).
- Se aplicó la contraseña SuperUser con `mumble-server -supw` (valor solo de prueba, no va en el egg).
- **Bragi** se conectó a `127.0.0.1:25566` como `AeroHost DJ` con `SERVER_IP=54.37.59.143` (murmur: `Authenticated`; bot: `Initialization complete`). También se verificó antes en `26438`.
- **yt-dlp 2026.11.23** resolvió `ytsearch1:never gonna give you up` → `Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster) [youtube]` (sin descargar).
- Avisos esperables, no bloqueantes: fallo de Zeroconf/Avahi dentro del contenedor, y `Failed to set IPV6_RECVPKTINFO` al bindear solo IPv4.

El panel no se tocó. La imagen no se publicó.


## Archivos de este directorio

| Archivo | Uso |
| --- | --- |
| `Dockerfile` | Imagen runtime (murmur + Bragi) |
| `entrypoint.sh` | Entrypoint estilo yolk / Pterodactyl |
| `start-premium.sh` | Arranque: config, `-supw`, murmur, bot |
| `apply_config.py` | Escribe `murmur.ini` y `configuration.ini` desde variables de entorno (sin imprimir secretos) |
| `murmur.ini.template` | Plantilla HQ de murmur |
| `local-test.sh` | Prueba local con Docker |

Datos persistentes del servidor (volumen `/home/container`): `murmur.ini`, `murmur.sqlite`, `murmur.log`, `configuration.ini`, `bragi.pem`, `bragi.log`, `settings.db`, `music/`, `tmp/`, y opcionalmente `youtube-cookies.txt`.
