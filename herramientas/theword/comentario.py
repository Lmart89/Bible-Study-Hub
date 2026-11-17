"""Comentario de theWord (.cmt.twm) → formato de comentarios de la app (plan §6).

theWord: bible_refs(topic_id, bi, ci, fvi, tvi) + content(topic_id, data en RVF o RTF)
    ci = 0   → introducción al libro      → capitulo = 0, verso_desde NULL
    fvi = 0  → comentario del capítulo    → verso_desde NULL
    fvi–tvi  → versículo o pasaje         → verso_desde, verso_hasta (NULL si es uno solo)
"""

import os
import sqlite3

from . import rtf, rvf
from .comun import EXTENSIONES, abrir_twm, config_twm, enlazar_referencias, marcar, nombre_archivo, texto, titulo


def contenido_html(data):
    data = data or b""
    if data.startswith(b"-8 "):
        cuerpo = rvf.a_html(data)
    else:
        cuerpo = rtf.a_html(texto(data))
    return enlazar_referencias(cuerpo)


def convertir(ruta, carpeta_salida):
    tw = abrir_twm(ruta)
    cfg = config_twm(tw)
    abreviatura = cfg.get("abbrev") or os.path.basename(ruta).split(".")[0]
    os.makedirs(carpeta_salida, exist_ok=True)
    destino = os.path.join(carpeta_salida, nombre_archivo(abreviatura) + EXTENSIONES["comentario"])
    if os.path.exists(destino):
        os.remove(destino)

    c = sqlite3.connect(destino)
    c.executescript("""
        CREATE TABLE meta (clave TEXT PRIMARY KEY, valor TEXT);
        CREATE TABLE entradas (
            id INTEGER PRIMARY KEY,
            libro INTEGER NOT NULL,
            capitulo INTEGER NOT NULL,      -- 0 = introducción al libro
            verso_desde INTEGER,            -- NULL = capítulo (o libro) completo
            verso_hasta INTEGER,            -- NULL = un solo versículo
            html TEXT NOT NULL);
    """)
    filas, vacias = [], 0
    for bi, ci, fvi, tvi, data in tw.execute("""
            SELECT r.bi, r.ci, r.fvi, r.tvi, c.data
            FROM bible_refs r JOIN content c ON c.topic_id = r.topic_id
            ORDER BY r.bi, r.ci, r.fvi, r.topic_id"""):
        cuerpo = contenido_html(data)
        if not cuerpo:
            vacias += 1
            continue
        if not ci or not fvi:
            desde = hasta = None
        else:
            desde = fvi
            hasta = tvi if tvi and tvi != fvi else None
        filas.append((bi, ci or 0, desde, hasta, cuerpo))
    c.executemany("INSERT INTO entradas(libro, capitulo, verso_desde, verso_hasta, html) VALUES (?, ?, ?, ?, ?)", filas)
    c.execute("CREATE INDEX idx_entradas_ref ON entradas(libro, capitulo, verso_desde)")
    c.executemany("INSERT INTO meta VALUES (?, ?)", [
        ("nombre", titulo(cfg.get("title") or abreviatura)),
        ("abreviatura", abreviatura.strip()),
        ("autor", cfg.get("author", "")),
        ("descripcion", cfg.get("description", "")),
        ("fuente", "theWord: " + os.path.basename(ruta)),
    ])
    marcar(c, "comentario")
    c.commit()
    c.execute("VACUUM")
    c.close()
    libros = len({f[0] for f in filas})
    return destino, "%d entradas en %d libros (%d vacías omitidas)" % (len(filas), libros, vacias)
