"""Pasa módulos ya convertidos (.sqlite) al formato propio (.ebb/.ebc/.ebd) sin volver a convertirlos.

Uso:
    python herramientas/migrar_formato.py               (carpeta: modulos/)
    python herramientas/migrar_formato.py otra/carpeta/data --borrar

En <data>/biblias, <data>/comentarios y <data>/diccionarios, cada .sqlite con las tablas de su tipo
se copia con la extensión nueva y se le pone la marca (PRAGMA application_id, user_version y
meta.tipo; ver theword/comun.py). Con --borrar se elimina el .sqlite una vez comprobada la copia.
"""

import argparse
import os
import shutil
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from theword.comun import EXTENSIONES, leer_marca, marcar  # noqa: E402

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARPETAS = {"biblias": "biblia", "comentarios": "comentario", "diccionarios": "diccionario"}
# tablas que debe tener cada tipo (lo mínimo que usa la app)
TABLAS = {"biblia": {"verses", "verses_fts"}, "comentario": {"entradas"}, "diccionario": {"entradas", "variantes"}}


def migrar(origen, tipo, borrar):
    destino = os.path.splitext(origen)[0] + EXTENSIONES[tipo]
    c = sqlite3.connect("file:%s?mode=ro" % origen.replace("\\", "/"), uri=True)
    tablas = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    c.close()
    faltan = TABLAS[tipo] - tablas
    if faltan:
        return "✗ %s: no es un %s (faltan las tablas %s)" % (origen, tipo, ", ".join(sorted(faltan)))
    shutil.copy2(origen, destino)
    c = sqlite3.connect(destino)
    c.execute("CREATE TABLE IF NOT EXISTS meta (clave TEXT PRIMARY KEY, valor TEXT)")
    marcar(c, tipo)
    c.commit()
    leido, motivo = leer_marca(c)
    c.close()
    if leido != tipo:
        os.remove(destino)
        return "✗ %s: la copia no quedó marcada (%s)" % (origen, motivo)
    if borrar:
        os.remove(origen)
    return "✓ %s → %s%s" % (os.path.relpath(origen, RAIZ), os.path.basename(destino), " (original borrado)" if borrar else "")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("data", nargs="?", default=os.path.join(RAIZ, "modulos"))
    ap.add_argument("--borrar", action="store_true", help="borrar cada .sqlite después de comprobar su copia")
    args = ap.parse_args()
    errores = 0
    for carpeta, tipo in CARPETAS.items():
        dir_tipo = os.path.join(args.data, carpeta)
        if not os.path.isdir(dir_tipo):
            continue
        for f in sorted(os.listdir(dir_tipo)):
            if f.lower().endswith(".sqlite"):
                linea = migrar(os.path.join(dir_tipo, f), tipo, args.borrar)
                errores += linea.startswith("✗")
                print(linea)
    return 1 if errores else 0


if __name__ == "__main__":
    sys.exit(main())
