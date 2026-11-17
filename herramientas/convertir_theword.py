"""Convierte módulos de theWord a los formatos de la app de Estudio Bíblico.

Uso:
    python herramientas/convertir_theword.py mis_modulos_theword/*   (salida: modulos/)
    python herramientas/convertir_theword.py MiBiblia.ont --salida otra/carpeta

Según la extensión:
    .ont .ot .nt   Biblia       → <salida>/biblias/<abreviatura>.ebb
    .cmt.twm       Comentario   → <salida>/comentarios/<abreviatura>.ebc
    .dct.twm       Diccionario  → <salida>/diccionarios/<abreviatura>.ebd

Los .ebb/.ebc/.ebd son bases SQLite con la marca del formato propio (PRAGMA application_id
«EBIB», user_version = versión del formato y meta.tipo): la app solo abre los que la tienen.
Para marcar módulos ya convertidos (.sqlite) sin volver a convertirlos: herramientas/migrar_formato.py

Solo convierte módulos que se tenga permiso de usar. Los formatos están descritos en
docs/MODULOS.md.
"""

import argparse
import glob
import os
import shutil
import sqlite3
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from theword import biblia, comentario, diccionario  # noqa: E402

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def tipo(ruta):
    """Carpeta de salida y conversor según la extensión o, en los .twm con nombre irregular
    («.cmt_.twm», «.dct_.twm», «x.twm»), según el tipo de su config (1 = diccionario,
    2 = comentario; 3 = libro general, que la app no usa)."""
    nombre = ruta.lower()
    if nombre.endswith((".ont", ".ot", ".nt")):
        return "biblias", biblia
    if nombre.endswith((".cmt.twm", ".cmt_.twm")):
        return "comentarios", comentario
    if nombre.endswith((".dct.twm", ".dct_.twm")):
        return "diccionarios", diccionario
    if nombre.endswith(".twm") and os.path.getsize(ruta) > 0:
        try:
            c = sqlite3.connect("file:%s?mode=ro" % ruta.replace("\\", "/"), uri=True)
            fila = c.execute("SELECT value FROM config WHERE name = 'type'").fetchone()
            c.close()
        except sqlite3.Error:
            fila = None
        if fila and str(fila[0]) == "2":
            return "comentarios", comentario
        if fila and str(fila[0]) == "1":
            return "diccionarios", diccionario
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("archivos", nargs="+", help="módulos de theWord (admite comodines)")
    ap.add_argument("--salida", default=os.path.join(RAIZ, "modulos"))
    args = ap.parse_args()

    rutas = [r for patron in args.archivos for r in (glob.glob(patron) or [patron])]
    errores = 0
    hechos = set()  # destinos de esta ejecución: dos módulos con la misma abreviatura no se pisan
    for ruta in rutas:
        if os.path.isfile(ruta) and os.path.getsize(ruta) == 0:
            print("· se omite (archivo vacío):", ruta)
            continue
        carpeta, modulo = tipo(ruta)
        if not modulo:
            print("· se omite (tipo no admitido):", ruta)
            continue
        inicio = time.time()
        temporal = tempfile.mkdtemp()
        try:
            hecho, resumen = modulo.convertir(ruta, temporal)
            os.makedirs(os.path.join(args.salida, carpeta), exist_ok=True)
            base, ext = os.path.splitext(os.path.basename(hecho))
            destino = os.path.join(args.salida, carpeta, base + ext)
            n = 2
            while destino in hechos:
                destino = os.path.join(args.salida, carpeta, "%s_%d%s" % (base, n, ext))
                n += 1
            shutil.move(hecho, destino)
            hechos.add(destino)
        except Exception as e:  # sigue con los demás módulos
            errores += 1
            print("✗ %s: %s" % (ruta, e))
            continue
        finally:
            shutil.rmtree(temporal, ignore_errors=True)
        print("✓ %s → %s\n    %s · %.1f MB · %.1f s" % (
            os.path.basename(ruta), os.path.relpath(destino, RAIZ), resumen,
            os.path.getsize(destino) / 1e6, time.time() - inicio))
    return 1 if errores else 0


if __name__ == "__main__":
    sys.exit(main())
