--[[--
Importa un bosquejo o sermón de Word (.docx) como nota, con las marcas de las notas
(bsh_marcas y el exportador bsh_azw3), para editarla y exportarla.

Un .docx es un ZIP: el texto está en word/document.xml, los nombres de los estilos en
word/styles.xml y la numeración de las listas en word/numbering.xml. Se leen con libarchive
(ffi/archiver) y se recorren con patrones de Lua, sin otras bibliotecas.

    Estilo Título (o el primer párrafo, si es un Título 1 o va todo en negrita) → # título
    Subtítulo justo después del título → subtítulo de la nota (va bajo el título en el AZW3)
    Título 1 y 2 → ## sección          Título 3 o más → párrafo en **negrita**
    Cita, Cita destacada → > cita
    Listas: viñetas → «- », números → «1. », letras → «a. »; otras («I.», «A.», «1.1.») quedan
    delante del texto
    Negrita, cursiva, subrayado, tachado y resaltado → **…**, *…*, <u>…</u>, ~~…~~, ==…==
    Tablas → una línea por fila, con las celdas separadas por « · »

Las imágenes, los cuadros de texto, las notas al pie y los comentarios no se importan; el texto
borrado con control de cambios tampoco. Los estilos se reconocen por su nombre en inglés (el que
guarda Word en cualquier idioma) o en español.
--]]--

local M = {}

M.MAX_XML = 8 * 1024 * 1024 -- document.xml más grande que esto no se convierte (memoria del K3)

--- Texto ------------------------------------------------------------------------------

local function utf8(n)
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
    if n < 0x10000 then
        return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
    end
    return string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64,
        0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end

local ENTIDADES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

