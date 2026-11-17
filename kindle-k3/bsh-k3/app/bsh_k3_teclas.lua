--[[--
Teclas globales del Kindle 3, leídas antes que cualquier pantalla con el gancho de entrada de
KOReader (Input:registerEventAdjustHook), sin cambiar el núcleo:

  * Home: vuelve a la Biblia desde cualquier pantalla o menú (en la edición de una nota, antes
    pregunta si guardar). La tecla no llega a las pantallas: así ningún campo de texto la usa.
  * Back mantenido EMERGENCIA segundos: cierre de emergencia, sin confirmar. Una pulsación corta
    sigue llegando a las pantallas como siempre (cerrar, volver); las repeticiones de la tecla
    mantenida no llegan.

El gancho no se puede quitar: queda instalado y, sin app abierta, no hace nada.
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")

local Teclas = {}

Teclas.EMERGENCIA = 5 -- segundos con Back pulsado

local EV_KEY = 1
local PULSADA, SUELTA = 1, 0

local acciones = nil -- { al_inicio = function(), al_emergencia = function() }
local instalado = false
local cuenta_atras = nil

local function cancelar()
    if cuenta_atras then
        UIManager:unschedule(cuenta_atras)
        cuenta_atras = nil
    end
end

--- Lo que hace cada tecla. Se separa del gancho para poder probarlo sin dispositivo.
-- Devuelve true si la tecla queda anulada (no debe llegar a las pantallas).
function Teclas.procesar(nombre, valor)
    if not acciones then return false end
    if nombre == "Back" then
        if valor == PULSADA and not cuenta_atras then
            cuenta_atras = function()
                cuenta_atras = nil
                if acciones and acciones.al_emergencia then acciones.al_emergencia() end
            end
            UIManager:scheduleIn(Teclas.EMERGENCIA, cuenta_atras)
        elseif valor == SUELTA then
            cancelar()
        else
            -- repetición mientras se mantiene: si llegara, cerraría una pantalla tras otra
            return true
        end
        return false
    elseif nombre == "Home" then
        if valor == PULSADA then
            UIManager:nextTick(function()
                if acciones and acciones.al_inicio then acciones.al_inicio() end
            end)
        end
        return true -- ni la pulsación ni la suelta llegan a las pantallas
    end
    return false
end

--- Activa las teclas globales. o: { al_inicio, al_emergencia }.
function Teclas.activar(o)
    acciones = o
    if instalado or not Device:hasKeys() then return end
    instalado = true
    Device.input:registerEventAdjustHook(function(input, ev)
        if ev.type ~= EV_KEY or not acciones then return end
        local nombre = input.event_map[ev.code]
        if nombre and Teclas.procesar(nombre, ev.value) then
            ev.code = 0 -- sin nombre en el mapa: KOReader la ignora
        end
    end)
end

function Teclas.desactivar()
    cancelar()
    acciones = nil
end

return Teclas
