--[[--
Paso a los nombres actuales (1.8). Hasta la 1.7 los módulos se llamaban pruebabiblia_*, bshk3_* y
biblestudyhub_*, y los datos del usuario settings/pruebabiblia_usuario.sqlite, pruebabiblia.conf y
los ajustes «pruebabiblia_…». Cada app lo llama al abrir, antes de leer nada:

    require("bsh_migracion").ejecutar{ limpiar_app = true }

  * Ajustes: cada «pruebabiblia_x» se copia a «bsh_x» si este aún no existe.
  * Datos: pruebabiblia_usuario.sqlite → bsh_usuario.sqlite y pruebabiblia.conf → bsh.conf, también
    copiados. Los originales se quedan: si se vuelve a la versión anterior, esta sigue con ellos.
  * Carpeta app (limpiar_app): los módulos con los nombres viejos que dejó la actualización pasan a
    app.anterior/app, de modo que «Volver a la versión anterior» los recupere. Se conservan los dos
    puentes (bshk3_app, bshk3_base en el Kindle 3; biblestudyhub_app y _base en el PW3), porque
    reader.lua y el núcleo de KOReader, que una actualización no cambia, los siguen pidiendo.

Todo es idempotente: si ya se hizo, no cambia nada.
--]]--

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Migracion = {}

Migracion.ARCHIVOS = {
    { "pruebabiblia_usuario.sqlite", "bsh_usuario.sqlite" },
    { "pruebabiblia.conf", "bsh.conf" },
}

-- módulos con nombre viejo que sobran en app/ tras actualizar
Migracion.VIEJOS = { "^pruebabiblia_.+%.lua$", "^bshk3_.+%.lua$", "^biblestudyhub_.+%.lua$", "^bshtexteditor_servidor%.lua$" }
-- puentes que se quedan: los pide reader.lua (o el núcleo de KOReader) de instalaciones anteriores
Migracion.PUENTES = {
    ["bshk3_app.lua"] = true, ["bshk3_base.lua"] = true,
    ["biblestudyhub_app.lua"] = true, ["biblestudyhub_base.lua"] = true,
}

--- Copia los ajustes «pruebabiblia_x» a «bsh_x». Devuelve cuántos copió.
function Migracion.ajustes(ajustes)
    ajustes = ajustes or G_reader_settings
    if not (ajustes and type(ajustes.data) == "table") then return 0 end
    local nuevos = {}
    for clave, valor in pairs(ajustes.data) do
        local resto = type(clave) == "string" and clave:match("^pruebabiblia_(.+)$")
        if resto and ajustes.data["bsh_" .. resto] == nil then nuevos["bsh_" .. resto] = valor end
    end
    local n = 0
    for clave, valor in pairs(nuevos) do
        ajustes:saveSetting(clave, valor)
        n = n + 1
    end
    if n > 0 and ajustes.flush then ajustes:flush() end
    return n
end

--- Copia viejo en nuevo si nuevo no existe (por un temporal: un apagón no deja medio archivo).
function Migracion.copiar(viejo, nuevo)
    if lfs.attributes(nuevo, "mode") or lfs.attributes(viejo, "mode") ~= "file" then return false end
    local origen = io.open(viejo, "rb")
    if not origen then return false end
    local datos = origen:read("*a")
    origen:close()
    local temporal = nuevo .. ".tmp"
    local destino = io.open(temporal, "wb")
    if not destino then return false end
    local ok = destino:write(datos)
    destino:close()
    if not ok or not os.rename(temporal, nuevo) then
        os.remove(temporal)
        return false
    end
    return true
end

--- Copia los datos del usuario a sus nombres nuevos. Devuelve cuántos copió.
function Migracion.datos(carpeta)
    carpeta = carpeta or DataStorage:getSettingsDir()
    local n = 0
    for _, par in ipairs(Migracion.ARCHIVOS) do
        if Migracion.copiar(carpeta .. "/" .. par[1], carpeta .. "/" .. par[2]) then n = n + 1 end
    end
    return n
end

local function esViejo(nombre)
    if Migracion.PUENTES[nombre] then return false end
    for _, patron in ipairs(Migracion.VIEJOS) do
        if nombre:match(patron) then return true end
    end
    return false
end

--- Saca de app/ los módulos con nombre viejo. Con una versión anterior guardada (app.anterior),
-- van allí para que «Volver a la versión anterior» los recupere; si no, se borran.
function Migracion.limpiarApp(base)
    base = base or lfs.currentdir()
    local app = base .. "/app"
    if lfs.attributes(app, "mode") ~= "directory" then return 0 end
    local anterior = base .. "/app.anterior"
    local guardar = lfs.attributes(anterior .. "/version.txt", "mode") == "file"
    if guardar and lfs.attributes(anterior .. "/app", "mode") ~= "directory" then lfs.mkdir(anterior .. "/app") end
    local viejos = {}
    for nombre in lfs.dir(app) do
        if esViejo(nombre) and lfs.attributes(app .. "/" .. nombre, "mode") == "file" then viejos[#viejos + 1] = nombre end
    end
    for _, nombre in ipairs(viejos) do
        local ruta = app .. "/" .. nombre
        if not (guardar and os.rename(ruta, anterior .. "/app/" .. nombre)) then os.remove(ruta) end
    end
    return #viejos
end

--- o: { limpiar_app = true, base = carpeta de la app, carpeta = la de settings }.
function Migracion.ejecutar(o)
    o = o or {}
    local ok, err = pcall(function()
        local datos = Migracion.datos(o.carpeta)
        local ajustes = Migracion.ajustes(o.ajustes)
        local limpios = o.limpiar_app and Migracion.limpiarApp(o.base) or 0
        if datos + ajustes + limpios > 0 then
            logger.info("[BSH] migración a los nombres nuevos:", datos, "archivos,", ajustes, "ajustes,",
                limpios, "módulos viejos retirados")
        end
    end)
    if not ok then logger.warn("[BSH] migración incompleta:", err) end
end

return Migracion