--- Quita las entidades XML (&amp; &#233; &#xE9;…).
function M.texto(s)
    return (s:gsub("&(#?)([xX]?)(%w+);", function(num, hex, v)
        if num == "" then return ENTIDADES[v] end
        local n = tonumber(v, hex ~= "" and 16 or 10)
        return n and utf8(n)
    end))
end

--- Atributos de la primera etiqueta <nombre …> o <nombre/> en xml (sin confundir w:b con w:bCs),
-- o nil si no está.
local function etiqueta(xml, nombre)
    if not xml then return nil end
    local esc = nombre:gsub("%p", "%%%0")
    return xml:match("<" .. esc .. "([%s/][^>]*)>") or (xml:find("<" .. esc .. ">") and "")
end

local function atributo(attrs, nombre)
    return attrs and attrs:match(nombre:gsub("%p", "%%%0") .. '="([^"]*)"')
end

local function valor(xml, nombre)
    return atributo(etiqueta(xml, nombre), "w:val")
end

--- ¿Está activa la propiedad? <w:b/> sí; <w:b w:val="0"/> o "false" o "none" no.
local function activo(xml, nombre)
    local attrs = etiqueta(xml, nombre)
    if not attrs then return false end
    local v = atributo(attrs, "w:val")
    return not (v == "0" or v == "false" or v == "none" or v == "off")
end

local function recortar(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Estilos ----------------------------------------------------------------------------

--- styles.xml → { [styleId] = { nombre (en minúsculas), base, nivel } }
local function leerEstilos(xml)
    local estilos = {}
    for attrs, cuerpo in (xml or ""):gmatch("<w:style(%s[^>]*)>(.-)</w:style>") do
        local id = atributo(attrs, "w:styleId")
        if id then
            estilos[id] = {
                nombre = (valor(cuerpo, "w:name") or id):lower(),
                base = valor(cuerpo, "w:basedOn"),
                nivel = tonumber(valor(cuerpo, "w:outlineLvl") or ""),
            }
        end
    end
    return estilos
end

--- Tipo de un nombre (o id) de estilo: "titulo", "subtitulo", "h1"…, "cita", o nil.
local function tipoPorNombre(n)
    n = n:lower():gsub("[%s_%-]", "")
    if n == "title" or n == "título" or n == "titulo" or n == "ttulo" then return "titulo" end
    if n == "subtitle" or n == "subtítulo" or n == "subtitulo" or n == "subttulo" then return "subtitulo" end
    local h = n:match("^heading(%d)$") or n:match("^título(%d)$") or n:match("^titulo(%d)$") or n:match("^ttulo(%d)$")
        or n:match("^encabezado(%d)$")
    if h then return "h" .. h end
    if n == "quote" or n == "intensequote" or n == "cita" or n == "citadestacada" or n == "citaintensa" then
        return "cita"
    end
    if n == "strong" or n == "textoennegrita" then return "negrita" end
    if n == "emphasis" or n == "nfasis" or n == "énfasis" then return "cursiva" end
end

--- Tipo del estilo id, siguiendo los estilos en que se basa.
local function tipoDeEstilo(estilos, id)
    for _ = 1, 8 do
        if not id then return nil end
        local e = estilos[id]
        local t = tipoPorNombre(e and e.nombre or id) or tipoPorNombre(id)
        if t then return t end
        if e and e.nivel and e.nivel < 9 then return "h" .. (e.nivel + 1) end
        id = e and e.base
    end
end

--- Numeración -------------------------------------------------------------------------

--- numbering.xml → { [numId] = { [nivel] = { formato, texto, inicio } } }
local function leerNumeracion(xml)
    local abstractos = {}
    for attrs, cuerpo in (xml or ""):gmatch("<w:abstractNum(%s[^>]*)>(.-)</w:abstractNum>") do
        local niveles = {}
        for lattrs, lvl in cuerpo:gmatch("<w:lvl(%s[^>]*)>(.-)</w:lvl>") do
            local i = tonumber(atributo(lattrs, "w:ilvl") or "")
            if i then
                niveles[i] = { formato = valor(lvl, "w:numFmt") or "decimal", texto = valor(lvl, "w:lvlText") or "",
                    inicio = tonumber(valor(lvl, "w:start") or "") or 1 }
            end
        end
        abstractos[atributo(attrs, "w:abstractNumId") or ""] = niveles
    end
    local numeros = {}
    for attrs, cuerpo in (xml or ""):gmatch("<w:num(%s[^>]*)>(.-)</w:num>") do
        local id = atributo(attrs, "w:numId")
        local abstracto = valor(cuerpo, "w:abstractNumId")
        if id and abstracto then numeros[id] = abstractos[abstracto] end
    end
    return numeros
end

local ROMANOS = { { 1000, "m" }, { 900, "cm" }, { 500, "d" }, { 400, "cd" }, { 100, "c" }, { 90, "xc" },
    { 50, "l" }, { 40, "xl" }, { 10, "x" }, { 9, "ix" }, { 5, "v" }, { 4, "iv" }, { 1, "i" } }

local function romano(n)
    local t = {}
    for _, par in ipairs(ROMANOS) do
        while n >= par[1] do
            t[#t + 1] = par[2]
            n = n - par[1]
        end
    end
    return table.concat(t)
end

--- 1 → a, 26 → z, 27 → aa (como Word).
local function letra(n)
    local l = string.char(96 + (n - 1) % 26 + 1)
    return l:rep(math.floor((n - 1) / 26) + 1)
end

local function numeroCon(formato, n)
    if formato == "lowerLetter" then return letra(n) end
    if formato == "upperLetter" then return letra(n):upper() end
    if formato == "lowerRoman" then return romano(n) end
    if formato == "upperRoman" then return romano(n):upper() end
    return tostring(n)
end

--- Lleva la cuenta de cada lista y da el prefijo de cada elemento.
local function Contador(numeros)
    local cuentas = {}
    return function(numId, ilvl)
        local niveles = numeros[numId]
        local nivel = niveles and niveles[ilvl]
        if not nivel or numId == "0" then return nil end
        local c = cuentas[numId] or {}
        cuentas[numId] = c
        c[ilvl] = (c[ilvl] or (nivel.inicio - 1)) + 1
        for k in pairs(c) do if k > ilvl then c[k] = nil end end -- los niveles de dentro empiezan de nuevo
        if nivel.formato == "bullet" then return "- " end
        if nivel.formato == "none" then return "" end
        local etiqueta_ = nivel.texto:gsub("%%(%d)", function(k)
            local i = tonumber(k) - 1
            local nv = niveles[i]
            return nv and numeroCon(nv.formato, c[i] or nv.inicio) or ""
        end)
        etiqueta_ = recortar(etiqueta_)
        if etiqueta_ == "" then return "" end
        -- 1. y a. son listas de las notas; «1)» y «a)» también, con punto
        local num = etiqueta_:match("^(%d+)[%.%)]$")
        if num then return num .. ". " end
        local l = etiqueta_:match("^(%l+)[%.%)]$")
        if l and l == l:sub(1, 1):rep(#l) then return l .. ". " end
        return etiqueta_ .. " " -- I., A., 1.1. y otras: delante del texto
    end
end

--- Párrafos ---------------------------------------------------------------------------

local MARCAS = { { "r", "==", "==" }, { "b", "**", "**" }, { "i", "*", "*" }, { "u", "<u>", "</u>" },
    { "s", "~~", "~~" } }

--- Trozos { texto, b, i, u, s, r } → una línea con marcas. Los espacios quedan fuera de las marcas.
local function conMarcas(trozos)
    local unidos = {}
    for _, t in ipairs(trozos) do
        local u = unidos[#unidos]
        if u and u.b == t.b and u.i == t.i and u.u == t.u and u.s == t.s and u.r == t.r then
            u.texto = u.texto .. t.texto
        else
            unidos[#unidos + 1] = { texto = t.texto, b = t.b, i = t.i, u = t.u, s = t.s, r = t.r }
        end
    end
    local out = {}
    for _, t in ipairs(unidos) do
        local antes, centro, despues = t.texto:match("^(%s*)(.-)(%s*)$")
        if centro == "" then
            out[#out + 1] = t.texto
        else
            local abre, cierra = {}, {}
            for _, m in ipairs(MARCAS) do
                if t[m[1]] then
                    abre[#abre + 1] = m[2]
                    table.insert(cierra, 1, m[3])
                end
            end
            out[#out + 1] = antes .. table.concat(abre) .. centro .. table.concat(cierra) .. despues
        end
    end
    return table.concat(out)
end

--- Un párrafo (<w:p>…</w:p>) → { estilo, numId, ilvl, lineas = { trozos… } }.
local function leerParrafo(xml, estilos)
    local ppr = xml:match("<w:pPr>(.-)</w:pPr>") or ""
    local p = { estilo = valor(ppr, "w:pStyle"), numId = valor(ppr, "w:numId"),
        ilvl = tonumber(valor(ppr, "w:ilvl") or "") or 0, nivel = tonumber(valor(ppr, "w:outlineLvl") or "") }
    xml = xml:gsub("<w:pPr>.-</w:pPr>", "")
    local lineas = { {} }
    for run in xml:gmatch("<w:r[%s>].-</w:r>") do
        local rpr = run:match("<w:rPr>(.-)</w:rPr>") or ""
        local ce = tipoDeEstilo(estilos, valor(rpr, "w:rStyle"))
        local f = {
            b = activo(rpr, "w:b") or ce == "negrita",
            i = activo(rpr, "w:i") or ce == "cursiva",
            u = activo(rpr, "w:u"),
            s = activo(rpr, "w:strike") or activo(rpr, "w:dstrike"),
            r = activo(rpr, "w:highlight"),
        }
        run = run:gsub("<w:rPr>.-</w:rPr>", "")
        for nombre, attrs, texto in run:gmatch("<(w:%a+)([^>]*)>([^<]*)") do
            local pieza
            if nombre == "w:t" and not attrs:match("/$") then
                pieza = M.texto(texto)
            elseif nombre == "w:tab" or nombre == "w:ptab" then
                pieza = " "
            elseif nombre == "w:noBreakHyphen" then
                pieza = "-"
            elseif (nombre == "w:br" and not attrs:match('w:type="page"')) or nombre == "w:cr" then
                lineas[#lineas + 1] = {}
            end
            if pieza and pieza ~= "" then
                local actual = lineas[#lineas]
                actual[#actual + 1] = { texto = pieza, b = f.b, i = f.i, u = f.u, s = f.s, r = f.r }
            end
        end
    end
    p.lineas = lineas
    return p
end

local function plano(trozos)
    local t = {}
    for i, tr in ipairs(trozos) do t[i] = tr.texto end
    return recortar((table.concat(t):gsub("%s+", " ")))
end

--- ¿Todo el texto de la línea va en negrita?
local function todoNegrita(trozos)
    local alguno = false
    for _, t in ipairs(trozos) do
        if t.texto:find("%S") then
            if not t.b then return false end
            alguno = true
        end
    end
    return alguno
end

--- Tabla → una línea por fila, celdas con « · ».
local function leerTabla(xml)
    local filas = {}
    for fila in xml:gmatch("<w:tr[%s>].-</w:tr>") do
        local celdas = {}
        for celda in fila:gmatch("<w:tc[%s>].-</w:tc>") do
            local partes = {}
            for t in celda:gmatch("<w:t[%s>][^<]*") do
                partes[#partes + 1] = M.texto(t:gsub("^<w:t[^>]*>", ""))
            end
            local texto = recortar((table.concat(partes):gsub("%s+", " ")))
            if texto ~= "" then celdas[#celdas + 1] = texto end
        end
        if #celdas > 0 then filas[#filas + 1] = table.concat(celdas, " · ") end
    end
    return filas
end

--- Cuerpo del documento ------------------------------------------------------------------

--- Busca el cierre de la tabla que empieza en i (las tablas pueden ir unas dentro de otras).
local function finTabla(xml, i)
    local nivel, pos = 0, i
    while true do
        local a = xml:find("<w:tbl[%s>]", pos)
        local c = xml:find("</w:tbl>", pos, true)
        if not c then return #xml end
        if a and a < c then
            nivel = nivel + 1
            pos = a + 1
        else
            nivel = nivel - 1
            pos = c + 1
            if nivel == 0 then return c + #"</w:tbl>" - 1 end
        end
    end
end

--- Partes del .docx → { titulo, subtitulo, cuerpo, omitido = { imagenes, tablas } }, o nil y el error.
-- partes: { documento = document.xml, estilos = styles.xml, numeracion = numbering.xml };
-- nombre: el del archivo, para el título si el documento no tiene.
function M.convertir(partes, nombre)
    local doc = partes.documento
    if not doc or not doc:find("<w:body") then return nil, "no es un documento de Word (.docx)" end
    local estilos = leerEstilos(partes.estilos)
    local numerar = Contador(leerNumeracion(partes.numeracion))
    local omitido = { imagenes = 0, tablas = 0 }
    local cuerpo = doc:match("<w:body>(.*)</w:body>") or doc:match("<w:body[^>]*>(.*)") or ""
    -- lo que no es texto del documento
    cuerpo = cuerpo:gsub("<w:drawing>.-</w:drawing>", function() omitido.imagenes = omitido.imagenes + 1 return "" end)
    cuerpo = cuerpo:gsub("<w:pict[%s>].-</w:pict>", function() omitido.imagenes = omitido.imagenes + 1 return "" end)
    cuerpo = cuerpo:gsub("<mc:AlternateContent>.-</mc:AlternateContent>", "")
    cuerpo = cuerpo:gsub("<w:txbxContent>.-</w:txbxContent>", "")
    cuerpo = cuerpo:gsub("<w:del%s[^>]*>.-</w:del>", "")
    cuerpo = cuerpo:gsub("<w:sectPr[%s>].-</w:sectPr>", "")

    -- bloques en orden: párrafos y tablas
    local bloques = {}
    local pos = 1
    while true do
        local ip = cuerpo:find("<w:p[%s>/]", pos)
        local it = cuerpo:find("<w:tbl[%s>]", pos)
        if not ip and not it then break end
        if it and (not ip or it < ip) then
            local fin = finTabla(cuerpo, it)
            for _, fila in ipairs(leerTabla(cuerpo:sub(it, fin))) do
                bloques[#bloques + 1] = { tipo = "p", texto = fila, fila = true }
            end
            omitido.tablas = omitido.tablas + 1
            pos = fin + 1
        else
            local cierre = cuerpo:find("</w:p>", ip, true)
            local vacio = cuerpo:match("^<w:p[^>]-/>", ip)
            if vacio then
                pos = ip + #vacio
                bloques[#bloques + 1] = { tipo = "vacio" }
            else
                local fin = cierre and (cierre + 5) or #cuerpo
                local p = leerParrafo(cuerpo:sub(ip, fin), estilos)
                local tipo = tipoDeEstilo(estilos, p.estilo)
                if not tipo and p.nivel and p.nivel < 9 then tipo = "h" .. (p.nivel + 1) end
                p.tipo = tipo
                bloques[#bloques + 1] = p
                pos = fin + 1
            end
        end
    end

    -- título, subtítulo y cuerpo con las marcas de las notas
    local titulo, subtitulo
    local salida = {} -- { texto, lista = true/false }
    local primero = true
    for _, b in ipairs(bloques) do
        if b.tipo == "vacio" then
            -- nada: los párrafos ya van separados
        elseif b.fila then
            salida[#salida + 1] = { texto = b.texto }
            primero = false
        else
            local texto_plano = plano((function()
                local todo = {}
                for _, l in ipairs(b.lineas) do for _, t in ipairs(l) do todo[#todo + 1] = t end end
                return todo
            end)())
            if texto_plano ~= "" then
                local tipo = b.tipo
                local nivel = tipo and tonumber(tipo:match("^h(%d)$"))
                if primero and not titulo and (tipo == "titulo" or nivel == 1
                    or (not tipo and not b.numId and #texto_plano <= 120 and todoNegrita(b.lineas[1]) and #b.lineas == 1)) then
                    titulo = texto_plano
                elseif tipo == "titulo" then
                    salida[#salida + 1] = { texto = "## " .. texto_plano }
                elseif tipo == "subtitulo" then
                    if titulo and #salida == 0 and not subtitulo then
                        subtitulo = texto_plano
                    else
                        salida[#salida + 1] = { texto = "## " .. texto_plano }
                    end
                elseif nivel and nivel <= 2 then
                    salida[#salida + 1] = { texto = "## " .. texto_plano }
                elseif nivel then
                    salida[#salida + 1] = { texto = "**" .. texto_plano .. "**" }
                else
                    local lineas = {}
                    for _, l in ipairs(b.lineas) do
                        local t = recortar(conMarcas(l))
                        if t ~= "" then lineas[#lineas + 1] = t end
                    end
                    local prefijo = b.numId and numerar(b.numId, b.ilvl)
                    if tipo == "cita" then
                        for i, l in ipairs(lineas) do lineas[i] = "> " .. l end
                        salida[#salida + 1] = { texto = table.concat(lineas, "\n") }
                    elseif prefijo then
                        -- «- », «1. » y «a. » son listas de las notas: sus elementos van seguidos
                        local lista = prefijo == "- " or prefijo:match("^%d+%. $") or prefijo:match("^%l+%. $")
                        salida[#salida + 1] = { texto = prefijo .. table.concat(lineas, " "), lista = lista ~= nil }
                    else
                        salida[#salida + 1] = { texto = table.concat(lineas, "\n") }
                    end
                end
                primero = false
            end
        end
    end

    if not titulo then
        titulo = recortar(((nombre or ""):gsub("%.[Dd][Oo][Cc][Xx]$", ""):gsub("[_]+", " ")))
        if titulo == "" then titulo = "Bosquejo importado" end
    end
    local partes_cuerpo = { "# " .. titulo }
    for i, s in ipairs(salida) do
        local anterior = salida[i - 1]
        partes_cuerpo[#partes_cuerpo + 1] = (anterior and anterior.lista and s.lista) and "\n" or "\n\n"
        partes_cuerpo[#partes_cuerpo + 1] = s.texto
    end
    if #salida == 0 then return nil, "el documento no tiene texto" end
    return { titulo = titulo, subtitulo = subtitulo, cuerpo = table.concat(partes_cuerpo), omitido = omitido }
end

--- Lee un .docx del disco y lo convierte (ver convertir). Devuelve el resultado, o nil y el error.
function M.leer(ruta, nombre)
    local Archiver = require("ffi/archiver")
    local zip = Archiver.Reader:new()
    if not zip:open(ruta) then return nil, "no es un documento de Word (.docx)" end
    local buscados = { ["word/document.xml"] = "documento", ["word/styles.xml"] = "estilos",
        ["word/numbering.xml"] = "numeracion" }
    local partes, grande = {}, false
    for entrada in zip:iterate() do
        local clave = entrada.mode == "file" and buscados[entrada.path]
        if clave then
            if clave == "documento" and (tonumber(entrada.size) or 0) > M.MAX_XML then
                grande = true
            else
                partes[clave] = zip:extractToMemory(entrada.path)
            end
        end
    end
    zip:close()
    if grande then return nil, "el documento es demasiado grande para el Kindle" end
    if not partes.documento then
        return nil, "no es un documento de Word (.docx). Los .doc antiguos hay que guardarlos antes como .docx"
    end
    return M.convertir(partes, nombre)
end

return M
