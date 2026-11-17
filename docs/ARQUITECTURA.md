# Arquitectura

Bible Study Hub es una app independiente construida **sobre el núcleo de KOReader** (LuaJIT, widgets, UIManager,
controladores de pantalla, entrada, Wi-Fi y energía). No usa el gestor de archivos ni el lector de KOReader, y no
carga plugins.

## Archivos de KOReader que cambian

Todo lo demás de la base de KOReader queda intacto.

### `reader.lua`

Al final del arranque, en lugar de abrir el gestor de archivos o el último libro, abre la app:

```lua
package.path = "app/?.lua;" .. package.path
require("bsh_pw3_app"):abrir()      -- Kindle 3: require("bsh_k3_app")
local exit_code = UIManager:run()
```

### `frontend/ui/screensaver.lua` y `frontend/ui/widget/pathchooser.lua`

Una sola línea en cada uno. Sin gestor de archivos ni lector, `self.ui` quedaba en `nil` y el protector de pantalla
y el selector de carpetas fallaban. Ahora usan la base de la app como último recurso:

```lua
self.ui = require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
    or require("bsh_pw3_base")      -- Kindle 3: require("bsh_k3_base")
```

### Lanzador

- **PW3: `biblestudyhub.sh`** — el `koreader.sh` de KOReader con `KOREADER_DIR=/mnt/us/biblestudyhub`, su propia
  copia en `/var/tmp`, textos de arranque propios y, la primera vez, la copia de ajustes y notas desde
  `/mnt/us/koreader`. `documents/BibleStudyHub.sh` es el *scriptlet* que la biblioteca muestra con icono y llama a
  `biblestudyhub.sh --kual --asap`.
- **K3: `koreader.sh`** — el de KOReader legacy, que fuera de `/var/tmp` siempre usa su propia carpeta (el Kindle puede
  traer `KOREADER_DIR=/mnt/us/koreader` exportado), registra cada etapa en `arranque.log`, trae los datos de una
  instalación anterior la primera vez y avisa a la biblioteca tras exportar libros. Solo ASCII: el `sh` del Kindle 3
  es antiguo. KUAL lo llama desde `extensions/bsh_k3/menu.json`.

## Módulos Lua de `app/`

### Núcleo común (`bsh_*.lua`, iguales en las dos versiones)

| Módulo | Qué hace |
|---|---|
| `bsh_db` | Acceso a los módulos SQLite, consultas y búsqueda FTS5 |
| `bsh_registro` | Descubre y valida los módulos instalados; caché de conexiones |
| `bsh_libros` | Nombres, abreviaturas y grupos de libros bíblicos |
| `bsh_comentario`, `bsh_diccionario` | Pantallas de comentario y diccionario |
| `bsh_notas`, `bsh_usuario`, `bsh_exportar` | Notas en `BSH Notes`, respaldos en SQLite, exportación `.md` |
| `bsh_azw3` | Exportador de notas a AZW3 (KF8) |
| `bsh_word` | Importador de `.docx` a nota |
| `bsh_marcas` | Marcas sencillas de las notas → HTML con formato |
| `bsh_favoritos` | Favoritos en listas personalizadas |
| `bsh_ui` | Componentes de interfaz compartidos (barra superior, filas de menú, vista previa de versículos) |
| `bsh_ajustes_lectura`, `bsh_ajustes_avanzados` | Ajustes de lectura y pantalla completa de ajustes |
| `bsh_conf` | Configuración en `settings/bsh.conf` |
| `bsh_carga`, `bsh_acerca` | Pantalla de carga y «Acerca de» |
| `bsh_importar` | Importación y validación de módulos |
| `bsh_migracion` | Pasa datos y ajustes de nombres anteriores (≤ 1.7) a los actuales |
| `bsh_actualizar`, `bsh_recibir`, `bsh_servidor_web` | Actualización e importación por Wi-Fi: servidor HTTP propio con código de 4 cifras, paquetes `.tar` con manifiesto SHA-256 |
| `bsh_dispositivo` | Contraste, iluminación, modo nocturno, tiempo de reposo y Wi-Fi |

### Capa del Paperwhite 3 (táctil)

`bsh_pw3_app` (arranque, reposo, eventos), `bsh_pw3_base` (sustituto de `self.ui`), `bsh_lector` (lector con
gestos y panel lateral), `bsh_selector` (selector de referencia: libro → capítulo → versículo).

### Capa del Kindle 3 (teclado)

`bsh_k3_app`, `bsh_k3_base`, `bsh_k3_teclas` (Home, Back, Menu, Back mantenido), `bsh_k3_visor` (visor HTML con foco
de D-Pad), `bsh_k3_lector`, `bsh_k3_panel`, `bsh_k3_busqueda`, `bsh_k3_comentario`, `bsh_k3_diccionario`,
`bsh_k3_notas` (con editor), `bsh_k3_favoritos`, `bsh_k3_selector`, `bsh_k3_ajustes_avanzados`.

### Recursos

- `iconos/*.svg` — logo e iconos de formato; `iconos/lanzador.png` (PW3) es el icono de la biblioteca.
- `suspension/suspension.svg` — pantalla de reposo.
- `version.txt` — versión mostrada en Ajustes y usada por el actualizador.

## Paquetes de actualización por Wi-Fi

`bsh-<pw3|k3>-<versión>.tar` (formato USTAR) contiene `manifiesto.txt` y la carpeta `app/` sin `data/`:

```
version 1.8
app bsh-pw3
<sha256>  app/bsh_db.lua
...
```

El Kindle rechaza el paquete si falta un archivo, si una huella no coincide, si una ruta sale de `app/` o si la
línea `app` es de la otra versión.
