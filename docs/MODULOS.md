# Módulos

El repositorio **no distribuye textos bíblicos, comentarios ni diccionarios**. Muchas traducciones (por ejemplo la
Reina-Valera 1960) y obras de referencia tienen derechos de autor: convierte e instala solo los que tengas permiso
de usar.

## Formato

Cada módulo es una base **SQLite** con una marca propia, para que la app ignore cualquier otra base:

| Tipo | Extensión | Carpeta en `app/data/` |
|---|---|---|
| Biblia | `.ebb` | `biblias/` |
| Comentario | `.ebc` | `comentarios/` |
| Diccionario | `.ebd` | `diccionarios/` |

La marca:

- `PRAGMA application_id = 0x45424942` («EBIB»)
- `PRAGMA user_version = 1` (versión del formato)
- tabla `meta(clave, valor)` con `tipo` = `biblia` | `comentario` | `diccionario`, además de `nombre` y otros datos.

Tablas principales:

- **Biblia:** `verses(id, book, chapter, verse, text, html, fin_parrafo)` + índice FTS5 `verses_fts(text)` para la
  búsqueda. `book` usa la numeración 1–66 (Génesis = 1, Apocalipsis = 66).
- **Comentario:** `entradas(id, libro, capitulo, verso_desde, verso_hasta, html)`; `capitulo = 0` es la introducción
  al libro y `verso_desde = NULL` cubre el capítulo completo.
- **Diccionario:** `entradas(id, termino, html)` y `variantes(palabra, entrada_id, …)` para la búsqueda de palabras.

La app recorre la carpeta de módulos (y subcarpetas, hasta 3 niveles) y reconoce el tipo por la extensión y la
marca. Los archivos rechazados se anotan en `crash.log`. La carpeta se puede cambiar en Ajustes avanzados; por
defecto es `app/data/`.

## Convertir módulos de theWord

Requiere **Python 3** (solo biblioteca estándar; el SQLite de Python debe tener FTS5, como el de python.org).

```bash
python herramientas/convertir_theword.py ruta/a/mis_modulos/*
```

Según la extensión de entrada:

| theWord | Resultado |
|---|---|
| `.ont`, `.ot`, `.nt` | `modulos/biblias/<abreviatura>.ebb` |
| `.cmt.twm` | `modulos/comentarios/<abreviatura>.ebc` |
| `.dct.twm` | `modulos/diccionarios/<abreviatura>.ebd` |

Por defecto escribe en `modulos/` en la raíz del repositorio (ignorada por git). Usa `--salida otra/carpeta` para
cambiarla. Después copia las subcarpetas a `app/data/` o impórtalas por Wi-Fi desde la app.

Los `.twm` de tipo «libro general» se omiten: la app no los usa.

### Bases ya convertidas como `.sqlite`

Las versiones antiguas de la app usaban `.sqlite` sin marca. Para pasarlas al formato actual sin convertir de
nuevo:

```bash
python herramientas/migrar_formato.py carpeta/data --borrar
```
