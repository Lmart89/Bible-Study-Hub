--[[--
Actualizaciones por Wi-Fi, sin conectar el Kindle a la PC. Lo comparten Bible Study Hub for K3
(bsh-k3) y Bible Study Hub del PW3 (bsh-pw3); cada app lo configura al abrir:

    Actualizar.configurar{ nombre = "Bible Study Hub for K3", prefijo = "bsh-k3",
        reiniciar = function() … end }   -- cierra las bases y sale con el código 85

El armado en la PC (tools/armar_bsh_k3.py o armar_bsh_pw3.py, con --paquete) genera
<prefijo>-<versión>.tar con la carpeta app (sin los módulos de data) y un manifiesto.txt:
«version 1.2», «app bsh-k3» y, por archivo, «sha256 ruta». Un paquete de otra app no se instala
(los de la 1.1 a la 1.3 del K3 no traen «app»: son bsh-k3). En los ajustes, «Recibir
actualización por Wi-Fi» enciende el servidor web (bsh_servidor_web, con código de 4
cifras, en bsh_recibir); desde el navegador se envía el paquete.

Al llegar se aplica con cuidado: se lee con libarchive, se comprueba la huella de cada archivo y
que solo toque app/ (nunca app/data), se guarda lo actual en app.anterior y se escribe cada
archivo nuevo en uno temporal antes de renombrarlo. Luego la app se reinicia (código 85, que
el script de arranque usa para volver a abrirla). «Volver a la versión anterior» deshace la última.
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Actualizar = {
    nombre = "Bible Study Hub",
    prefijo = "bsh-k3",
    reiniciar = nil, -- function(): cierra la app con el código 85 para que vuelva a abrirse
}

--- o: { nombre, prefijo, reiniciar } (ver arriba).
function Actualizar.configurar(o)
    for k, v in pairs(o) do Actualizar[k] = v end
    return Actualizar
end

Actualizar.MANIFIESTO = "manifiesto.txt"
Actualizar.ANTERIOR = "app.anterior" -- copia de lo que se reemplazó, junto a app

--- Carpeta de la app (donde está app/): la de trabajo de KOReader.
function Actualizar.base()
    return lfs.currentdir()
end

local function leer(ruta)
    local f = io.open(ruta, "rb")
    if not f then return nil end
    local t = f:read("*a")
    f:close()
    return t
end

local function escribir(ruta, datos)
    local f = io.open(ruta, "wb")
    if not f then return false end
    f:write(datos)
    f:close()
    return true
end

--- Crea las carpetas que faltan hasta la de ruta (sin el archivo).
local function carpetas(base, rel)
    local actual = base
    for parte in rel:gmatch("([^/]+)/") do
        actual = actual .. "/" .. parte
        if lfs.attributes(actual, "mode") ~= "directory" then lfs.mkdir(actual) end
    end
end

local function borrarCarpeta(ruta)
    if lfs.attributes(ruta, "mode") ~= "directory" then return end
    for n in lfs.dir(ruta) do
        if n ~= "." and n ~= ".." then
            local r = ruta .. "/" .. n
            if lfs.attributes(r, "mode") == "directory" then borrarCarpeta(r) else os.remove(r) end
        end
    end
    lfs.rmdir(ruta)
end

--- Versión instalada (app/version.txt), o «?».
function Actualizar.version(base)
    local t = leer((base or Actualizar.base()) .. "/app/version.txt")
    return t and t:match("^%s*(.-)%s*$") or "?"
end

--- ¿Se puede escribir esta ruta? Solo dentro de app/, sin subir ni tocar los módulos.
function Actualizar.rutaValida(ruta)
    if type(ruta) ~= "string" or not ruta:match("^app/[%w_%-%./]+$") then return false end
    if ruta:find("..", 1, true) or ruta:find("//", 1, true) then return false end
    if ruta:match("^app/data/") or ruta == "app/data" then return false end
    return true
end

--- Lee el manifiesto: versión y { ruta = sha256 }. Devuelve nil y el error si no es válido.
function Actualizar.leerManifiesto(texto)
    if not texto then return nil, "el paquete no tiene manifiesto" end
    local version = texto:match("^version%s+(%S+)")
    if not version then return nil, "el manifiesto no dice la versión" end
    local app = texto:match("\napp%s+(%S+)") or "bsh-k3"
    if app ~= Actualizar.prefijo then
        return nil, "es un paquete de otra app (" .. app .. "), no de " .. Actualizar.nombre
    end
    local archivos, n = {}, 0
    for huella, ruta in texto:gmatch("\n(%x+)%s+([^\r\n]+)") do
        if #huella ~= 64 then return nil, "huella no válida: " .. ruta end
        if not Actualizar.rutaValida(ruta) then return nil, "ruta no permitida: " .. ruta end
        archivos[ruta] = huella:lower()
        n = n + 1
    end
    if n == 0 then return nil, "el manifiesto no tiene archivos" end
    return version, archivos
end

--- Saca del .tar el manifiesto y todos los archivos que nombra, ya comprobados.
-- Devuelve versión, { ruta = contenido }, o nil y el error. No escribe nada.
-- avance(texto, pct) (opcional) informa cada paso (de 0 a 55 %).
function Actualizar.leerPaquete(ruta_tar, avance)
    avance = avance or function() end
    local Archiver = require("ffi/archiver")
    local sha2 = require("ffi/sha2")
    avance("Abriendo el paquete…", 2)
    local paquete = Archiver.Reader:new()
    if not paquete:open(ruta_tar) then return nil, "no se pudo abrir el paquete: " .. tostring(paquete.err) end
    local entradas = {}
    for entrada in paquete:iterate() do
        if entrada.mode == "file" then entradas[#entradas + 1] = entrada.path end
    end
    local contenidos = {}
    for i, ruta in ipairs(entradas) do
        contenidos[ruta:gsub("^%./", "")] = paquete:extractToMemory(ruta)
        avance("Leyendo el paquete…", 5 + math.floor(30 * i / #entradas))
    end
    paquete:close()
    local version, archivos = Actualizar.leerManifiesto(contenidos[Actualizar.MANIFIESTO])
    if not version then return nil, archivos end
    local total, i = 0, 0
    for _ in pairs(archivos) do total = total + 1 end
    local listos = {}
    for ruta, huella in pairs(archivos) do
        local datos = contenidos[ruta]
        if not datos then return nil, "falta en el paquete: " .. ruta end
        if sha2.sha256(datos) ~= huella then return nil, "llegó dañado: " .. ruta end
        listos[ruta] = datos
        i = i + 1
        avance("Comprobando los archivos…", 35 + math.floor(20 * i / total))
    end
    return version, listos
end

--- Aplica un paquete. Devuelve la versión nueva, o nil y el error (sin haber cambiado nada).
-- avance(texto, pct) (opcional) informa cada paso, de 0 a 100 %.
function Actualizar.aplicar(ruta_tar, base, avance)
    base = base or Actualizar.base()
    avance = avance or function() end
    local version, archivos = Actualizar.leerPaquete(ruta_tar, avance)
    if not version then return nil, archivos end
    local total = 0
    for _ in pairs(archivos) do total = total + 1 end
    -- 1. lo nuevo, en temporales: si algo falla aquí, la app sigue intacta
    local i = 0
    for ruta, datos in pairs(archivos) do
        carpetas(base, ruta)
        if not escribir(base .. "/" .. ruta .. ".nuevo", datos) then
            for r in pairs(archivos) do os.remove(base .. "/" .. r .. ".nuevo") end
            return nil, "no se pudo escribir " .. ruta
        end
        i = i + 1
        avance("Preparando los archivos nuevos…", 55 + math.floor(25 * i / total))
    end
    -- 2. copia de lo actual en app.anterior, con la lista de lo que no existía
    avance("Guardando la versión actual…", 80)
    local anterior = base .. "/" .. Actualizar.ANTERIOR
    borrarCarpeta(anterior)
    lfs.mkdir(anterior)
    local nuevos = {}
    i = 0
    for ruta in pairs(archivos) do
        local actual = leer(base .. "/" .. ruta)
        if actual then
            carpetas(anterior, ruta)
            escribir(anterior .. "/" .. ruta, actual)
        else
            nuevos[#nuevos + 1] = ruta
        end
        i = i + 1
        avance("Guardando la versión actual…", 80 + math.floor(12 * i / total))
    end
    escribir(anterior .. "/nuevos.txt", table.concat(nuevos, "\n"))
    escribir(anterior .. "/version.txt", Actualizar.version(base))
    -- 3. cada temporal ocupa el lugar del archivo
    avance("Instalando…", 95)
    for ruta in pairs(archivos) do
        local destino = base .. "/" .. ruta
        if not os.rename(destino .. ".nuevo", destino) then
            os.remove(destino)
            os.rename(destino .. ".nuevo", destino)
        end
    end
    os.remove(ruta_tar)
    logger.info("[BSH] actualizada a la versión", version)
    return version
end

--- Como aplicar, pero por pasos: entre uno y otro la app sigue atendiendo (la pantalla del
-- Kindle y las consultas de la página web, que así muestra el avance). Al final llama a
-- al_terminar(version) o al_terminar(nil, error).
function Actualizar.aplicarPorPasos(ruta_tar, avance, al_terminar)
    local hilo = coroutine.create(function()
        return Actualizar.aplicar(ruta_tar, nil, function(texto, pct)
            avance(texto, pct)
            coroutine.yield()
        end)
    end)
    local function seguir()
        local ok, version, err = coroutine.resume(hilo)
        if not ok then return al_terminar(nil, tostring(version)) end
        if coroutine.status(hilo) == "dead" then return al_terminar(version, err) end
        UIManager:scheduleIn(0.01, seguir)
    end
    seguir()
end

function Actualizar.hayAnterior(base)
    return lfs.attributes((base or Actualizar.base()) .. "/" .. Actualizar.ANTERIOR .. "/version.txt", "mode") == "file"
end

--- Deshace la última actualización. Devuelve la versión recuperada, o nil y el error.
function Actualizar.volverAnterior(base)
    base = base or Actualizar.base()
    local anterior = base .. "/" .. Actualizar.ANTERIOR
    local version = leer(anterior .. "/version.txt")
    if not version then return nil, "no hay una versión anterior guardada" end
    local function restaurar(dir, rel)
        for n in lfs.dir(dir) do
            if n ~= "." and n ~= ".." then
                local r = dir .. "/" .. n
                local destino = rel and (rel .. "/" .. n) or n
                if lfs.attributes(r, "mode") == "directory" then
                    restaurar(r, destino)
                elseif rel then -- solo lo que está dentro de app/
                    carpetas(base, destino)
                    escribir(base .. "/" .. destino, leer(r))
                end
            end
        end
    end
    restaurar(anterior, nil)
    for ruta in (leer(anterior .. "/nuevos.txt") or ""):gmatch("[^\n]+") do
        if Actualizar.rutaValida(ruta) then os.remove(base .. "/" .. ruta) end
    end
    borrarCarpeta(anterior)
    return version:match("^%s*(.-)%s*$")
end


--- Reinicia la app (con el código 85) tras un aviso de 2 segundos. antes(): justo antes de salir.
local function reiniciarConAviso(texto, antes)
    UIManager:show(InfoMessage:new{ text = texto })
    UIManager:scheduleIn(2, function()
        if antes then antes() end
        if Actualizar.reiniciar then Actualizar.reiniciar() else UIManager:restartKOReader() end
    end)
end

--- Pantalla «Recibir actualización» ------------------------------------------------------

local Recibir = require("bsh_recibir")
local Pantalla = Recibir:extend{
    name = "bsh_actualizar",
    pregunta_wifi = "El Wi-Fi está apagado o sin red.\n¿Encenderlo para recibir la actualización?",
}

function Pantalla:init()
    self.titulo = "Actualizar " .. Actualizar.nombre
    self.detalle = "Versión instalada: " .. Actualizar.version()
    self.instrucciones = "Elige allí el paquete " .. Actualizar.prefijo
        .. "-…tar. Se comprueba, se instala y la app se reinicia sola."
    self.destino = Actualizar.base() .. "/settings/" .. Actualizar.prefijo .. "-actualizacion.tar"
    self.pagina = { ayuda = "El archivo " .. Actualizar.prefijo .. "-….tar que genera el armado en la PC",
        reactivar = "Ajustes avanzados → Recibir actualización por Wi-Fi…" }
    Recibir.init(self)
end

--- Llegó un paquete: se instala por pasos (con el avance en el Kindle y en la página) y la app
-- se reinicia. El servidor se apaga justo antes de salir, para que la página vea el final.
function Pantalla:recibir(ruta)
    self.en_proceso = true
    self:avance("Paquete recibido. Comprobando…", 0)
    Actualizar.aplicarPorPasos(ruta, function(texto, pct) self:avance(texto, pct) end, function(version, err)
        if not version then
            os.remove(ruta)
            return self:terminar("No se instaló: " .. tostring(err) .. ". La app no cambió.", false)
        end
        self:terminar(Actualizar.nombre .. " actualizada a la versión " .. version .. ". La app se reinicia.", true)
        -- la página ve el final y enseguida el aviso de cierre (el servidor se apaga al reiniciar)
        self.servidor:anunciarCierre()
        reiniciarConAviso(Actualizar.nombre .. " actualizada a la versión " .. version .. ".\nReiniciando…",
            function() self.servidor:detener() end)
    end)
end

Actualizar.Pantalla = Pantalla

--- Deshace la última actualización, tras confirmar, y reinicia la app.
function Actualizar.preguntarAnterior()
    local guardada = (leer(Actualizar.base() .. "/" .. Actualizar.ANTERIOR .. "/version.txt") or "?"):match("^%s*(.-)%s*$")
    UIManager:show(ConfirmBox:new{
        text = "¿Volver a la versión " .. guardada .. "?\nAhora está la " .. Actualizar.version() .. ". La app se reiniciará.",
        ok_text = "Volver",
        cancel_text = "Cancelar",
        ok_callback = function()
            local version, err = Actualizar.volverAnterior()
            if not version then
                return UIManager:show(InfoMessage:new{ text = "No se pudo volver:\n" .. tostring(err) })
            end
            reiniciarConAviso("Volviendo a la versión " .. version .. ".\nReiniciando…")
        end,
    })
end

return Actualizar
