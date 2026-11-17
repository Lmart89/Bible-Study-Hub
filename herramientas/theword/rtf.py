"""RTF sencillo (el de los diccionarios de theWord) → HTML.

Los diccionarios analizados solo usan \\uNNN? (letras acentuadas) y \\par (párrafo), pero se
aceptan también \\'hh, \\line, \\tab, \\b/\\b0 e \\i/\\i0. Las llaves de grupo se quitan y el resto
de palabras de control se ignoran.
"""

import html
import re

TOKEN = re.compile(r"\\u(-?\d+)\??|\\'([0-9a-fA-F]{2})|\\([a-z]+)(-?\d+)? ?|\\([\\{}])|([{}])|([^\\{}]+)")


def a_html(rtf):
    if not rtf:
        return ""
    parrafos, actual = [], []
    negrita = cursiva = False

    def abrir_cerrar(t):
        if negrita:
            t = "<b>%s</b>" % t
        if cursiva:
            t = "<i>%s</i>" % t
        return t

    for m in TOKEN.finditer(rtf):
        uni, hexa, palabra, num, escapado, llave, txt = m.groups()
        if uni is not None:
            actual.append(abrir_cerrar(html.escape(chr(int(uni) % 65536))))
        elif hexa is not None:
            actual.append(abrir_cerrar(html.escape(bytes([int(hexa, 16)]).decode("cp1252", "replace"))))
        elif palabra is not None:
            if palabra == "par" or palabra == "line":
                parrafos.append("".join(actual))
                actual = []
            elif palabra == "tab":
                actual.append(" ")
            elif palabra == "b":
                negrita = num != "0"
            elif palabra == "i":
                cursiva = num != "0"
        elif escapado is not None:
            actual.append(abrir_cerrar(html.escape(escapado)))
        elif txt is not None:
            t = txt.replace("\r", "").replace("\n", "")
            if t:
                actual.append(abrir_cerrar(html.escape(t)))
    parrafos.append("".join(actual))
    return "\n".join("<p>%s</p>" % p.strip() for p in parrafos if p.strip())
