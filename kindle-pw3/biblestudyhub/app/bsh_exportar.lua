--[[--
Archivos de las notas en la carpeta compartida «BSH Notes», en Markdown.

Cada nota es un .md: una cabecera YAML con el vínculo bíblico y las fechas, seguida del cuerpo tal
como se escribió. La cabecera guarda el id de la nota, así que su archivo se reconoce aunque
cambie el título. La subcarpeta Copias guarda las copias temporales y no se lista como notas.

M.exportar pasa a archivos las notas de la tabla antigua: solo reescribe un archivo si la nota
se editó después de exportarla.
--]]--

local DataStorage = require("datastorage")
local Device = require("device")
local Libros = require("bsh_libros")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local M = {}

M.COPIAS = "Copias"

--- /mnt/us/BSH Notes en el Kindle.
function M.carpeta()
    return (Device.home_dir or DataStorage:getDataDir()) .. "/BSH Notes"
end

local function fecha(t)
    return t and os.date("%Y-%m-%dT%H:%M:%S", t) or ""
end

--- Donde el Kindle busca los libros.
function M.carpetaLibros()
    return (Device.home_dir or DataStorage:getDataDir()) .. "/documents"
end

--- Fecha de una cabecera → segundos, o nil.
function M.aSegundos(texto)
    local a, m, d, h, mi, s = tostring(texto or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not a then return nil end
    return os.time{ year = tonumber(a), month = tonumber(m), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }
end

local function referencia(n)
    local ref = Libros.nombre(n.libro) .. " " .. n.capitulo
    if n.verso then
        ref = ref .. ":" .. n.verso
        if n.verso_hasta and n.verso_hasta ~= n.verso then ref = ref .. "-" .. n.verso_hasta end
    end
    return ref
end

--- Texto completo del archivo de una nota.
function M.contenido(n)
    local cab = { "---", "id: " .. n.id }
    if n.libro then
        cab[#cab + 1] = "referencia: " .. referencia(n)
        cab[#cab + 1] = "libro: " .. n.libro
        cab[#cab + 1] = "capitulo: " .. n.capitulo
        if n.verso then cab[#cab + 1] = "verso: " .. n.verso end
        if n.verso_hasta then cab[#cab + 1] = "verso_hasta: " .. n.verso_hasta end
    end
    if n.subtitulo and n.subtitulo ~= "" then cab[#cab + 1] = "subtitulo: " .. n.subtitulo end
    if n.interlineado and n.interlineado ~= "" then cab[#cab + 1] = "interlineado: " .. n.interlineado end
    cab[#cab + 1] = "creada: " .. fecha(n.creada)
    cab[#cab + 1] = "editada: " .. fecha(n.editada)
    cab[#cab + 1] = "---"
    local cuerpo = (n.cuerpo or ""):gsub("^%s*\n", "")
    return table.concat(cab, "\n") .. "\n\n" .. cuerpo .. "\n"
end

--- Nombre de archivo sin extensión. Quita lo que FAT32 no admite en un nombre.
function M.nombre(n)
    local t = (n.titulo or ""):gsub('[%c\\/:%*%?"<>|]', " "):gsub("%s+", " ")
    t = t:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    return t ~= "" and t or "Nota"
end

--- Ruta libre para una nota nueva: con su id detrás si el título ya está ocupado.
function M.rutaNueva(carpeta, n)
    local base = M.nombre(n)
    local ruta = carpeta .. "/" .. base .. ".md"
    if lfs.attributes(ruta, "mode") then ruta = carpeta .. "/" .. base .. " (" .. n.id .. ").md" end
    return ruta
end

--- Separa un archivo en (campos de la cabecera o nil, cuerpo, texto de la cabecera).
function M.separar(texto)
    texto = texto:gsub("\r\n", "\n")
    if texto:sub(1, 4) == "---\n" then
        local fin = texto:find("\n---\n", 4, true)
        if fin then
            local cab = {}
            for linea in texto:sub(5, fin):gmatch("([^\n]*)\n") do
                local clave, valor = linea:match("^([%w_]+):%s*(.-)%s*$")
                if clave then cab[clave] = valor end
            end
            return cab, (texto:sub(fin + 5):gsub("^\n+", "")), texto:sub(1, fin + 4)
        end
    end
    return nil, texto
end

local function leerTexto(ruta)
    local f, err = io.open(ruta, "r")
    if not f then return nil, err end
    local texto = f:read("*a")
    f:close()
    return texto
end

--- Lee un .md. Devuelve (cabecera o nil, cuerpo), o nil, nil y el error.
function M.leer(ruta)
    local texto, err = leerTexto(ruta)
    if not texto then return nil, nil, err end
    return M.separar(texto)
end

--- Escribe en un temporal y lo renombra: un fallo no deja a medias un archivo que ya existía.
function M.escribir(ruta, texto)
    local tmp = ruta .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then return nil, err end
    local ok, err_escritura = f:write(texto)
    f:close()
    if ok then
        ok, err_escritura = os.rename(tmp, ruta)
    end
    if not ok then
        os.remove(tmp)
        return nil, err_escritura
    end
    return true
end

--- Cambia el cuerpo de un .md y conserva su cabecera, incluidos los campos de otros editores.
-- Con subtitulo también lo cambia; "" lo quita y nil lo deja como está.
--- Cambia un campo de la cabecera: valor nil lo deja como esté y "" lo quita.
local function ponerCampo(cabecera, cab, clave, valor)
    if valor == nil then return cabecera end
    local linea = valor ~= "" and (clave .. ": " .. valor):gsub("%%", "%%%%") or nil
    if cab[clave] then
        return (cabecera:gsub("\n" .. clave .. ":[^\n]*", linea and ("\n" .. linea) or "", 1))
    elseif linea then
        return (cabecera:gsub("\n%-%-%-\n$", "\n" .. linea .. "\n---\n"))
    end
    return cabecera
end

-- campos: otros campos de la cabecera que cambian, como subtitulo (ver ponerCampo).
function M.reemplazarCuerpo(ruta, cuerpo, editada, subtitulo, campos)
    local texto, err = leerTexto(ruta)
    if not texto then return nil, err end
    local cab, _, cabecera = M.separar(texto)
    if not cab then cabecera = "" end
    local nueva = "editada: " .. fecha(editada)
    if cab and cab.editada then
        cabecera = cabecera:gsub("\neditada:[^\n]*", "\n" .. nueva:gsub("%%", "%%%%"), 1)
    elseif cab then
        cabecera = cabecera:gsub("\n%-%-%-\n$", "\n" .. nueva .. "\n---\n")
    end
    if cab then
        cabecera = ponerCampo(cabecera, cab, "subtitulo", subtitulo)
        for _, clave in ipairs{ "interlineado" } do
            cabecera = ponerCampo(cabecera, cab, clave, campos and campos[clave])
        end
    end
    local separacion = cab and "\n" or ""
    return M.escribir(ruta, cabecera .. separacion .. cuerpo:gsub("^%s*\n", "") .. "\n")
end

M.PAPELERA = "Papelera" -- subcarpeta de las notas eliminadas: no entra en la lista ni en el índice

--- Copia temporal de un .md en la subcarpeta Copias, con la fecha en el nombre.
function M.copia(ruta, carpeta)
    local texto, err = leerTexto(ruta)
    if not texto then return nil, err end
    local dir = carpeta .. "/" .. M.COPIAS
    if lfs.attributes(dir, "mode") ~= "directory" then
        local ok, err_dir = lfs.mkdir(dir)
        if not ok then return nil, err_dir end
    end
    local base = ruta:match("([^/]+)%.md$") or "Nota"
    local destino = dir .. "/" .. base .. " " .. os.date("%Y-%m-%d %H%M%S") .. ".md"
    local ok, err_copia = M.escribir(destino, texto)
    if not ok then return nil, err_copia end
    return destino
end

--- Exporta una lista de notas.
-- @return { nuevas, actualizadas, sin_cambios, errores }, o nil y el error si no hay carpeta.
function M.exportar(notas, carpeta)
    carpeta = carpeta or M.carpeta()
    if lfs.attributes(carpeta, "mode") ~= "directory" then
        local ok, err = lfs.mkdir(carpeta)
        if not ok then
            logger.warn("[BSH] no se pudo crear", carpeta, err)
            return nil, err
        end
    end
    local por_id = {}
    for archivo in lfs.dir(carpeta) do
        if archivo:match("%.md$") then
            local cab = M.leer(carpeta .. "/" .. archivo)
            if cab and cab.id then
                por_id[cab.id] = { ruta = carpeta .. "/" .. archivo, editada = cab.editada or "" }
            end
        end
    end
    local r = { nuevas = 0, actualizadas = 0, sin_cambios = 0, errores = 0 }
    for _, n in ipairs(notas) do
        local previa = por_id[tostring(n.id)]
        local ruta, contador
        if not previa then
            ruta, contador = M.rutaNueva(carpeta, n), "nuevas"
        elseif previa.editada < fecha(n.editada) then
            ruta, contador = previa.ruta, "actualizadas"
        else
            contador = "sin_cambios"
        end
        if ruta then
            local ok, err = M.escribir(ruta, M.contenido(n))
            if not ok then
                logger.warn("[BSH] no se pudo exportar la nota", n.id, err)
                contador = "errores"
            end
        end
        r[contador] = r[contador] + 1
    end
    return r
end

return M
