"""RVF (formato de TRichView, el que usan los comentarios de theWord) → HTML.

Estructura que se lee (comprobada con Barclay, Matthew Henry y Diario Vivir):
  * cabecera "-8 1 3", "-9 …" y bloques "RVStyle2" con la tabla de estilos de texto
    (cada estilo empieza por "StyleName"; "fsBold"/"fsItalic" marcan negrita/cursiva)
  * después, un elemento por cabecera de texto:
        <estilo> <líneas> <párrafo> <opciones> <tipo> <etiqueta>\\r\\n<texto>
    - estilo < 0: elemento especial (salto, imagen…): solo cuenta como corte de párrafo
    - párrafo ≥ 0 y sin la opción 1: el elemento empieza un párrafo nuevo
    - opción 8: texto en UTF-16LE (si no, Windows-1252)
    - etiqueta "tw://bible.*?id=40.1.1-40.1.17" en un estilo «Jump»: enlace a la Biblia → verso://40-1-1
"""

import html
import re

CABECERA = re.compile(rb'(?:\r\n|\)|^) ?(-?\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+|"[^"\r\n]*")\r\n')
ENLACE_BIBLIA = re.compile(rb"id=(\d+)\.(\d+)\.(\d+)")


def _estilos(data):
    i = data.find(b"RVStyle2")
    if i < 0:
        return []
    fin = data.find(b"RVStyle2", i + 8)
    bloque = data[i:fin if fin > 0 else len(data)]
    # «Jump» marca los estilos de hipervínculo: solo esos elementos son enlaces de verdad
    # (Diario Vivir guarda la etiqueta tw:// también en texto normal).
    return [{"b": b"fsBold" in p, "i": b"fsItalic" in p, "enlace": b"\x04Jump\t" in p}
            for p in bloque.split(b"StyleName")[1:]]


def a_html(data):
    """Devuelve el HTML (párrafos <p>) de un contenido RVF."""
    if not data:
        return ""
    estilos = _estilos(data)
    ultimo = data.rfind(b"RVStyle2")
    cuerpo = data[data.find(b"\r\n", ultimo) + 2:] if ultimo >= 0 else data
    cabeceras = list(CABECERA.finditer(cuerpo))
    parrafos, actual = [], []
    for k, m in enumerate(cabeceras):
        estilo, lineas, parrafo, opciones = (int(m.group(j)) for j in (1, 2, 3, 4))
        etiqueta = m.group(6) if m.group(6).startswith(b'"') else None
        fin = cabeceras[k + 1].start() if k + 1 < len(cabeceras) else len(cuerpo)
        crudo = cuerpo[m.end():fin]
        if crudo.endswith(b") "):
            crudo = crudo[:-2]
        elif crudo.endswith(b")"):
            crudo = crudo[:-1]
        if not (opciones & 1) and parrafo >= 0 and actual:
            parrafos.append(actual)
            actual = []
        if estilo < 0 or lineas == 0:
            continue
        txt = crudo.decode("utf-16-le", "replace") if opciones & 8 else crudo.decode("cp1252", "replace")
        formato = estilos[estilo] if estilo < len(estilos) else {}
        destino = None
        if etiqueta and formato.get("enlace"):
            r = ENLACE_BIBLIA.search(etiqueta)
            if r:
                destino = "verso://%s-%s-%s" % tuple(g.decode() for g in r.groups())
        for n, linea in enumerate(txt.replace("\r\n", "\n").split("\n")):
            if n > 0:
                parrafos.append(actual)
                actual = []
            t = html.escape(linea)
            if formato.get("b"):
                t = "<b>%s</b>" % t
            if formato.get("i"):
                t = "<i>%s</i>" % t
            if destino:
                t = '<a href="%s">%s</a>' % (destino, t)
            actual.append(t)
    if actual:
        parrafos.append(actual)
    return "\n".join("<p>%s</p>" % "".join(p) for p in parrafos if "".join(p).strip())
