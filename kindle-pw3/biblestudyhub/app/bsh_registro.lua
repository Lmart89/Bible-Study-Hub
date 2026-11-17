--[[--
Registro de módulos (alfa 10): sabe qué módulos hay instalados y deja abierta la conexión de cada
comentario y diccionario, para que el panel lateral solo tenga que hacer consultas.

  * Registro.pasos(plugin_path): la carga dividida en pasos (uno por módulo) para la pantalla de
    carga, que entre paso y paso deja dibujar la barra.
  * Registro.lista(tipo, plugin_path): { { archivo, ruta, nombre, db }, … } por nombre.
  * Registro.conexion(modulo): la conexión abierta del módulo.
  * Registro.cerrar(): cierra todo (lo hace el lector al salir).
  * Registro.explorar(carpeta): los archivos de módulo de una carpeta, sin abrirlos (alfa 11).
  * Registro.olvidar(): borra la lista guardada, para que la próxima carga lo compruebe todo.

Los módulos se buscan en la carpeta de bsh.conf y sus subcarpetas: la extensión dice el
tipo, así que da igual cómo estén repartidos (por ejemplo data/comentarios/ o todos juntos).

La lista se guarda con el tamaño y la fecha de cada archivo: si no cambiaron, se confía en la
comprobación de la marca que ya se hizo y no se repite.

Cada conexión usa una caché pequeña: con 26 módulos, la caché por defecto de SQLite (2 MB) podría
ocupar 50 MB de los 256 MB del PW2, y las consultas por índice no la necesitan.
--]]--

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local Conf = require("bsh_conf")
local DB = require("bsh_db")

local Registro = {}

local CLAVE = "bsh_registro"
local CACHE_KIB = 256
local PROFUNDIDAD = 3 -- niveles de subcarpetas que se revisan (por si eligen una carpeta muy general)
local TIPOS = {
    { tipo = "biblia", texto = "Verificando recursos…" },
    { tipo = "comentario", texto = "Cargando módulos disponibles…" },
    { tipo = "diccionario", texto = "Verificando índices…" },
}

local listas -- por tipo; nil = sin cargar

local function vacias()
    return { biblia = {}, comentario = {}, diccionario = {} }
end

--- Conexión lista para consultas: caché pequeña y primera lectura (calienta los índices).
local function preparar(db)
    pcall(function() db.conn:exec("PRAGMA cache_size = -" .. CACHE_KIB) end)
    pcall(db.filas, db, "SELECT 1 FROM entradas LIMIT 1")
end

local function cargarModulo(ruta, archivo, tipo, anteriores, nuevos)
    local attr = lfs.attributes(ruta)
    local clave = ruta -- la ruta completa: dos subcarpetas pueden tener un archivo con el mismo nombre
    local antes = anteriores[clave]
    local sin_cambios = antes and attr and antes.tam == attr.size and antes.fecha == attr.modification
    local db = DB.abrir(ruta)
    if not db then return end
    local nombre
    if sin_cambios then
        nombre = antes.nombre
    else
        local valido, motivo = db:comprobarModulo(tipo)
        if not valido then
            logger.warn("[BSH] se omite", ruta, ":", motivo)
            db:cerrar()
            return
        end
        local ok, filas = pcall(db.filas, db, "SELECT valor FROM meta WHERE clave = 'nombre'")
        nombre = ok and filas[1] and filas[1][1] or archivo
    end
    if tipo == "biblia" then
        db:cerrar() -- el lector abre la suya
        db = nil
    else
        preparar(db)
    end
    table.insert(listas[tipo], { archivo = archivo, ruta = ruta, nombre = nombre, db = db })
    if attr then nuevos[clave] = { tam = attr.size, fecha = attr.modification, nombre = nombre } end
end

