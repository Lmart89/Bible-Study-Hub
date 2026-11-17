# Instalación

Bible Study Hub se instala como **una copia aparte de KOReader** con la app dentro. KOReader, si ya está instalado
en el Kindle, sigue funcionando por separado.

Requisitos comunes:

- Kindle con jailbreak (como para instalar KOReader).
- Una copia **limpia** de KOReader en la versión indicada para tu modelo (abajo).
- Al menos un módulo de Biblia en formato `.ebb` (ver [MODULOS.md](MODULOS.md)).

> Las rutas `D:\` de esta guía son la unidad del Kindle conectado por USB en Windows; en el Kindle corresponden a
> `/mnt/us/`.

---

## Kindle Paperwhite 3 y Kindle táctiles

Base: **KOReader v2025.10**, paquete `koreader-kindlepw2-v2025.10.zip`
(<https://github.com/koreader/koreader/releases/tag/v2025.10>).

### 1. Preparar la carpeta en el PC

1. Descomprime el paquete de KOReader. Obtienes una carpeta `koreader/`.
2. Cámbiale el nombre a `biblestudyhub/`.
3. Copia **encima** el contenido de `kindle-pw3/biblestudyhub/` de este repositorio, aceptando reemplazar archivos:
   - `app/` (nueva)
   - `biblestudyhub.sh` (nuevo)
   - `reader.lua`, `frontend/ui/screensaver.lua`, `frontend/ui/widget/pathchooser.lua` (reemplazan los originales)
4. Opcional, para que pese menos: borra `plugins/*` (la app no carga plugins; deja la carpeta `plugins` vacía),
   `ota/`, `koreader.sh` y las traducciones de `l10n/` que no uses (deja `es`).
5. Pon tus módulos en `biblestudyhub/app/data/`:

   ```
   app/data/biblias/       *.ebb
   app/data/comentarios/   *.ebc
   app/data/diccionarios/  *.ebd
   ```

### 2. Copiar al Kindle

| Desde el PC | Hasta el Kindle |
|---|---|
| `biblestudyhub/` | `D:\biblestudyhub` |
| `kindle-pw3/documents/BibleStudyHub.sh` | `D:\documents\BibleStudyHub.sh` |

Desconecta el Kindle y toca **Bible Study Hub** en la biblioteca.

La primera vez, la app trae desde `/mnt/us/koreader` (si existe) los ajustes de lectura y la base de notas y
favoritos. Después cada carpeta guarda los suyos.

---

## Kindle 3 (Kindle Keyboard)

Base: **KOReader legacy v2026.07.1** para Kindle 3 (paquete `koreader-legacy`, que trae las carpetas `koreader/`,
`extensions/` y `launchpad/`). Requiere **KUAL**: en el Kindle 3 la biblioteca no abre scripts.

### 1. Preparar la carpeta en el PC

1. Descomprime KOReader legacy y toma su carpeta `koreader/`.
2. Cámbiale el nombre a `bsh-k3/`.
3. Copia **encima** el contenido de `kindle-k3/bsh-k3/`, aceptando reemplazar:
   - `app/` (nueva)
   - `koreader.sh`, `reader.lua`, `frontend/ui/screensaver.lua`, `frontend/ui/widget/pathchooser.lua`
4. Opcional: vacía `plugins/` (deja la carpeta), borra `ota/` y las traducciones de `l10n/` salvo `es`.
5. Pon tus módulos en `bsh-k3/app/data/` (mismas subcarpetas que arriba).

### 2. Copiar al Kindle

| Desde el PC | Hasta el Kindle |
|---|---|
| `bsh-k3/` | `D:\bsh-k3` |
| `kindle-k3/extensions/bsh_k3/` | `D:\extensions\bsh_k3` |

Debe existir exactamente `D:\bsh-k3\koreader.sh`. Si la copias dentro de una `D:\bsh-k3` que ya existía, queda
anidada (`D:\bsh-k3\bsh-k3\koreader.sh`) y KUAL no la encuentra.

Abre KUAL: **BSH - K3 → Start BSH - K3**.

### Teclas (Kindle 3)

| Tecla | Qué hace |
|---|---|
| **Home** | Vuelve a la Biblia desde cualquier pantalla (si editas una nota con cambios, pregunta antes) |
| **Back** | Cierra la pantalla actual. En la Biblia, pregunta si salir. En el editor, pregunta si guardar |
| **Back mantenido 5 s** | Cierre de emergencia (guarda la posición de lectura) |
| **Menu** | En la Biblia, el panel lateral; en cada módulo, su menú |
| **Teclas laterales** | Página siguiente / anterior (en la Biblia sigue al capítulo siguiente o anterior) |
| **D-Pad** | Mueve el resaltado entre versículos, resultados, notas, citas u opciones |
| **Botón central** | Abre o ejecuta lo resaltado |
| **Del** | En la lista de notas, borra la nota resaltada (pregunta antes) |
| **G · S · F · N** | En la Biblia: ir a pasaje, buscar, favoritos, notas del pasaje |

---

## Datos del usuario

| Qué | Dónde (en el Kindle) |
|---|---|
| Notas (`.md`) | `/mnt/us/BSH Notes/` (compartida por las dos versiones y por BSH Text Editor) |
| Favoritos, marcas y respaldos de notas | `<carpeta de la app>/settings/bsh_usuario.sqlite` |
| Configuración | `<carpeta de la app>/settings/bsh.conf` y `settings.reader.lua` |
| Libros exportados (AZW3) | `/mnt/us/documents/` |

## Actualizar

- **Por Wi-Fi (recomendado):** Ajustes avanzados → **Actualizaciones** → *Recibir actualización por Wi-Fi*. El Kindle
  muestra una dirección y un código de 4 cifras; ábrela en el navegador del PC o del celular (misma red) y envía el
  paquete `bsh-pw3-<versión>.tar` o `bsh-k3-<versión>.tar`. El Kindle comprueba la huella SHA-256 de cada archivo,
  guarda la versión actual en `app.anterior` y se reinicia. *Volver a la versión anterior* deshace el cambio.
  Un paquete de una versión no se instala en la otra.
- **Por USB:** copia el contenido de `app/` del repositorio sobre la `app/` del Kindle, **sin tocar `app/data`**.

## Importar módulos por Wi-Fi

Ajustes avanzados → **Módulos** → *Administrar módulos* → *Importar por Wi-Fi…* (o *Importar desde el Kindle…*
para archivos ya copiados a `documents`). La app comprueba la marca del formato antes de aceptarlos.

## Si no abre

- `<carpeta de la app>/crash.log`: mensajes de KOReader y de la app.
- Kindle 3: `D:\bsh-k3\arranque.log` registra cada etapa del script de arranque. Si no existe, KUAL no encontró
  `D:\bsh-k3\koreader.sh`. Si termina en «lanzando reader.lua», el problema está en la app (ver `crash.log`).
- Sin módulos de Biblia en `app/data/biblias`, la app no tiene qué mostrar.

## Desinstalar

Borra las dos rutas de la tabla de instalación de tu modelo. Tus notas siguen en `D:\BSH Notes`.
