"""Diccionario de theWord (.dct.twm) → formato de diccionarios de la app.

theWord: topics(id, subject) + content(topic_id, data en RTF) + topics_wordindex(id, word)

Salida:
    meta(clave, valor)                         -- nombre, abreviatura, autor, descripcion
    entradas(id, termino, html)
    variantes(palabra, entrada_id)             -- palabras normalizadas (minúsculas, sin tildes)
                                                  para buscar; índice por palabra
Enlaces en el HTML: citas bíblicas → verso://libro-cap-verso; remisiones a otro artículo
(«[Ver=] CARNERO» del Nelson) → dic://carnero
"""

import os
import re
import sqlite3

from . import rtf, rvf
from .comun import EXTENSIONES, abrir_twm, config_twm, enlazar_referencias, marcar, nombre_archivo, normalizar, texto

PALABRA = re.compile(r"[a-zñ0-9]+")
# Remisiones del Nelson: «[Ver=]  CARNERO; OVEJA» → enlace al artículo CARNERO
REMISION = re.compile(r"\[Ver=\]\s*(&quot;)?([A-ZÁÉÍÓÚÜÑ][A-ZÁÉÍÓÚÜÑ\- ]*[A-ZÁÉÍÓÚÜÑ]|[A-ZÁÉÍÓÚÜÑ])")


def remisiones(cuerpo):
    return REMISION.sub(lambda m: '%s<a href="dic://%s">%s</a>' % (
        m.group(1) or "", normalizar(m.group(2)), m.group(2)), cuerpo)


def convertir(ruta, carpeta_salida):
    tw = abrir_twm(ruta)
    cfg = config_twm(tw)
    abreviatura = (cfg.get("abbrev") or os.path.basename(ruta).split(".")[0]).strip()
    os.makedirs(carpeta_salida, exist_ok=True)
    destino = os.path.join(carpeta_salida, nombre_archivo(abreviatura) + EXTENSIONES["diccionario"])
    if os.path.exists(destino):
        os.remove(destino)

    c = sqlite3.connect(destino)
    c.executescript("""
        CREATE TABLE meta (clave TEXT PRIMARY KEY, valor TEXT);
        CREATE TABLE entradas (id INTEGER PRIMARY KEY, termino TEXT NOT NULL, html TEXT NOT NULL);
        CREATE TABLE variantes (palabra TEXT NOT NULL, entrada_id INTEGER NOT NULL,
                                PRIMARY KEY (palabra, entrada_id)) WITHOUT ROWID;
    """)
    entradas, variantes, vacias = [], set(), 0
    for tid, subject, data in tw.execute("""
            SELECT t.id, t.subject, c.data FROM topics t JOIN content c ON c.topic_id = t.id
            ORDER BY t.rel_order, t.id"""):
        termino = texto(subject).strip()
        data = data or b""
        cuerpo = rvf.a_html(data) if data.startswith(b"-8 ") else rtf.a_html(texto(data))
        if not termino or not cuerpo:
            vacias += 1
            continue
        entradas.append((tid, termino, remisiones(enlazar_referencias(cuerpo))))
        norm = normalizar(termino)
        variantes.add((norm, tid))
        for p in PALABRA.findall(norm):
            variantes.add((p, tid))
    ids = {e[0] for e in entradas}
    for tid, palabra in tw.execute("SELECT id, word FROM topics_wordindex"):
        if tid in ids:
            norm = normalizar(texto(palabra)).strip("'")
            if norm:
                variantes.add((norm, tid))

    c.executemany("INSERT INTO entradas VALUES (?, ?, ?)", entradas)
    c.executemany("INSERT INTO variantes VALUES (?, ?)", sorted(variantes))
    titulo = cfg.get("title") or abreviatura
    c.executemany("INSERT INTO meta VALUES (?, ?)", [
        ("nombre", titulo),
        ("abreviatura", abreviatura),
        ("autor", cfg.get("author", "")),
        ("descripcion", cfg.get("description", "")),
        ("fuente", "theWord: " + os.path.basename(ruta)),
    ])
    marcar(c, "diccionario")
    c.commit()
    c.execute("VACUUM")
    c.close()
    return destino, "%d artículos, %d variantes de búsqueda (%d vacíos omitidos)" % (len(entradas), len(variantes), vacias)
