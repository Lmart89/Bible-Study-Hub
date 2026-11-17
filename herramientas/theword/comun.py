"""Utilidades comunes de los conversores: libros, normalización y enlaces a versículos."""

import html
import re
import sqlite3

LIBROS = [
    "Génesis", "Éxodo", "Levítico", "Números", "Deuteronomio", "Josué", "Jueces", "Rut",
    "1 Samuel", "2 Samuel", "1 Reyes", "2 Reyes", "1 Crónicas", "2 Crónicas", "Esdras", "Nehemías",
    "Ester", "Job", "Salmos", "Proverbios", "Eclesiastés", "Cantares", "Isaías", "Jeremías",
    "Lamentaciones", "Ezequiel", "Daniel", "Oseas", "Joel", "Amós", "Abdías", "Jonás",
    "Miqueas", "Nahúm", "Habacuc", "Sofonías", "Hageo", "Zacarías", "Malaquías",
    "Mateo", "Marcos", "Lucas", "Juan", "Hechos", "Romanos", "1 Corintios", "2 Corintios",
    "Gálatas", "Efesios", "Filipenses", "Colosenses", "1 Tesalonicenses", "2 Tesalonicenses",
    "1 Timoteo", "2 Timoteo", "Tito", "Filemón", "Hebreos", "Santiago", "1 Pedro", "2 Pedro",
    "1 Juan", "2 Juan", "3 Juan", "Judas", "Apocalipsis",
]

# Abreviaturas habituales en español (las del plugin y las que usa el Diccionario Nelson)
ABREVIATURAS = {
    1: ["Gn", "Gén", "Ge"], 2: ["Éx", "Ex"], 3: ["Lv", "Lev"], 4: ["Nm", "Núm", "Num"], 5: ["Dt", "Deut"],
    6: ["Jos"], 7: ["Jue", "Jc"], 8: ["Rt"], 9: ["1 S", "1 Sm", "1 Sam"], 10: ["2 S", "2 Sm", "2 Sam"],
    11: ["1 R", "1 Re"], 12: ["2 R", "2 Re"], 13: ["1 Cr"], 14: ["2 Cr"], 15: ["Esd"], 16: ["Neh"],
    17: ["Est"], 18: ["Job"], 19: ["Sal", "Salmo"], 20: ["Pr", "Prov"], 21: ["Ec", "Ecl"], 22: ["Cnt", "Cant"],
    23: ["Is"], 24: ["Jer"], 25: ["Lm", "Lam"], 26: ["Ez"], 27: ["Dn", "Dan"], 28: ["Os"], 29: ["Jl"],
    30: ["Am"], 31: ["Abd"], 32: ["Jon"], 33: ["Mi", "Miq"], 34: ["Nah"], 35: ["Hab"], 36: ["Sof"],
    37: ["Hag"], 38: ["Zac"], 39: ["Mal"], 40: ["Mt"], 41: ["Mr", "Mc"], 42: ["Lc"], 43: ["Jn"],
    44: ["Hch"], 45: ["Ro", "Rom"], 46: ["1 Co"], 47: ["2 Co"], 48: ["Gá", "Gl", "Gal"], 49: ["Ef"],
    50: ["Fil", "Flp"], 51: ["Col"], 52: ["1 Ts"], 53: ["2 Ts"], 54: ["1 Ti"], 55: ["2 Ti"], 56: ["Tit"],
    57: ["Flm"], 58: ["He", "Heb"], 59: ["Stg"], 60: ["1 P", "1 Pe"], 61: ["2 P", "2 Pe"],
    62: ["1 Jn"], 63: ["2 Jn"], 64: ["3 Jn"], 65: ["Jud"], 66: ["Ap"],
}

# Formato propio de los módulos: por dentro siguen siendo SQLite, con una marca en la cabecera
# (PRAGMA application_id y user_version) y su tipo en meta. La app solo abre los que la tienen.
APP_ID = 0x45424942  # «EBIB»
FORMATO = 1          # versión del formato (PRAGMA user_version); subirla si cambian las tablas
EXTENSIONES = {"biblia": ".ebb", "comentario": ".ebc", "diccionario": ".ebd"}


