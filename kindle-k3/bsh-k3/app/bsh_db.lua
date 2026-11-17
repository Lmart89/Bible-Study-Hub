--[[--
Acceso a la Biblia y a los módulos (.ebb/.ebc/.ebd: SQLite con la marca del formato propio)
con lua-ljsqlite3 (la librería SQLite que trae KOReader).

Notas de la librería:
  * los INTEGER llegan como int64 de LuaJIT (cdata): siempre se convierten con tonumber()
  * los números de Lua se enlazan como REAL: LIMIT/OFFSET van como enteros literales en el SQL
--]]--

local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local time = require("ui/time")

local DB = {}
DB.__index = DB

local function ms(desde)
    return time.to_ms(time.since(desde))
end

--- Formato propio de los módulos (alfa 9) --------------------------------------------
-- Por dentro siguen siendo SQLite; tools/convertir_theword.py (o tools/migrar_formato.py) les pone
-- una marca en la cabecera (PRAGMA application_id y user_version) y su tipo en meta. La app solo
-- lista (bsh_registro.lua) los archivos con su extensión que tienen la marca y el tipo correctos.
DB.APP_ID = 0x45424942 -- «EBIB»
DB.FORMATO = 1         -- versión de formato más alta que entiende esta app
DB.EXTENSIONES = { biblia = "ebb", comentario = "ebc", diccionario = "ebd" }

--- Abre una base (por defecto en solo lectura; modo "rwc" la crea si no existe).
-- Devuelve nil y el error si falla.
function DB.abrir(ruta, modo)
    local inicio = time.now()
    local ok, conn = pcall(SQ3.open, ruta, modo or "ro")
    if not ok then
        logger.warn("[BSH] no se pudo abrir", ruta, conn)
        return nil, tostring(conn)
    end
    local self = setmetatable({ conn = conn, ruta = ruta }, DB)
    logger.info("[BSH] base abierta en", ms(inicio), "ms:", ruta)
    return self
end

function DB:cerrar()
    if self.conn then
        self.conn:close()
        self.conn = nil
    end
end

--- ¿Es esta base un módulo de la app del tipo dado? Devuelve true, o nil y el motivo.
function DB:comprobarModulo(tipo)
    local ok, motivo = pcall(function()
        if self:filas("PRAGMA application_id")[1][1] ~= DB.APP_ID then
            return "no tiene la marca de Estudio Bíblico"
        end
        local version = self:filas("PRAGMA user_version")[1][1]
        if version < 1 or version > DB.FORMATO then
            return "formato " .. version .. " (esta versión lee hasta el " .. DB.FORMATO .. ")"
        end
        local fila = self:filas("SELECT valor FROM meta WHERE clave = 'tipo'")[1]
        if not fila or fila[1] ~= tipo then
            return "es de tipo «" .. tostring(fila and fila[1]) .. "», no «" .. tipo .. "»"
        end
    end)
    if not ok then return nil, tostring(motivo) end
    if motivo then return nil, motivo end
    return true
end

--- Nombre de archivo sin extensión: el comentario o diccionario elegido se recuerda así, para que
-- siga valiendo al pasar de «bar.sqlite» a «bar.ebc».
function DB.sinExtension(archivo)
    return (tostring(archivo or ""):gsub("%.%w+$", ""))
end

