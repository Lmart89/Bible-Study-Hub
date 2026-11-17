--[[--
Los 66 libros en el orden de rvr1960.sqlite (columna verses.book = 1..66).
--]]--

local Libros = {
    "Génesis", "Éxodo", "Levítico", "Números", "Deuteronomio", "Josué", "Jueces", "Rut",
    "1 Samuel", "2 Samuel", "1 Reyes", "2 Reyes", "1 Crónicas", "2 Crónicas", "Esdras", "Nehemías",
    "Ester", "Job", "Salmos", "Proverbios", "Eclesiastés", "Cantares", "Isaías", "Jeremías",
    "Lamentaciones", "Ezequiel", "Daniel", "Oseas", "Joel", "Amós", "Abdías", "Jonás",
    "Miqueas", "Nahúm", "Habacuc", "Sofonías", "Hageo", "Zacarías", "Malaquías",
    "Mateo", "Marcos", "Lucas", "Juan", "Hechos", "Romanos", "1 Corintios", "2 Corintios",
    "Gálatas", "Efesios", "Filipenses", "Colosenses", "1 Tesalonicenses", "2 Tesalonicenses",
    "1 Timoteo", "2 Timoteo", "Tito", "Filemón", "Hebreos", "Santiago", "1 Pedro", "2 Pedro",
    "1 Juan", "2 Juan", "3 Juan", "Judas", "Apocalipsis",
}

-- Abreviaturas (selector de libros y referencias cortas)
local Abreviaturas = {
    "Gn", "Éx", "Lv", "Nm", "Dt", "Jos", "Jue", "Rt", "1 S", "2 S", "1 R",
    "2 R", "1 Cr", "2 Cr", "Esd", "Neh", "Est", "Job", "Sal", "Pr", "Ec", "Cnt",
    "Is", "Jer", "Lm", "Ez", "Dn", "Os", "Jl", "Am", "Abd", "Jon", "Mi",
    "Nah", "Hab", "Sof", "Hag", "Zac", "Mal", "Mt", "Mr", "Lc", "Jn", "Hch",
    "Ro", "1 Co", "2 Co", "Gá", "Ef", "Fil", "Col", "1 Ts", "2 Ts", "1 Ti", "2 Ti",
    "Tit", "Flm", "He", "Stg", "1 P", "2 P", "1 Jn", "2 Jn", "3 Jn", "Jud", "Ap",
}

-- Quita tildes y pasa a minúsculas (UTF-8) para comparar nombres escritos por el usuario.
local ACENTOS = {
    ["á"] = "a", ["é"] = "e", ["í"] = "i", ["ó"] = "o", ["ú"] = "u", ["ü"] = "u", ["ñ"] = "n",
    ["Á"] = "a", ["É"] = "e", ["Í"] = "i", ["Ó"] = "o", ["Ú"] = "u", ["Ü"] = "u", ["Ñ"] = "n",
}
local function normalizar(s)
    s = s:gsub("[\195][\128-\191]", function(c) return ACENTOS[c] or c end)
    return s:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
end

local M = { nombres = Libros, total = #Libros, normalizar = normalizar }

function M.nombre(n)
    return Libros[n] or ("Libro " .. tostring(n))
end

function M.abreviatura(n)
    return Abreviaturas[n] or tostring(n)
end

M.ULTIMO_AT = 39

--- Dónde buscar: grupos de libros (todos son tramos seguidos en el orden de la Biblia).
-- «actual» (el libro que se lee) y «libros» (tramo elegido por el usuario) se resuelven en M.rango.
M.GRUPOS = {
    { id = "toda", nombre = "Toda la Biblia", desde = 1, hasta = 66 },
    { id = "at", nombre = "Antiguo Testamento", desde = 1, hasta = 39 },
    { id = "nt", nombre = "Nuevo Testamento", desde = 40, hasta = 66 },
    { id = "pentateuco", nombre = "Pentateuco", desde = 1, hasta = 5 },
    { id = "historicos", nombre = "Libros históricos", desde = 6, hasta = 17 },
    { id = "poeticos", nombre = "Libros poéticos", desde = 18, hasta = 22 },
    { id = "profetas", nombre = "Profetas", desde = 23, hasta = 39 },
    { id = "mayores", nombre = "Profetas mayores", desde = 23, hasta = 27 },
    { id = "menores", nombre = "Profetas menores", desde = 28, hasta = 39 },
    { id = "evangelios", nombre = "Evangelios", desde = 40, hasta = 43 },
    { id = "hechos", nombre = "Hechos", desde = 44, hasta = 44 },
    { id = "paulinas", nombre = "Cartas de Pablo", desde = 45, hasta = 57 },
    { id = "generales", nombre = "Cartas generales", desde = 58, hasta = 65 },
    { id = "apocalipsis", nombre = "Apocalipsis", desde = 66, hasta = 66 },
    { id = "actual", nombre = "Libro actual" },
    { id = "libros", nombre = "Elegir libros…" },
}

--- Nombre, primer y último libro de un rango. libro = el que se lee; desde/hasta = tramo elegido.
function M.rango(id, libro, desde, hasta)
    if id == "actual" and Libros[libro or 0] then
        return Libros[libro], libro, libro
    elseif id == "libros" and Libros[desde or 0] and Libros[hasta or 0] then
        if desde > hasta then desde, hasta = hasta, desde end
        if desde == hasta then return Libros[desde], desde, hasta end
        return Libros[desde] .. " a " .. Libros[hasta], desde, hasta
    end
    for _, g in ipairs(M.GRUPOS) do
        if g.id == id and g.desde then return g.nombre, g.desde, g.hasta end
    end
    return M.GRUPOS[1].nombre, 1, #Libros
end

--- Busca un libro por número o por el comienzo de su nombre ("jn" no, "juan" sí, "1 cor" sí).
-- @treturn number|nil
function M.buscar(texto)
    texto = normalizar(texto or "")
    if texto == "" then return nil end
    local n = tonumber(texto)
    if n then
        return (n >= 1 and n <= #Libros) and n or nil
    end
    for i, nombre in ipairs(Libros) do
        if normalizar(nombre) == texto then return i end
    end
    -- abreviaturas exactas («jn», «1 co», «gn»): las de las notas y referencias cortas
    for i, abr in ipairs(Abreviaturas) do
        if normalizar(abr) == texto then return i end
    end
    for i, nombre in ipairs(Libros) do
        if normalizar(nombre):sub(1, #texto) == texto then return i end
    end
    return nil
end

--- Interpreta "Juan 3", "juan 3:16", "43 3", "1 corintios 13".
-- @treturn number|nil libro, number|nil capítulo, number|nil versículo
function M.referencia(texto)
    texto = normalizar(texto or "")
    local nombre, cap, ver = texto:match("^(.-)%s+(%d+)%s*[:%.]%s*(%d+)$")
    if not nombre then
        nombre, cap = texto:match("^(.-)%s+(%d+)$")
    end
    if not nombre then
        nombre = texto
    end
    local libro = M.buscar(nombre)
    return libro, tonumber(cap) or (libro and 1), tonumber(ver)
end

return M