def marcar(conn, tipo):
    """Pone la marca del formato propio en una base ya creada (con su tabla meta)."""
    assert tipo in EXTENSIONES, tipo
    conn.execute("PRAGMA application_id = %d" % APP_ID)
    conn.execute("PRAGMA user_version = %d" % FORMATO)
    conn.executemany("INSERT OR REPLACE INTO meta VALUES (?, ?)", [("tipo", tipo), ("formato", str(FORMATO))])


def leer_marca(conn):
    """(tipo, None) si la base es un módulo válido; (None, motivo) si no."""
    if conn.execute("PRAGMA application_id").fetchone()[0] != APP_ID:
        return None, "no tiene la marca de Estudio Bíblico"
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    if not 1 <= version <= FORMATO:
        return None, "formato %d no admitido" % version
    fila = conn.execute("SELECT valor FROM meta WHERE clave = 'tipo'").fetchone()
    if not fila or fila[0] not in EXTENSIONES:
        return None, "sin tipo válido en meta"
    return fila[0], None


_ACENTOS = str.maketrans("áéíóúüñÁÉÍÓÚÜÑ", "aeiouunAEIOUUN")


def normalizar(s):
    """Minúsculas y sin tildes (igual que bsh_libros.lua): «Aarón» → «aaron»."""
    return re.sub(r"\s+", " ", s.translate(_ACENTOS).lower()).strip()


# nombre o abreviatura (normalizado) → número de libro
_A_LIBRO = {}
for _n, _nombre in enumerate(LIBROS, 1):
    _A_LIBRO[normalizar(_nombre)] = _n
for _n, _abrevs in ABREVIATURAS.items():
    for _a in _abrevs:
        _A_LIBRO[normalizar(_a)] = _n
_A_LIBRO[normalizar("Salmo")] = 19

_NOMBRES = sorted(set(LIBROS) | {a for v in ABREVIATURAS.values() for a in v}, key=len, reverse=True)
# «Éx 6.20», «1 Cr 6.3», «Juan 3:16», «Hch 2.1-4» (en texto ya escapado como HTML)
REFERENCIA = re.compile(
    r"(?<![\w])(" + "|".join(re.escape(n) for n in _NOMBRES) + r")\.? (\d{1,3})[.:](\d{1,3})(?:[-–]\d{1,3})?(?![\w])")


_YA_ENLAZADO = re.compile(r"(<a\b.*?</a>|<[^>]+>)", re.S)


def enlazar_referencias(texto_html):
    """Convierte las citas bíblicas de un texto HTML en enlaces verso://libro-cap-verso.
    No toca el interior de las etiquetas ni de los enlaces que ya existen."""
    def sustituir(m):
        libro = _A_LIBRO.get(normalizar(m.group(1)))
        if not libro:
            return m.group(0)
        return '<a href="verso://%d-%s-%s">%s</a>' % (libro, m.group(2), m.group(3), m.group(0))
    partes = _YA_ENLAZADO.split(texto_html)
    for i in range(0, len(partes), 2):  # los índices pares son texto fuera de etiquetas
        partes[i] = REFERENCIA.sub(sustituir, partes[i])
    return "".join(partes)


def texto(valor):
    """Valor de SQLite (bytes o str) a str: UTF-8 y, si no lo es, Windows-1252 (theWord mezcla ambos)."""
    if valor is None:
        return ""
    if isinstance(valor, str):
        return valor
    try:
        return valor.decode("utf-8")
    except UnicodeDecodeError:
        return valor.decode("cp1252", "replace")


def abrir_twm(ruta):
    """Abre un módulo .twm (SQLite) en solo lectura, devolviendo bytes en las columnas de texto."""
    c = sqlite3.connect("file:%s?mode=ro" % ruta.replace("\\", "/"), uri=True)
    c.text_factory = bytes
    return c


def config_twm(conn):
    return {texto(k): texto(v) for k, v in conn.execute("SELECT name, value FROM config")}


def titulo(s):
    """Títulos que theWord guarda EN MAYÚSCULAS → «Comentario al Nuevo Testamento - Barclay»."""
    if not s.isupper():
        return s
    palabras = s.lower().split(" ")
    return " ".join(p.capitalize() if i == 0 or len(p) > 3 else p for i, p in enumerate(palabras))


def nombre_archivo(s):
    """Nombre de archivo seguro a partir de una abreviatura: «NELSON-test » → «nelson-test»."""
    s = normalizar(s)
    s = re.sub(r"[^a-z0-9_-]+", "_", s).strip("_")
    return s or "modulo"


escapar = html.escape
