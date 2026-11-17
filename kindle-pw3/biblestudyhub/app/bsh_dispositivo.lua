--[[--
Ajustes del Kindle para las apps BSH: contraste del texto, iluminación, modo nocturno, tiempo
antes del reposo y Wi-Fi. Se guardan en la configuración propia de la app (su settings.reader.lua),
no en la de KOReader. Lo usan las pantallas de «Ajustes avanzados» (bsh_ajustes_avanzados).

    Dispositivo.iniciar()      al abrir la app: aplica el contraste y arranca el reloj de reposo
    Dispositivo.alDespertar()  desde onResume de la pantalla principal: cuenta de nuevo desde cero

Contraste: MuPDF dibuja el HTML de la app (HtmlBoxWidget) con una gamma; mayor que 1 oscurece los
grises del texto suavizado sin tocar el blanco ni el negro. Solo se activa en la app independiente,
que es la única que llama a iniciar().

Reposo: el Kindle se duerme solo tras unos minutos sin tocarlo (su propio tiempo). Con un tiempo
propio, la app le pide al Kindle que espere (cada 4 minutos, como el autosuspend de KOReader) y,
cumplido el tiempo, lo duerme ella misma.
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local D = {}

D.CONTRASTES = {
    { nombre = "Normal", gamma = 1.0 },
    { nombre = "Medio", gamma = 1.5 },
    { nombre = "Alto", gamma = 2.2 },
    { nombre = "Máximo", gamma = 3.5 },
}
-- minutos sin tocar la pantalla antes del reposo; 0 = lo decide el Kindle
D.REPOSOS = { 0, 3, 5, 10, 15, 20, 30, 45, 60 }
local AVISO_T1 = 4 * 60 -- el Kindle no se duerme antes de 5 min desde el último aviso

local gamma = 1.0
local reposo = { ultimo = 0, t1 = nil, suspendido = 0, dormido = false }

--- Contraste ------------------------------------------------------------------

--- Índice y nivel actual de D.CONTRASTES.
function D.contraste()
    local g = G_reader_settings:readSetting("bsh_contraste") or 1.0
    for i, c in ipairs(D.CONTRASTES) do
        if c.gamma == g then return i, c end
    end
    return 1, D.CONTRASTES[1]
end

function D.fijarContraste(i)
    local c = D.CONTRASTES[i] or D.CONTRASTES[1]
    G_reader_settings:saveSetting("bsh_contraste", c.gamma ~= 1.0 and c.gamma or nil)
    gamma = c.gamma
end

--- Una sola vez: HtmlBoxWidget dibuja cada página con un DrawContext nuevo; mientras dibuja, ese
-- DrawContext sale ya con la gamma elegida. Con contraste normal no se toca nada.
local function instalarContraste()
    if D._contraste_instalado then return end
    D._contraste_instalado = true
    local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
    local DrawContext = require("ffi/drawcontext")
    local dibujar = HtmlBoxWidget._render
    HtmlBoxWidget._render = function(self, ...)
        if self.bb or gamma == 1.0 then return dibujar(self, ...) end
        local nuevo = DrawContext.new
        DrawContext.new = function(...)
            local dc = nuevo(...)
            dc:setGamma(gamma)
            return dc
        end
        local ok, err = pcall(dibujar, self, ...)
        DrawContext.new = nuevo
        if not ok then error(err, 0) end
    end
end

--- Iluminación y modo nocturno ----------------------------------------------------

function D.hayLuz()
    return Device:hasFrontlight() and true or false
end

--- «Apagada» o la intensidad (0–24 en el PW3).
function D.textoLuz()
    local powerd = Device:getPowerDevice()
    if powerd:isFrontlightOff() then return "Apagada" end
    return tostring(powerd:frontlightIntensity())
end

--- La ventana de luz de KOReader; al cerrarla, al_cerrar() (para poner al día el valor).
function D.mostrarLuz(al_cerrar)
    local FrontLightWidget = require("ui/widget/frontlightwidget")
    local ventana = FrontLightWidget:new{}
    local cerrar = ventana.onCloseWidget
    ventana.onCloseWidget = function(w, ...)
        local r = cerrar and cerrar(w, ...)
        if al_cerrar then al_cerrar() end
        return r
    end
    UIManager:show(ventana)
end

function D.nocturno()
    return G_reader_settings:isTrue("night_mode")
end

--- Invierte la pantalla (texto blanco sobre negro) y lo recuerda para el próximo arranque.
function D.cambiarNocturno()
    local activo = not D.nocturno()
    Device.screen:toggleNightMode()
    G_reader_settings:saveSetting("night_mode", activo)
    if UIManager.ToggleNightMode then UIManager:ToggleNightMode(activo) end
    UIManager:setDirty("all", "full")
end

--- Reposo -------------------------------------------------------------------------

function D.reposo()
    return G_reader_settings:readSetting("bsh_reposo_minutos") or 0
end

function D.textoReposo(m)
    m = m or D.reposo()
    if m == 0 then return "Lo decide el Kindle" end
    if m == 60 then return "1 hora" end
    return m .. " min"
end

local revisar
local function programar(segundos)
    UIManager:unschedule(revisar)
    UIManager:scheduleIn(segundos, revisar)
end

revisar = function()
    local minutos = D.reposo()
    if minutos == 0 then return end
    if Device.screen_saver_mode then -- ya está en reposo: al despertar se cuenta de nuevo
        reposo.dormido = true
        return programar(60)
    end
    if reposo.dormido or (Device.total_suspend_time or 0) ~= reposo.suspendido then
        return D.alDespertar()
    end
    local ahora = UIManager:getTime()
    local resta = minutos * 60 - time.to_number(ahora - reposo.ultimo)
    if resta <= 0 then
        reposo.dormido = true -- no volver a pedirlo: en el Kindle, pedirlo otra vez lo despertaría
        UIManager:suspend()
        return programar(60)
    end
    local powerd = Device:getPowerDevice()
    if Device:isKindle() and powerd.resetT1Timeout then
        if not reposo.t1 or time.to_number(ahora - reposo.t1) >= AVISO_T1 then
            powerd:resetT1Timeout()
            reposo.t1 = ahora
        end
        return programar(math.min(resta, AVISO_T1))
    end
    programar(resta)
end

--- Vuelve a contar desde ahora (al abrir la app, al despertar el Kindle, al cambiar el tiempo).
function D.alDespertar()
    reposo.ultimo = UIManager:getTime()
    reposo.suspendido = Device.total_suspend_time or 0
    reposo.dormido = false
    reposo.t1 = nil
    UIManager:unschedule(revisar)
    if D.reposo() ~= 0 then programar(1) end -- enseguida: el primer aviso al Kindle
end

function D.fijarReposo(minutos)
    G_reader_settings:saveSetting("bsh_reposo_minutos", minutos ~= 0 and minutos or nil)
    D.alDespertar()
end

--- Wi-Fi ----------------------------------------------------------------------------

local function red()
    return require("ui/network/manager")
end

--- Texto del estado y si el Wi-Fi está encendido: «Apagado», «Sin red» o el nombre de la red.
function D.estadoRed()
    local N = red()
    if not N:isWifiOn() then return "Apagado", false end
    if not N:isConnected() then return "Sin red", true end
    local actual = N.getCurrentNetwork and N:getCurrentNetwork()
    return actual and actual.ssid or "Conectado", true
end

function D.cambiarWifi(al_terminar)
    local N = red()
    if N:isWifiOn() then
        N:toggleWifiOff(al_terminar, true)
    else
        N:toggleWifiOn(al_terminar, false, true)
    end
end

--- Lista de redes de KOReader para conectarse a otra (enciende el Wi-Fi si hace falta).
function D.elegirRed(al_terminar)
    local N = red()
    if N:isWifiOn() then
        N.wifi_toggle_long_press = true -- pide la lista aunque ya esté conectado
        N:reconnectOrShowNetworkMenu(al_terminar, true)
    else
        N:toggleWifiOn(al_terminar, true, true)
    end
end

--- «Red: …», «Dirección IP: …» para mostrar en un aviso.
function D.infoRed()
    local estado, encendido = D.estadoRed()
    local lineas = { "Wi-Fi: " .. (encendido and "encendido" or "apagado") }
    if encendido then
        lineas[#lineas + 1] = "Red: " .. estado
        local ok, Servidor = pcall(require, "bsh_servidor_web")
        local ip = ok and Servidor.ip and Servidor.ip()
        lineas[#lineas + 1] = "Dirección IP: " .. (ip or "sin dirección")
    end
    return table.concat(lineas, "\n")
end

--- Arranque ---------------------------------------------------------------------------

function D.iniciar()
    local _, c = D.contraste()
    gamma = c.gamma
    instalarContraste()
    if not D._oyendo and UIManager.event_hook then
        D._oyendo = true
        UIManager.event_hook:register("InputEvent", function() reposo.ultimo = UIManager:getTime() end)
    end
    D.alDespertar()
end

return D
