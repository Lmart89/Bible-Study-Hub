--[[--
Importar módulos (Biblias .ebb, comentarios .ebc, diccionarios .ebd) a la carpeta de módulos de la
app. Lo usa «Administrar módulos» (bsh_ajustes_avanzados), por Wi-Fi o desde un archivo del Kindle.

    Importar.instalar(ruta, archivo, carpeta, mover)
        → { nombre, tipo, destino, reemplazado }  o  nil, motivo

Antes de copiar, abre el archivo y comprueba que es un módulo de la app del tipo que dice su
extensión (DB:comprobarModulo). Va a la subcarpeta de su tipo (biblias, comentarios, diccionarios);
se escribe aparte y se renombra, así un corte no deja un módulo a medias. Un archivo con el mismo
nombre se reemplaza. Para que la app lo vea hay que reiniciarla (el registro se arma al cargar).
--]]--

local DB = require("bsh_db")
local lfs = require("libs/libkoreader-lfs")

local Importar = {}

Importar.CARPETAS = { biblia = "biblias", comentario = "comentarios", diccionario = "diccionarios" }
Importar.TIPOS = { biblia = "Biblia", comentario = "comentario", diccionario = "diccionario" }
Importar.AYUDA = "Se esperan archivos .ebb (Biblia), .ebc (comentario) o .ebd (diccionario)."

local BLOQUE = 1024 * 1024

--- Tipo de módulo por la extensión del archivo, o nil.
function Importar.tipo(archivo)
    local ext = tostring(archivo or ""):lower():match("%.(%w+)$")
    for tipo, e in pairs(DB.EXTENSIONES) do
        if e == ext then return tipo end
    end
end

local function copiar(origen, destino)
    local entrada = io.open(origen, "rb")
    if not entrada then return false end
    local salida = io.open(destino, "wb")
    if not salida then
        entrada:close()
        return false
    end
    local ok = true
    while true do
        local datos = entrada:read(BLOQUE)
        if not datos then break end
        if not salida:write(datos) then
            ok = false
            break
        end
    end
    entrada:close()
    salida:close()
    return ok
end

function Importar.instalar(ruta, archivo, carpeta, mover)
    archivo = tostring(archivo or ""):gsub("^.*[/\\]", "")
    local tipo = Importar.tipo(archivo)
    if not tipo then
        return nil, "«" .. archivo .. "» no es un módulo. " .. Importar.AYUDA
    end
    local db, err = DB.abrir(ruta)
    if not db then return nil, "No se pudo abrir «" .. archivo .. "»: " .. tostring(err) end
    local valido, motivo = db:comprobarModulo(tipo)
    local nombre = archivo
    if valido then
        local ok, filas = pcall(db.filas, db, "SELECT valor FROM meta WHERE clave = 'nombre'")
        if ok and filas[1] and filas[1][1] then nombre = filas[1][1] end
    end
    db:cerrar()
    if not valido then return nil, "«" .. archivo .. "» no es un módulo válido: " .. tostring(motivo) end

    local sub = carpeta .. "/" .. Importar.CARPETAS[tipo]
    if lfs.attributes(sub, "mode") ~= "directory" then
        if lfs.attributes(carpeta, "mode") ~= "directory" then lfs.mkdir(carpeta) end
        lfs.mkdir(sub)
        if lfs.attributes(sub, "mode") ~= "directory" then sub = carpeta end
    end
    local destino = sub .. "/" .. archivo
    if destino == ruta then return nil, "«" .. archivo .. "» ya está en la carpeta de módulos." end
    local reemplazado = lfs.attributes(destino, "mode") == "file"
    local temporal = destino .. ".importando"
    os.remove(temporal)
    if not (mover and os.rename(ruta, temporal)) and not copiar(ruta, temporal) then
        os.remove(temporal)
        return nil, "No se pudo copiar «" .. archivo .. "» a " .. sub .. " (¿falta espacio?)."
    end
    if not os.rename(temporal, destino) then
        os.remove(temporal)
        return nil, "No se pudo guardar «" .. archivo .. "» en " .. sub .. "."
    end
    return { nombre = nombre, tipo = tipo, destino = destino, reemplazado = reemplazado }
end

--- «Reina-Valera 1960 (Biblia)», y si reemplazó a otro archivo, lo dice.
function Importar.describir(r)
    return r.nombre .. " (" .. Importar.TIPOS[r.tipo] .. ")" .. (r.reemplazado and ", reemplazó al anterior" or "")
end

return Importar
