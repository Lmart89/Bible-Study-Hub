--[[--
Convierte una nota en AZW3 (KF8) para abrirla en el Kindle. Es tools/generar_azw3_v2.py en Lua.

Sin compresión, imágenes ni DRM. Los estilos salen de los documentos de Word del usuario.
Admite las marcas de las notas (bsh_marcas): # título, ## sección, > cita, - lista,
1. y a. listas con números o letras, **negrita**, *cursiva*, ==resaltado==, <u>subrayado</u>,
~~tachado~~, y párrafos con 4 espacios que continúan una lista. Lee las marcas con las mismas
reglas que BSH Text Editor: pueden anidarse, y una marca sin cierre es texto. La alineación y la
sangría van en un comentario al inicio del párrafo (<!--centro sangria:1-->), y el interlineado
de la nota llega en o.interlineado.
Las líneas seguidas forman un párrafo; una línea en blanco lo cierra.
El vínculo bíblico no se exporta: solo se ve dentro de la app.
--]]--

local Marcas = require("bsh_marcas")

local M = {}

local NULL = 0xFFFFFFFF
local TAM_REGISTRO = 4096
local TAM_CABECERA_INDX = 192
local TAM_TROZO = 8192
local UTF8 = 65001

local CSS = [[
body { font-family: serif; line-height: 1.2; margin: 0 5pt; }
h1 { font-size: 2.5em; font-weight: bold; text-align: center; margin: 0 0 0.18em 0; }
h2 { font-size: 1.5em; font-weight: bold; margin: 2pt 0 0 0; page-break-after: avoid; page-break-inside: avoid; }
p { text-align: justify; text-indent: 14.2pt; margin: 0 0 8pt 0; }
blockquote { font-style: italic; text-align: justify; text-indent: 14.2pt; margin: 0 16.7pt 8pt 14.2pt; }
ul { list-style-type: none; margin: 0; padding: 0; }
li { text-align: justify; text-indent: -18pt; margin: 0 2.45pt 0 32.2pt; }
.subtitulo { color: #5a5a5a; font-size: 2em; font-weight: bold; text-align: center; text-indent: 0; margin: 0 0 1.2em 0; }
.cont { text-indent: 17.5pt; margin: 0 2.45pt 0 32.2pt; }
.cita { font-style: italic; text-indent: 0; }
.fin { margin-bottom: 8pt; }
.res { background-color: #cccccc; }
.sub { text-decoration: underline; }
.tac { text-decoration: line-through; }
.subtac { text-decoration: underline line-through; }]]

-- Interlineado normal del editor (1,15), que aquí es el line-height 1.2 del CSS
local INTERLINEADO_NORMAL = 1.15

local ALINEACION = { izquierda = "left", centro = "center", derecha = "right", justificado = "justify" }
local SANGRIA = 24 -- puntos por nivel
-- Margen izquierdo de cada bloque en el CSS, en puntos: la sangría se suma a él
local MARGEN = { h1 = 0, h2 = 0, p = 0, cita = 14.2, li = 32.2, cont = 32.2, cont_cita = 32.2 }

--- Bytes ------------------------------------------------------------------------------

local function u16(v)
    return string.char(math.floor(v / 256) % 256, v % 256)
end

local function u32(...)
    local out = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        out[i] = string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
            math.floor(v / 256) % 256, v % 256)
    end
    return table.concat(out)
end

local function ceros(n)
    return string.rep("\0", n)
end

--- Entero de longitud variable: 7 bits por byte, el último lleva el bit alto.
local function encint(valor)
    local b = { (valor % 128) + 128 }
    valor = math.floor(valor / 128)
    while valor > 0 do
        table.insert(b, 1, valor % 128)
        valor = math.floor(valor / 128)
    end
    return string.char((table.unpack or unpack)(b))
end

local function alinear(datos)
    return datos .. ceros(-#datos % 4)
end

--- Devuelve (registros, { cadena = desplazamiento }).
local function cncx(cadenas)
    local partes, mapa, largo = {}, {}, 0
    for _, c in ipairs(cadenas) do
        if not mapa[c] then
            mapa[c] = largo
            partes[#partes + 1] = encint(#c) .. c
            largo = largo + #partes[#partes]
        end
    end
    if largo == 0 then return {}, mapa end
    return { alinear(table.concat(partes)) }, mapa
end

local DESPLAZA = { [1] = 0, [2] = 1, [3] = 0, [4] = 2, [8] = 3, [12] = 2, [128] = 7 }

--- Índice INDX: registro de cabecera, un registro de datos y los CNCX.
-- tags: { { nombre, número, valores por entrada, máscara } }
-- entradas: { { clave, { nombre = lista de valores } } }
local function indice(tags, entradas, registros_cncx)
    local tabla = {}
    for _, t in ipairs(tags) do
        tabla[#tabla + 1] = string.char(t[2], t[3], t[4], 0)
    end
    tabla[#tabla + 1] = string.char(0, 0, 0, 1)
    tabla = table.concat(tabla)
    local tagx = "TAGX" .. u32(12 + #tabla, 1) .. tabla

    local bloque, idxt, largo, ultima = {}, {}, 0, ""
    for _, e in ipairs(entradas) do
        local clave, valores = e[1], e[2]
        local control, cuerpo = 0, {}
        for _, t in ipairs(tags) do
            local v = valores[t[1]]
            if v then
                control = control + (#v / t[3]) * 2 ^ DESPLAZA[t[4]]
                for _, x in ipairs(v) do cuerpo[#cuerpo + 1] = encint(x) end
            end
        end
        local fila = string.char(#clave) .. clave .. string.char(control) .. table.concat(cuerpo)
        idxt[#idxt + 1] = u16(TAM_CABECERA_INDX + largo)
        bloque[#bloque + 1] = fila
        largo = largo + #fila
        ultima = clave
    end

    local bloque_a = alinear(table.concat(bloque))
    local datos = "INDX" .. u32(TAM_CABECERA_INDX, 0, 1, 0, TAM_CABECERA_INDX + #bloque_a, #entradas)
        .. string.rep(string.char(255), 8) .. ceros(156)
    datos = datos .. bloque_a .. alinear("IDXT" .. table.concat(idxt))

    local geometria = alinear(string.char(#ultima) .. ultima .. u16(#entradas))
    local tagx_a = alinear(tagx)
    local pos_idxt = TAM_CABECERA_INDX + #tagx_a + #geometria
    local cab = "INDX" .. u32(TAM_CABECERA_INDX) .. ceros(8) .. u32(2, pos_idxt, 1, UTF8)
        .. u32(NULL, #entradas, 0, 0, 0, #registros_cncx) .. ceros(124) .. u32(TAM_CABECERA_INDX) .. ceros(8)
    local idxt_cab = alinear("IDXT" .. u16(TAM_CABECERA_INDX + #tagx_a))
    local salida = { cab .. tagx_a .. geometria .. idxt_cab, datos }
    for _, r in ipairs(registros_cncx) do salida[#salida + 1] = r end
    return salida
end

--- Corta en bloques de 4096 bytes y añade el byte final que exige extra_data_flags = 1.
-- Si el corte parte un carácter UTF-8, los bytes que faltan van detrás como solape.
local function registrosTexto(texto)
    local salida = {}
    local pos = 0
    while pos < #texto do
        local fin = math.min(pos + TAM_REGISTRO, #texto)
        local solape = 0
        while fin + solape < #texto do
            local b = texto:byte(fin + solape + 1)
            if b < 128 or b >= 192 then break end
            solape = solape + 1
        end
        salida[#salida + 1] = texto:sub(pos + 1, fin + solape) .. string.char(solape)
        pos = pos + TAM_REGISTRO
    end
    return salida
end

local function exth(registros)
    local datos = {}
    for _, r in ipairs(registros) do
        datos[#datos + 1] = u32(r[1], 8 + #r[2]) .. r[2]
    end
    datos = table.concat(datos)
    return alinear("EXTH" .. u32(12 + #datos, #registros) .. datos)
end

--- Texto a XHTML ------------------------------------------------------------------------

local function escapar(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local PATRON = "[%z\1-\127\194-\244][\128-\191]*"
local DOBLES = { ["**"] = "n", ["=="] = "r", ["~~"] = "t" }

--- Línea → lista de caracteres con sus marcas { ch, n, k, r, u, t }, con las reglas de
-- BSH Text Editor (bshtexteditor_doc): una marca sin cierre, o sin nada dentro, es texto.
-- literales: posiciones de * que ya se sabe que son texto.
local function marcados(texto, literales)
    literales = literales or {}
    local out, f, abre = {}, {}, nil
    local i, largo = 1, #texto
    local function cierra(marca, desde)
        local j = texto:find(marca, desde, true)
        return j and j > desde
    end
    local function poner(ch)
        out[#out + 1] = { ch = ch, n = f.n, k = f.k, r = f.r, u = f.u, t = f.t }
    end
    while i <= largo do
        local dos = texto:sub(i, i + 1)
        local doble = DOBLES[dos]
        if doble and (f[doble] or cierra(dos, i + 2)) then
            f[doble] = not f[doble]
            i = i + 2
        elseif dos == "**" then
            poner("*")
            poner("*")
            i = i + 2
        elseif not f.u and texto:sub(i, i + 2) == "<u>" and cierra("</u>", i + 3) then
            f.u = true
            i = i + 3
        elseif f.u and texto:sub(i, i + 3) == "</u>" then
            f.u = false
            i = i + 4
        elseif texto:sub(i, i) == "*" and not literales[i] and (f.k or texto:find("*", i + 1, true)) then
            f.k = not f.k
            if f.k then abre = i end
            i = i + 1
        else
            local ch = texto:match(PATRON, i) or texto:sub(i, i)
            poner(ch)
            i = i + #ch
        end
    end
    if f.k then -- la cursiva no se cerró: su * era texto
        literales[abre] = true
        return marcados(texto, literales)
    end
    return out
end

-- Orden en que se abren las etiquetas; se cierran al revés, para que queden bien anidadas.
-- El subrayado y el tachado van juntos en d, porque un span dentro de otro no siempre suma
-- las dos líneas.
local ORDEN = { "r", "d", "n", "k" }
local CLASE_D = { u = "sub", t = "tac", ut = "subtac" }
local function abrir(m, valor)
    if m == "r" then return '<span class="res">' end
    if m == "d" then return '<span class="' .. CLASE_D[valor] .. '">' end
    return m == "n" and "<strong>" or "<em>"
end
local CIERRA = { r = "</span>", d = "</span>", n = "</strong>", k = "</em>" }

--- Marcas dentro de una línea → XHTML con las etiquetas bien anidadas.
function M.enLinea(texto)
    texto = texto:gsub("[\1-\8\11\12\14-\31]", "")
    local t, pila = {}, {}
    local function cerrarHasta(nivel)
        while #pila > nivel do t[#t + 1] = CIERRA[table.remove(pila)[1]] end
    end
    for _, c in ipairs(marcados(texto)) do
        local d = (c.u or c.t) and ((c.u and "u" or "") .. (c.t and "t" or "")) or nil
        local v = { r = c.r, d = d, n = c.n, k = c.k }
        -- si una etiqueta abierta cambia, se cierran también las abiertas después de ella
        for j, e in ipairs(pila) do
            if v[e[1]] ~= e[2] then
                cerrarHasta(j - 1)
                break
            end
        end
        local abiertas = {}
        for _, e in ipairs(pila) do abiertas[e[1]] = true end
        for _, m in ipairs(ORDEN) do
            if v[m] and not abiertas[m] then
                t[#t + 1] = abrir(m, v[m])
                pila[#pila + 1] = { m, v[m] }
            end
        end
        t[#t + 1] = escapar(c.ch)
    end
    cerrarHasta(0)
    return table.concat(t)
end

--- Lee el comentario de alineación y sangría del inicio del párrafo.
-- Devuelve (atributos o nil, resto). Un comentario con otras palabras es texto, como en el editor.
local function atributos(texto)
    local dentro, resto = texto:match("^<!%-%-(.-)%-%->(.*)")
    if not dentro or not dentro:find("%S") then return nil, texto end
    local at = {}
    for palabra in dentro:gmatch("%S+") do
        local s = palabra:match("^sangria:(%d)$")
        if ALINEACION[palabra] then
            at.alin = palabra
        elseif s then
            at.sangria = math.min(tonumber(s), 4)
        else
            return nil, texto
        end
    end
    if at.sangria == 0 then at.sangria = nil end
    return at, resto
end

--- Atributo style de un bloque con alineación o sangría, o "".
local function estilo(tipo, at)
    if not at then return "" end
    local t = {}
    if at.alin then
        t[#t + 1] = "text-align: " .. ALINEACION[at.alin]
        -- centrado o a la derecha, la sangría de primera línea lo descentraría
        if at.alin == "centro" or at.alin == "derecha" then t[#t + 1] = "text-indent: 0" end
    end
    if at.sangria then
        t[#t + 1] = string.format("margin-left: %.1fpt", (MARGEN[tipo] or 0) + SANGRIA * at.sangria)
    end
    return ' style="' .. table.concat(t, "; ") .. '"'
end

--- "a." … "z.", "aa." …: solo una letra, sola o repetida, como en el editor.
local function esLetra(v)
    local l = v:match("^(%l+)%.$")
    return l and l == string.rep(l:sub(1, 1), #l)
end

--- Cuerpo de la nota → lista de bloques { tipo, líneas, atributos, viñeta } (un párrafo o una
-- cita pueden tener varias líneas).
local function bloques(cuerpo)
    local lista = {}
    local abierto = false
    for linea in ((cuerpo or ""):gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        linea = linea:gsub("%s+$", "")
        if linea == "" then
            abierto = false
        else
            local tipo, texto, vineta
            local nivel, titulo = linea:match("^(#+)%s+(.+)$")
            local num, tras_num = linea:match("^(%d+%.) (.*)")
            if not num then
                local l, resto = linea:match("^(%l+%.) (.*)")
                if l and esLetra(l) then num, tras_num = l, resto end
            end
            if nivel then
                tipo, texto = (nivel == "#") and "h1" or "h2", titulo
            elseif linea:match("^    > ?") then
                tipo, texto = "cont_cita", linea:gsub("^    > ?", "")
            elseif linea:match("^%s*[-*] ") or linea:match("^%s*• ") then
                tipo, texto, vineta = "li", linea:gsub("^%s*[^%s]+%s+", ""), "-"
            elseif num then
                tipo, texto, vineta = "li", tras_num, num
            elseif linea:match("^> ?") then
                tipo, texto = "cita", linea:gsub("^> ?", "")
            elseif linea:match("^    ") then
                tipo, texto = "cont", linea:gsub("^%s+", "")
            else
                tipo, texto = "p", linea:gsub("^%s+", "")
            end
            local at
            at, texto = atributos(texto)
            local ultimo = lista[#lista]
            if abierto and ultimo and ultimo[1] == tipo and (tipo == "p" or tipo == "cita") and not at then
                ultimo[2][#ultimo[2] + 1] = texto
            else
                lista[#lista + 1] = { tipo, { texto }, at, vineta }
            end
            abierto = true
        end
    end
    return lista
end

local function enLineas(lineas)
    local out = {}
    for i, l in ipairs(lineas) do out[i] = M.enLinea(l) end
    return table.concat(out, "<br/>")
end

--- Devuelve (bloques XHTML, { [n.º de bloque] = etiqueta del índice }). Cada bloque lleva su aid.
local function aHtml(o)
    local lista = bloques(o.cuerpo)
    local salida, etiquetas = {}, {}
    local aid = 0
    local function marca()
        aid = aid + 1
        return string.format('aid="%X"', aid)
    end
    local function enLista(b)
        return b and (b[1] == "li" or b[1] == "cont" or b[1] == "cont_cita")
    end
    local subtitulo = o.subtitulo and o.subtitulo ~= ""
    local function ponerSubtitulo()
        if subtitulo then
            salida[#salida + 1] = string.format('<p class="subtitulo" %s>%s</p>', marca(), M.enLinea(o.subtitulo))
            subtitulo = false
        end
    end
    local i = 1
    while i <= #lista do
        local tipo, lineas, at = lista[i][1], lista[i][2], lista[i][3]
        if tipo == "h1" and #salida > 0 then tipo = "h2" end -- solo un # al inicio es el título
        if tipo == "h1" then
            etiquetas[#salida + 1] = Marcas.plano(lineas[1])
            salida[#salida + 1] = string.format("<h1 %s%s>%s</h1>", marca(), estilo(tipo, at), M.enLinea(lineas[1]))
            ponerSubtitulo()
        else
            ponerSubtitulo()
            if tipo == "h2" then
                etiquetas[#salida + 1] = Marcas.plano(lineas[1])
                salida[#salida + 1] = string.format("<h2 %s%s>%s</h2>", marca(), estilo(tipo, at), M.enLinea(lineas[1]))
            elseif tipo == "cita" then
                salida[#salida + 1] = string.format("<blockquote %s%s>%s</blockquote>", marca(), estilo(tipo, at), enLineas(lineas))
            elseif tipo == "li" then
                local items = {}
                while lista[i] and lista[i][1] == "li" do
                    local b = lista[i]
                    items[#items + 1] = string.format("<li %s%s>%s %s</li>", marca(), estilo("li", b[3]),
                        escapar(b[4]), M.enLinea(b[2][1]))
                    i = i + 1
                end
                i = i - 1
                local fin = enLista(lista[i + 1]) and "" or ' class="fin"'
                salida[#salida + 1] = string.format("<ul %s%s>%s</ul>", marca(), fin, table.concat(items))
            elseif tipo == "cont" or tipo == "cont_cita" then
                local clase = (tipo == "cont" and "cont" or "cont cita") .. (enLista(lista[i + 1]) and "" or " fin")
                salida[#salida + 1] = string.format('<p class="%s" %s%s>%s</p>', clase, marca(), estilo(tipo, at), enLineas(lineas))
            else
                salida[#salida + 1] = string.format("<p %s%s>%s</p>", marca(), estilo(tipo, at), enLineas(lineas))
            end
        end
        i = i + 1
    end
    ponerSubtitulo()
    if #salida == 0 then salida[1] = "<p>&#160;</p>" end
    return salida, etiquetas
end

--- Agrupa bloques completos en trozos. Devuelve (trozos, { { etiqueta, trozo, pos en trozo, pos global } }).
local function repartir(bloques_html, etiquetas)
    local trozos, entradas = {}, {}
    local actual, largo, total = {}, 0, 0
    for n, b in ipairs(bloques_html) do
        local crudo = b .. "\n"
        if largo > 0 and largo + #crudo > TAM_TROZO then
            trozos[#trozos + 1] = table.concat(actual)
            actual, largo = {}, 0
        end
        if etiquetas[n] then entradas[#entradas + 1] = { etiquetas[n], #trozos, largo, total } end
        actual[#actual + 1] = crudo
        largo = largo + #crudo
        total = total + #crudo
    end
    trozos[#trozos + 1] = table.concat(actual)
    return trozos, entradas
end

--- Construye el archivo.
-- @param o { titulo, cuerpo, subtitulo (opcional), autor (opcional), interlineado (opcional),
--   id (identifica la nota) }
-- @return bytes del .azw3
function M.construir(o)
    local titulo = o.titulo or "Nota"
    local autor = (o.autor and o.autor ~= "") and o.autor or "Bible Study Hub"
    local trozos, entradas = repartir(aHtml(o))

    local html_ini = '<?xml version="1.0" encoding="utf-8"?>'
        .. '<html xmlns="http://www.w3.org/1999/xhtml" lang="es"><head><title>' .. escapar(titulo) .. "</title>"
        .. '<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>'
        .. '<link href="kindle:flow:0001?mime=text/css" rel="stylesheet" type="text/css"/>'
        .. '</head><body aid="0">'
    local html_fin = "</body></html>"
    local esqueleto = html_ini .. html_fin
    local cuerpo = table.concat(trozos)
    local flujo0 = esqueleto .. cuerpo
    local css = CSS
    local il = tonumber(o.interlineado or "")
    if il and il >= 1 and il <= 3 and il ~= INTERLINEADO_NORMAL then
        css = css .. string.format("\nbody { line-height: %.2f; }", 1.2 * il / INTERLINEADO_NORMAL)
    end
    local texto = flujo0 .. css
    local insertar = #html_ini

    local textos = registrosTexto(texto)
    local largo_textos = 0
    for _, t in ipairs(textos) do largo_textos = largo_textos + #t end

    local selector = "P-//*[@aid='0']"
    local sel, m_sel = cncx({ selector })
    local filas = {}
    local acumulado = 0
    for n, t in ipairs(trozos) do
        filas[n] = { string.format("%010d", insertar + acumulado),
            { cncx = { m_sel[selector] }, archivo = { 0 }, secuencia = { n - 1 }, geometria = { acumulado, #t } } }
        acumulado = acumulado + #t
    end
    local idx_trozos = indice(
        { { "cncx", 2, 1, 1 }, { "archivo", 3, 1, 2 }, { "secuencia", 4, 1, 4 }, { "geometria", 6, 2, 8 } }, filas, sel)
    local idx_esq = indice({ { "cuenta", 1, 1, 3 }, { "geometria", 6, 2, 12 } },
        { { "SKEL0000000000", { cuenta = { #trozos, #trozos }, geometria = { 0, #esqueleto, 0, #esqueleto } } } }, {})

    if #entradas == 0 then entradas[1] = { titulo, 0, 0, 0 } end
    local nombres = {}
    for n, e in ipairs(entradas) do nombres[n] = e[1] end
    local et, m_et = cncx(nombres)
    local digitos = #tostring(#entradas - 1)
    digitos = digitos + digitos % 2
    local filas_ncx = {}
    for n, e in ipairs(entradas) do
        local fin = entradas[n + 1] and entradas[n + 1][4] or #cuerpo
        filas_ncx[n] = { string.format("%0" .. digitos .. "d", n - 1), {
            offset = { insertar + e[4] }, largo = { fin - e[4] }, etiqueta = { m_et[e[1]] },
            nivel = { 0 }, pos_fid = { e[2], e[3] },
        } }
    end
    local idx_ncx = indice({ { "offset", 1, 1, 1 }, { "largo", 2, 1, 2 }, { "etiqueta", 3, 1, 4 },
        { "nivel", 4, 1, 8 }, { "pos_fid", 6, 2, 128 } }, filas_ncx, et)

    local registros = { "" }
    for _, t in ipairs(textos) do registros[#registros + 1] = t end
    if largo_textos % 4 ~= 0 then registros[#registros + 1] = ceros(largo_textos % 4) end
    local n_texto = #textos

    -- los índices de registro de la cabecera empiezan en 0
    local function anadir(lista)
        local primero = #registros
        for _, r in ipairs(lista) do registros[#registros + 1] = r end
        return primero
    end
    local primero_no_texto = #registros
    local i_trozos = anadir(idx_trozos)
    local i_esq = anadir(idx_esq)
    local i_ncx = anadir(idx_ncx)
    local i_fdst = anadir({ "FDST" .. u32(12, 2, 0, #flujo0, #flujo0, #texto) })
    local i_flis = anadir({ "FLIS" .. u32(8) .. u16(0x41) .. ceros(6) .. u32(NULL) .. u16(1) .. u16(3) .. u32(3, 1, NULL) })
    local i_fcis = anadir({ "FCIS" .. u32(0x14, 0x10, 2, 0, #texto, 0, 0x28, 0, 0x28, 8) .. u16(1) .. u16(1) .. u32(0) })
    anadir({ string.char(0xE9, 0x8E, 13, 10) })

    -- identificador estable: al reexportar la misma nota el Kindle la trata como el mismo documento
    local id_doc = "bsh-nota-" .. tostring(o.id or titulo)
    local bloque_exth = exth({ { 100, autor }, { 503, titulo }, { 524, "es" }, { 501, "PDOC" }, { 113, id_doc }, { 504, id_doc } })

    local ahora = os.time()
    local pos_titulo = 280 + #bloque_exth
    local c = { u16(1), u16(0), u32(#texto), u16(n_texto), u16(TAM_REGISTRO), u16(0), u16(0) }
    c[#c + 1] = "MOBI" .. u32(264, 2, UTF8, ahora % 4294967296)
    c[#c + 1] = u32(8)                                                -- 36: versión del archivo
    c[#c + 1] = u32(NULL, NULL)                                       -- 40
    c[#c + 1] = u32(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)   -- 48
    c[#c + 1] = u32(primero_no_texto, pos_titulo, #titulo, 0x0A)      -- 80
    c[#c + 1] = u32(0, 0)                                             -- 96
    c[#c + 1] = u32(8, NULL)                                          -- 104: versión mínima, primer recurso
    c[#c + 1] = u32(0, 0, 0, 0)                                       -- 112
    c[#c + 1] = u32(0x50)                                             -- 128: hay EXTH
    c[#c + 1] = ceros(32)                                             -- 132
    c[#c + 1] = u32(NULL, NULL, 0, 0, 0)                              -- 164
    c[#c + 1] = ceros(8)                                              -- 184
    c[#c + 1] = u32(i_fdst, 2)                                        -- 192: registro FDST y número de flujos
    c[#c + 1] = u32(i_fcis, 1)                                        -- 200
    c[#c + 1] = u32(i_flis, 1)                                        -- 208
    c[#c + 1] = ceros(8)                                              -- 216
    c[#c + 1] = u32(NULL, 0, NULL, NULL)                              -- 224
    c[#c + 1] = u32(1)                                                -- 240: bytes finales en los registros de texto
    c[#c + 1] = u32(i_ncx, i_trozos, i_esq, NULL, NULL)               -- 244
    c[#c + 1] = u32(NULL, 0, 0, NULL)                                 -- 264
    registros[1] = table.concat(c) .. bloque_exth .. alinear(titulo .. "\0\0") .. ceros(1024)

    -- Palm Database
    local nombre = titulo:gsub("[^%w_%- ]", ""):gsub(" ", "_"):sub(1, 31)
    if nombre == "" then nombre = "BSH_Nota" end
    local palm = (ahora + 2082844800) % 4294967296
    local pdb = nombre .. ceros(32 - #nombre) .. u16(0) .. u16(0) .. u32(palm, palm, 0, 0, 0, 0)
        .. "BOOKMOBI" .. u32(#registros * 2 - 1, 0) .. u16(#registros)
    local pos = #pdb + 8 * #registros + 2
    local tabla = {}
    for i, r in ipairs(registros) do
        tabla[i] = u32(pos, (i - 1) * 2)
        pos = pos + #r
    end
    return pdb .. table.concat(tabla) .. "\0\0" .. table.concat(registros)
end

return M
