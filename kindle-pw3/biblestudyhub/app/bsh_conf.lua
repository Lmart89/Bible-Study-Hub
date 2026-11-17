--[[--
Configuración general de la app (alfa 11), en el archivo de texto settings/bsh.conf.
Está fuera del plugin para que se conserve al copiar una versión nueva, y se puede editar a mano:

    # Bible Study Hub
    carpeta_modulos=/mnt/us/modulos

Conf.VERSION es la versión que muestra la app. Los ajustes de lectura siguen en G_reader_settings.
--]]--

local DataStorage = require("datastorage")
local logger = require("logger")

local Conf = {
    VERSION = "alfa 11",
    -- Dirección del repositorio en GitHub, que se muestra en «Acerca de» (PW3 y Kindle 3).
    -- Vacía hasta publicarlo; por ejemplo: GITHUB = "github.com/usuario/bible-study-hub",
    GITHUB = nil,
}

local ARCHIVO = "bsh.conf"
local ENCABEZADO = "# Bible Study Hub"

local function ruta()
    return DataStorage:getSettingsDir() .. "/" .. ARCHIVO
end

--- Valores del archivo: { clave = valor }. Vacío si no existe.
function Conf.leer()
    local valores = {}
    local f = io.open(ruta(), "r")
    if not f then return valores end
    for linea in f:lines() do
        local clave, valor = linea:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if clave and valor ~= "" then valores[clave] = valor end
    end
    f:close()
    return valores
end

--- Guarda un valor (nil lo quita). Devuelve true, o false si no se pudo escribir.
function Conf.guardar(clave, valor)
    local valores = Conf.leer()
    valores[clave] = valor
    local claves = {}
    for k in pairs(valores) do claves[#claves + 1] = k end
    table.sort(claves)
    local lineas = { ENCABEZADO }
    for _, k in ipairs(claves) do lineas[#lineas + 1] = k .. "=" .. valores[k] end
    -- se escribe aparte y se renombra: un apagón no deja el archivo a medias
    local temporal = ruta() .. ".tmp"
    local f, err = io.open(temporal, "w")
    if not f then
        logger.warn("[BSH] no se pudo escribir", temporal, err)
        return false
    end
    f:write(table.concat(lineas, "\n"), "\n")
    f:close()
    return os.rename(temporal, ruta()) and true or false
end

--- Carpeta donde se buscan los módulos: la del .conf o data/ dentro del plugin.
function Conf.carpetaModulos(plugin_path)
    return Conf.leer().carpeta_modulos or (plugin_path .. "/data")
end

return Conf