local function recorrer(carpeta, nivel, tipos, hallados)
    if lfs.attributes(carpeta, "mode") ~= "directory" then return end
    local ok, siguiente, estado = pcall(lfs.dir, carpeta)
    if not ok then return end
    for nombre in siguiente, estado do
        if nombre:sub(1, 1) ~= "." then
            local ruta = carpeta .. "/" .. nombre
            local tipo = tipos[nombre:lower():match("%.(%w+)$")]
            if tipo then
                table.insert(hallados[tipo], { archivo = nombre, ruta = ruta })
            elseif nivel < PROFUNDIDAD then
                recorrer(ruta, nivel + 1, tipos, hallados)
            end
        end
    end
end

--- Archivos de módulo de una carpeta y sus subcarpetas, sin abrirlos:
-- { biblia = { { archivo, ruta }, … }, comentario = …, diccionario = … }, por nombre de archivo.
function Registro.explorar(carpeta)
    local tipos = {}
    for tipo, extension in pairs(DB.EXTENSIONES) do tipos[extension] = tipo end
    local hallados = vacias()
    recorrer(carpeta, 0, tipos, hallados)
    for _, lista in pairs(hallados) do
        table.sort(lista, function(a, b) return a.archivo < b.archivo end)
    end
    return hallados
end

--- La carga en pasos: { { texto = "Verificando índices…", ejecutar = función }, … }. El texto dice
-- qué operación se hace, no qué módulo: varios pasos seguidos comparten el mismo.
function Registro.pasos(plugin_path)
    Registro.cerrar()
    listas = vacias()
    local guardado = G_reader_settings:readSetting(CLAVE) or {}
    local anteriores = guardado.formato == DB.FORMATO and guardado.archivos or {}
    local nuevos = {}
    local pasos = {}
    local hallados = Registro.explorar(Conf.carpetaModulos(plugin_path))
    for _, c in ipairs(TIPOS) do
        for _, m in ipairs(hallados[c.tipo]) do
            pasos[#pasos + 1] = {
                texto = c.texto,
                ejecutar = function()
                    cargarModulo(m.ruta, m.archivo, c.tipo, anteriores, nuevos)
                end,
            }
        end
    end
    pasos[#pasos + 1] = {
        texto = "Preparando módulos…",
        ejecutar = function()
            for _, lista in pairs(listas) do
                table.sort(lista, function(a, b) return a.nombre < b.nombre end)
            end
            G_reader_settings:saveSetting(CLAVE, { formato = DB.FORMATO, archivos = nuevos })
        end,
    }
    return pasos
end

--- Módulos de un tipo. Si la pantalla de carga no se ejecutó, carga aquí de una vez.
function Registro.lista(tipo, plugin_path)
    if not listas then
        local inicio = time.now()
        for _, paso in ipairs(Registro.pasos(plugin_path)) do paso.ejecutar() end
        logger.info("[BSH] registro cargado sin pantalla de carga en", time.to_ms(time.since(inicio)), "ms")
    end
    return listas[tipo]
end

--- Ruta de la Biblia: el primer módulo .ebb válido por nombre de archivo, o nil.
function Registro.rutaBiblia(plugin_path)
    local primera
    for _, m in ipairs(Registro.lista("biblia", plugin_path)) do
        if not primera or m.archivo < primera.archivo then primera = m end
    end
    return primera and primera.ruta
end

--- Conexión abierta de un módulo (la abre si hace falta). Devuelve nil y el error si falla.
function Registro.conexion(modulo)
    if modulo.db then return modulo.db end
    local db, err = DB.abrir(modulo.ruta)
    if not db then return nil, err end
    preparar(db)
    modulo.db = db
    return db
end

--- Borra la lista guardada: la próxima carga vuelve a comprobar todos los módulos.
function Registro.olvidar()
    G_reader_settings:saveSetting(CLAVE, {})
end

--- Cierra las conexiones y olvida la lista en memoria.
function Registro.cerrar()
    for _, lista in pairs(listas or {}) do
        for _, m in ipairs(lista) do
            if m.db then
                m.db:cerrar()
                m.db = nil
            end
        end
    end
    listas = nil
end

return Registro
