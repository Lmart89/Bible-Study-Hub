<p align="center">
  <img src="logo.svg" alt="Bible Study Hub" width="140">
</p>

<h1 align="center">Bible Study Hub</h1>

<p align="center">
  Herramienta de estudio bíblico para lectores electrónicos Kindle, basada en <a href="https://github.com/koreader/koreader">KOReader</a>.
</p>

---

**Bible Study Hub (BSH)** es una app independiente para el Kindle: se abre desde la biblioteca o desde KUAL, sin
pasar por KOReader, y usa su núcleo (widgets, UIManager, controladores del dispositivo) como base. Incluye Biblia,
comentarios, diccionarios, notas, favoritos, búsqueda y exportación de notas a libro Kindle (AZW3).

## Versiones

| Carpeta | Dispositivo | Base de KOReader | Versión |
|---|---|---|---|
| [`kindle-pw3/`](kindle-pw3/) | Kindle Paperwhite 3 y Kindle táctiles (paquete `kindlepw2`) | KOReader **v2025.10** | 1.8 |
| [`kindle-k3/`](kindle-k3/) | Kindle 3 / Kindle Keyboard (teclado y D-Pad, sin pantalla táctil) | KOReader legacy **v2026.07.1** | 1.8 |

Las dos comparten el mismo núcleo (`bsh_*.lua`); cada una tiene su capa propia (`bsh_pw3_*` táctil, `bsh_k3_*`
teclado).

## Funciones

- **Lector de la Biblia** con formato, navegación por capítulos y versículos, y ajustes de letra, márgenes,
  interlineado y alineación.
- **Comentarios y diccionarios** consultables desde cada versículo, con vista previa flotante de las citas.
- **Búsqueda** de texto completo (SQLite FTS5) con alcance (*Dónde*: testamentos, grupos de libros, libro actual o
  libros elegidos) y modo (*Cómo*: todas las palabras, alguna, frase exacta, parcial o avanzada).
- **Notas** en Markdown en la carpeta `BSH Notes`, libres o vinculadas a un versículo, con respaldos y papelera.
- **Exportar notas a AZW3**, que la biblioteca del Kindle abre como un libro.
- **Importar bosquejos de Word (.docx)** como notas (Kindle 3).
- **Favoritos** y marcas de versículos.
- **Servidor Wi-Fi propio** (funciona sin Internet, también con el hotspot del celular) para recibir
  actualizaciones de la app y módulos desde el navegador del PC o del celular.
- **Ajustes avanzados**: red, módulos, contraste, modo nocturno, luz y tiempo de reposo.
- **Pantalla de reposo** propia.

## Instalación rápida

BSH **no es un plugin**: es la carpeta `app/` más unos pocos archivos de KOReader modificados, que se copian
**encima de una copia limpia de KOReader** para el Kindle. Los pasos completos están en
[docs/INSTALACION.md](docs/INSTALACION.md).

1. Descarga la base de KOReader indicada en la tabla de arriba y descomprímela.
2. Copia encima el contenido de `kindle-pw3/biblestudyhub/` (o `kindle-k3/bsh-k3/`), reemplazando archivos.
3. Agrega tus módulos en `app/data/` (ver [Módulos](#módulos)).
4. Copia la carpeta al Kindle junto con el lanzador (`documents/BibleStudyHub.sh` o la extensión de KUAL).

## Módulos

Este repositorio **no incluye Biblias, comentarios ni diccionarios**: muchos tienen derechos de autor. Cada usuario
agrega los módulos que tenga permiso de usar. La app usa un formato propio (SQLite con marca: `.ebb` Biblia,
`.ebc` comentario, `.ebd` diccionario) y trae un conversor desde módulos de theWord. Ver
[docs/MODULOS.md](docs/MODULOS.md).

## Estructura del repositorio

```
kindle-pw3/                    Paperwhite 3 (táctil)
  biblestudyhub/               → se copia encima de KOReader v2025.10 (kindlepw2)
    app/                       la app: código Lua, iconos, pantalla de reposo
    reader.lua                 modificado: abre la app en lugar de KOReader
    biblestudyhub.sh           lanzador (koreader.sh adaptado)
    frontend/ui/screensaver.lua          modificado (1 línea)
    frontend/ui/widget/pathchooser.lua   modificado (1 línea)
  documents/BibleStudyHub.sh   icono en la biblioteca del Kindle
kindle-k3/                     Kindle 3 (teclado)
  bsh-k3/                      → se copia encima de KOReader legacy v2026.07.1
    app/  reader.lua  koreader.sh  frontend/...
  extensions/bsh_k3/           entrada de KUAL
herramientas/                  conversor de módulos theWord (Python 3)
docs/                          instalación, módulos, arquitectura
```

Qué cambia exactamente en cada archivo de KOReader: [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md).

## Licencia

Bible Study Hub incluye y modifica archivos de KOReader, que se distribuye bajo la
**GNU Affero General Public License v3.0**. Este proyecto se publica bajo la misma licencia: ver [LICENSE](LICENSE).

KOReader © sus colaboradores — <https://github.com/koreader/koreader>.

## Autor

Creado por **Luis E. Martínez S.**