--- Ejecuta una consulta con parámetros y devuelve sus filas (tablas indexadas 1..n).
function DB:filas(sql, ...)
    local stmt = self.conn:prepare(sql)
    stmt:bind(...)
    local out = {}
    -- número real de columnas: con NULL en medio (nil en Lua), #fila no es fiable
    local columnas = stmt:_ncol()
    local fila = stmt:step()
    while fila do
        local copia = {}
        for i = 1, columnas do
            local v = fila[i]
            copia[i] = type(v) == "cdata" and tonumber(v) or v
        end
        out[#out + 1] = copia
        fila = stmt:step()
    end
    stmt:close()
    return out
end

--- Ejecuta una sentencia de escritura con parámetros (INSERT, UPDATE, DELETE).
function DB:ejecutar(sql, ...)
    local stmt = self.conn:prepare(sql)
    stmt:bind(...)
    stmt:step()
    stmt:close()
end

--- Texto de un versículo (o nil).
function DB:verso(libro, cap, verso)
    local f = self:filas("SELECT text FROM verses WHERE book = ? AND chapter = ? AND verse = ?", libro, cap, verso)[1]
    return f and f[1]
end

--- Versículos desde..hasta de un capítulo para la vista previa: { { verso, html }, … }
-- (si la Biblia no trae la columna html, el texto escapado).
function DB:pasaje(libro, cap, desde, hasta)
    if self:tieneHtml() then
        return self:filas("SELECT verse, html FROM verses WHERE book = ? AND chapter = ? AND verse BETWEEN ? AND ? ORDER BY verse",
            libro, cap, desde, hasta)
    end
    local filas = self:filas("SELECT verse, text FROM verses WHERE book = ? AND chapter = ? AND verse BETWEEN ? AND ? ORDER BY verse",
        libro, cap, desde, hasta)
    for _, f in ipairs(filas) do
        f[2] = tostring(f[2] or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    end
    return filas
end

--- Número de versículos de un capítulo.
function DB:versiculos(libro, cap)
    return self:filas("SELECT max(verse) FROM verses WHERE book = ? AND chapter = ?", libro, cap)[1][1] or 0
end

--- Diagnóstico: versión de SQLite, total de versículos y si FTS5 responde.
function DB:diagnostico()
    local d = {}
    local inicio = time.now()
    d.sqlite = self:filas("SELECT sqlite_version()")[1][1]
    d.versos = self:filas("SELECT count(*) FROM verses")[1][1]
    d.ms_conteo = ms(inicio)
    inicio = time.now()
    local ok, res = pcall(self.filas, self, "SELECT count(*) FROM verses_fts WHERE verses_fts MATCH ?", "dios")
    d.fts5 = ok and res[1][1] or ("ERROR: " .. tostring(res))
    d.ms_fts = ms(inicio)
    logger.info("[BSH] diagnóstico:", d.sqlite, d.versos, "fts5 'dios' =", d.fts5, d.ms_fts, "ms")
    return d
end

--- Último capítulo de un libro.
function DB:capitulos(libro)
    return self:filas("SELECT max(chapter) FROM verses WHERE book = ?", libro)[1][1] or 0
end

--- ¿La Biblia trae la columna html (convertida de theWord por tools/convertir_theword.py)?
function DB:tieneHtml()
    if self._tiene_html == nil then
        self._tiene_html = false
        for _, f in ipairs(self:filas("PRAGMA table_info(verses)")) do
            if f[2] == "html" then self._tiene_html = true end
        end
    end
    return self._tiene_html
end

--- Versículos de un capítulo: lista de { verso, texto, html, fin_parrafo }
-- (html y fin_parrafo solo si la base los tiene).
function DB:capitulo(libro, cap)
    local inicio = time.now()
    local columnas = self:tieneHtml() and "verse, text, html, fin_parrafo" or "verse, text"
    local filas = self:filas("SELECT " .. columnas .. " FROM verses WHERE book = ? AND chapter = ? ORDER BY verse", libro, cap)
    local t = ms(inicio)
    logger.info("[BSH] capítulo", libro, cap, "→", #filas, "versículos en", t, "ms")
    return filas, t
end

-- Convierte lo que escribe el usuario en una consulta FTS5 válida.
-- Si ya usa sintaxis FTS5 (comillas, AND/OR/NOT/NEAR, *) se respeta tal cual;
-- si no, cada palabra se pone entre comillas (evita errores con símbolos).
local function consulta_fts(texto)
    texto = texto:gsub("^%s+", ""):gsub("%s+$", "")
    if texto:find('"') or texto:find("%*") or texto:find("%f[%w]AND%f[%W]") or texto:find("%f[%w]OR%f[%W]")
        or texto:find("%f[%w]NOT%f[%W]") or texto:find("NEAR%(") then
        return texto, true
    end
    local partes = {}
    for palabra in texto:gmatch("%S+") do
        partes[#partes + 1] = '"' .. palabra:gsub('"', "") .. '"'
    end
    return table.concat(partes, " "), false
end
DB.consulta_fts = consulta_fts

--- Cómo buscar: cada modo convierte lo escrito en una consulta FTS5. Las tildes y mayúsculas
-- no importan (el índice unicode61 las quita).
DB.MODOS = {
    { id = "todas", nombre = "Todas las palabras", ayuda = "Versículos con todas las palabras, en cualquier orden." },
    { id = "alguna", nombre = "Cualquier palabra", ayuda = "Versículos con al menos una de las palabras." },
    { id = "frase", nombre = "Frase exacta", ayuda = "Las palabras juntas y en ese orden." },
    { id = "parcial", nombre = "Palabras parciales", ayuda = "Palabras que empiezan así: «amo» encuentra amor, amó, amonestar." },
    { id = "avanzada", nombre = "Avanzada (FTS5)", ayuda = "Sintaxis FTS5: \"frase\", pref*, a AND b, a OR b, a NOT b, NEAR(a b, 5)." },
}

function DB.modo(id)
    for _, m in ipairs(DB.MODOS) do
        if m.id == id then return m end
    end
    return DB.MODOS[1]
end

--- Consulta FTS5 para un modo de DB.MODOS (sin modo: como antes, se adivina por la sintaxis).
function DB.consulta_modo(texto, modo)
    texto = tostring(texto or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not modo then return (consulta_fts(texto)) end
    if modo == "avanzada" then return texto end
    local palabras = {}
    for p in texto:gmatch("%S+") do
        p = p:gsub('["%*]', "")
        -- una «palabra» solo de signos daría una frase vacía
        if p:find("[%w\128-\255]") then palabras[#palabras + 1] = p end
    end
    if #palabras == 0 then return "" end
    if modo == "frase" then return '"' .. table.concat(palabras, " ") .. '"' end
    local partes = {}
    for i, p in ipairs(palabras) do
        partes[i] = '"' .. p .. '"' .. (modo == "parcial" and "*" or "")
    end
    return table.concat(partes, modo == "alguna" and " OR " or " ")
end

--- Busca con FTS5 dentro de un rango de libros. modo: id de DB.MODOS (nil = sintaxis adivinada).
-- @treturn table|nil resultados { libro, cap, verso, extracto }, number total, number ms, string error,
--   table por_libro { {libro, cantidad}, ... } en orden bíblico
function DB:buscar(texto, libro_desde, libro_hasta, pagina, por_pagina, modo)
    local q = DB.consulta_modo(texto, modo)
    if q == "" then return nil, 0, 0, "búsqueda vacía" end
    local inicio = time.now()
    local ok, por_libro = pcall(self.filas, self, [[
        SELECT v.book, count(*) FROM verses_fts JOIN verses v ON v.id = verses_fts.rowid
        WHERE verses_fts MATCH ? AND v.book BETWEEN ? AND ? GROUP BY v.book ORDER BY v.book]],
        q, libro_desde, libro_hasta)
    if not ok then
        logger.warn("[BSH] error FTS5:", q, por_libro)
        return nil, 0, 0, tostring(por_libro)
    end
    local total = 0
    for _, f in ipairs(por_libro) do total = total + f[2] end
    -- char(1)/char(2) marcan la palabra encontrada; luego se cambian por <b></b> tras escapar el HTML
    local filas = self:filas(string.format([[
        SELECT v.book, v.chapter, v.verse, snippet(verses_fts, 0, char(1), char(2), '…', 24)
        FROM verses_fts JOIN verses v ON v.id = verses_fts.rowid
        WHERE verses_fts MATCH ? AND v.book BETWEEN ? AND ?
        ORDER BY v.id LIMIT %d OFFSET %d]], por_pagina, (pagina - 1) * por_pagina), q, libro_desde, libro_hasta)
    local t = ms(inicio)
    logger.info("[BSH] búsqueda", q, "libros", libro_desde, "-", libro_hasta, "→", total, "resultados, página", pagina, "en", t, "ms")
    return filas, total, t, nil, por_libro
end

--- Un versículo completo con las palabras de la búsqueda en negrita (HTML escapado), para la
-- vista previa de un resultado. nil si no coincide o hay un error.
function DB:versoResaltado(texto, modo, libro, cap, verso)
    local q = DB.consulta_modo(texto, modo)
    if q == "" then return nil end
    local ok, filas = pcall(self.filas, self, [[
        SELECT highlight(verses_fts, 0, char(1), char(2)) FROM verses_fts JOIN verses v ON v.id = verses_fts.rowid
        WHERE verses_fts MATCH ? AND v.book = ? AND v.chapter = ? AND v.verse = ?]], q, libro, cap, verso)
    if not ok or not filas[1] or not filas[1][1] then return nil end
    return (tostring(filas[1][1]):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub("\1", "<b>"):gsub("\2", "</b>"))
end

return DB
