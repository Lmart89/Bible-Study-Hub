"""Biblia de theWord (.ont = completa, .ot = AT, .nt = NT) → SQLite de la app.

El .ont es texto UTF-8: un versículo por línea en orden canónico (versificación de
versificacion.py) y, después, líneas "clave=valor" con los datos del módulo.

Etiquetas que se convierten:
    <CM>          al final del versículo: fin de párrafo (columna fin_parrafo = 1);
                  dentro del versículo: salto de línea (poesía)
    <i> <b>       se conservan (las cursivas marcan las palabras añadidas por los traductores)
    <FR>…<Fr>     palabras de Jesús → <span class="jesus">
    <font …>      se quita la etiqueta y se deja el texto
    otras         se descartan

Salida (igual que rvr1960.sqlite, más html, fin_parrafo y meta):
    meta(clave, valor)
    verses(id, book, chapter, verse, text, html, fin_parrafo)   -- text = texto plano (búsqueda)
    verses_fts  FTS5(text) con contenido externo en verses
"""

import html
import os
import re
import sqlite3

from .versificacion import VERSOS

ETIQUETA = re.compile(r"<(/?)([A-Za-z]+)[^>]*>")


def _referencias(primer_libro, ultimo_libro):
    for libro in range(primer_libro, ultimo_libro + 1):
        for cap, n in enumerate(VERSOS[libro - 1], 1):
            for verso in range(1, n + 1):
                yield libro, cap, verso


def _verso(linea):
    """Devuelve (texto plano, html, fin_parrafo) de una línea del .ont."""
    linea = linea.strip()
    fin_parrafo = 0
    while linea.endswith("<CM>"):
        fin_parrafo = 1
        linea = linea[:-4].rstrip()
    while linea.startswith("<CM>"):
        linea = linea[4:].lstrip()

    salida, plano, abiertas = [], [], []
    pos = 0
    for m in ETIQUETA.finditer(linea):
        trozo = linea[pos:m.start()]
        salida.append(html.escape(trozo))
        plano.append(trozo)
        pos = m.end()
        cierre, nombre = m.group(1) == "/", m.group(2)
        if nombre == "CM":
            if not salida or salida[-1] != "<br/>":
                salida.append("<br/>")
            plano.append(" ")
        elif nombre in ("i", "b"):
            if cierre:
                if nombre in abiertas:
                    abiertas.remove(nombre)
                    salida.append("</%s>" % nombre)
            else:
                abiertas.append(nombre)
                salida.append("<%s>" % nombre)
        elif nombre == "FR":
            abiertas.append("span")
            salida.append('<span class="jesus">')
        elif nombre == "Fr":
            if "span" in abiertas:
                abiertas.remove("span")
                salida.append("</span>")
        # <font>, </font> y cualquier otra: se descartan
    trozo = linea[pos:]
    salida.append(html.escape(trozo))
    plano.append(trozo)
    for nombre in reversed(abiertas):  # etiquetas sin cerrar en el módulo
        salida.append("</%s>" % nombre)
    texto = re.sub(r"\s+", " ", "".join(plano)).strip()
    return texto, "".join(salida).strip(), fin_parrafo


def convertir(ruta, carpeta_salida):
    ext = os.path.splitext(ruta)[1].lower()
    primero, ultimo = {".ont": (1, 66), ".ot": (1, 39), ".nt": (40, 66)}[ext]
    lineas = open(ruta, encoding="utf-8-sig").read().splitlines()
    refs = list(_referencias(primero, ultimo))
    versos, datos = lineas[:len(refs)], lineas[len(refs):]
    if len(versos) < len(refs):
        raise ValueError("%s: tiene %d líneas y la versificación pide %d" % (ruta, len(versos), len(refs)))

    meta = {}
    for l in datos:
        if "=" in l and not l.startswith(("{", "\\")):
            k, v = l.split("=", 1)
            meta[k.strip()] = v.strip()
    abreviatura = meta.get("short.title") or os.path.splitext(os.path.basename(ruta))[0]
    from .comun import EXTENSIONES, marcar, nombre_archivo
    os.makedirs(carpeta_salida, exist_ok=True)
    destino = os.path.join(carpeta_salida, nombre_archivo(abreviatura) + EXTENSIONES["biblia"])
    if os.path.exists(destino):
        os.remove(destino)

    c = sqlite3.connect(destino)
    c.executescript("""
        CREATE TABLE meta (clave TEXT PRIMARY KEY, valor TEXT);
        CREATE TABLE verses (
            id INTEGER PRIMARY KEY,
            book INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
            text TEXT NOT NULL, html TEXT NOT NULL, fin_parrafo INTEGER NOT NULL DEFAULT 0);
    """)
    filas = []
    for i, ((libro, cap, verso), linea) in enumerate(zip(refs, versos), 1):
        texto, cuerpo, fin = _verso(linea)
        filas.append((i, libro, cap, verso, texto, cuerpo, fin))
    c.executemany("INSERT INTO verses VALUES (?, ?, ?, ?, ?, ?, ?)", filas)
    c.executescript("""
        CREATE INDEX idx_book_chapter ON verses(book, chapter);
        CREATE INDEX idx_full_ref ON verses(book, chapter, verse);
        CREATE VIRTUAL TABLE verses_fts USING fts5(text, content='verses', content_rowid='id');
        INSERT INTO verses_fts(verses_fts) VALUES ('rebuild');
    """)
    c.executemany("INSERT INTO meta VALUES (?, ?)", [
        ("nombre", meta.get("description") or abreviatura),
        ("abreviatura", abreviatura),
        ("fuente", "theWord: " + os.path.basename(ruta)),
    ])
    marcar(c, "biblia")
    c.commit()
    c.execute("VACUUM")
    c.close()
    return destino, "%d versículos, %d con fin de párrafo" % (len(filas), sum(f[6] for f in filas))
