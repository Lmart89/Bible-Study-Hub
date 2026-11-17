--[[--
Pantalla «Recibir por Wi-Fi»: enciende el servidor web (bsh_servidor_web en modo paquete, con
código de 4 cifras) y espera un archivo desde el navegador del PC o del celular. Funciona sin
Internet, también con el hotspot del celular. Cancela con Back (K3) o con el botón Cancelar (táctil).

La usan la actualización de la app (bsh_actualizar, en el K3 y el PW3) y «Importar bosquejo de
Word» (bsh_k3_notas):

    Recibir:new{
        titulo = "…", detalle = "…",          -- arriba, en el Kindle y en la página web
        instrucciones = "…",                  -- en el Kindle, bajo el código
        pagina = { aceptar = ".docx", elegir, ayuda, recibido },  -- la página web (ver el servidor)
        destino = ruta,                       -- donde se guarda lo recibido
        recibir = function(pantalla, ruta, nombre) … end,
        boton = "Listo",                      -- (opcional, táctil) texto del botón (si no, «Cancelar»)
        al_cerrar = function() … end,         -- (opcional) después de cerrarse la pantalla
    }

recibir puede mostrar un estado con pantalla:mostrar(texto) o cerrar con pantalla:cerrarConAviso().
Para la página web: pantalla:avance(texto, pct) muestra el avance (barra en el navegador) y
pantalla:terminar(texto, ok) lo da por terminado. Si recibir no llama a terminar (ni deja
pantalla.en_proceso = true para terminar más tarde), se termina solo con el último estado.
La página dice «Bible Study Hub - Wifi Server» con el logo de la app (campo marca).
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Input = Device.input
local Screen = Device.screen

local ESPERA_WIFI = 60

-- Logo de la app (app/iconos/logo.svg) para la cabecera de la página web
local LOGO = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="Bible Study Hub">'
    .. '<path d="M50 5L89 27.5V72.5L50 95L11 72.5V27.5Z" fill="#000"/>'
    .. '<path d="M50 32C42 26 30 25 20 28V68C30 65 42 66 50 73C58 66 70 65 80 68V28C70 25 58 26 50 32Z" fill="#fff"/>'
    .. '<rect x="47" y="30" width="6" height="43" fill="#000"/><rect x="35" y="42" width="30" height="6" fill="#000"/></svg>'

local Recibir = InputContainer:extend{
    name = "bsh_recibir",
    covers_fullscreen = true,
    titulo = "Recibir un archivo",
    detalle = nil,
    instrucciones = "Elige allí el archivo.",
    pagina = nil,
    destino = nil,
    recibir = nil, -- function(pantalla, ruta, nombre)
    boton = "Cancelar", -- en el táctil, el botón para salir
    al_cerrar = nil, -- function(), ya cerrada la pantalla
    marca = { nombre = "Bible Study Hub - Wifi Server", logo = LOGO }, -- cabecera de la página web
    pregunta_wifi = "El Wi-Fi está apagado o sin red.\n¿Encenderlo para recibir el archivo?",
}

function Recibir:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Cerrar = { { Input.group.Back } } end
    self.tactil = Device.isTouchDevice and Device:isTouchDevice() or false
    self.estado = "Conectando al Wi-Fi…"
    local Servidor = require("bsh_servidor_web")
    self.servidor = Servidor.nuevo{
        paquete = function(ruta, nombre) UIManager:nextTick(function() self:procesar(ruta, nombre) end) end,
        destino = self.destino,
        titulo = self.titulo,
        detalle = self.detalle,
        pagina = self.pagina,
        al_evento = function(texto) self:mostrar(texto) end,
        marca = self.marca,
    }
    self:construir()
end

function Recibir:construir()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local ancho = screen_w - 6 * Screen:scaleBySize(10)
    local function texto(t, tam, negrita)
        return TextBoxWidget:new{ text = t, face = Font:getFace("cfont", tam), bold = negrita, width = ancho,
            alignment = "center" }
    end
    local espacio = VerticalSpan:new{ width = Screen:scaleBySize(24) }
    local cuerpo = VerticalGroup:new{ align = "center", texto(self.titulo, 24, true) }
    if self.detalle then cuerpo[#cuerpo + 1] = texto(self.detalle, 18) end
    cuerpo[#cuerpo + 1] = espacio
    if self.direccion then
        cuerpo[#cuerpo + 1] = texto("En el navegador del PC o del celular, en la misma red Wi-Fi, abre:", 17)
        cuerpo[#cuerpo + 1] = texto(self.direccion, 28, true)
        cuerpo[#cuerpo + 1] = espacio
        cuerpo[#cuerpo + 1] = texto("Código para entrar", 17)
        cuerpo[#cuerpo + 1] = texto(self.servidor.pin, 40, true)
        cuerpo[#cuerpo + 1] = espacio
        cuerpo[#cuerpo + 1] = texto(self.instrucciones .. (self.tactil and "" or " Back para cancelar."), 16)
        if self.ultimo then cuerpo[#cuerpo + 1] = texto(self.ultimo, 18, true) end
    else
        cuerpo[#cuerpo + 1] = texto(self.estado, 20)
    end
    if self.tactil then -- el PW3 no tiene Back
        cuerpo[#cuerpo + 1] = espacio
        cuerpo[#cuerpo + 1] = Button:new{ text = self.boton, width = math.floor(screen_w / 2),
            show_parent = self, callback = function() self:cerrarConAviso() end }
    end
    self[1] = FrameContainer:new{
        width = screen_w, height = screen_h, background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{ dimen = Geom:new{ w = screen_w, h = screen_h }, cuerpo },
    }
end

function Recibir:rehacer()
    if self.cerrada then return end
    self:free()
    self:construir()
    UIManager:setDirty(self, "ui")
end

--- Muestra un estado bajo las instrucciones («Recibido. Convirtiendo…», un error…).
function Recibir:mostrar(texto)
    self.ultimo = texto
    self:rehacer()
end

--- Llegó un archivo: lo entrega a recibir y, si no lo dio por terminado, lo termina con el
-- último estado (un texto que empieza con «No » es un error).
function Recibir:procesar(ruta, nombre)
    self.en_proceso = false
    local ok, err = pcall(self.recibir, self, ruta, nombre)
    if not ok then return self:terminar("Error: " .. tostring(err), false) end
    local p = self.servidor.progreso
    if not p.fin and not self.en_proceso then
        local texto = self.ultimo or "Listo."
        self:terminar(texto, not texto:match("^No "))
    end
end

--- Avance de lo que se hace con el archivo: en la página, una barra; en el Kindle, el texto
-- (con el %, y solo cada 10 % para no repintar la tinta a cada paso).
function Recibir:avance(texto, pct)
    self.servidor:progresar(texto, pct, false)
    local paso = pct and math.floor(pct / 10)
    if pct == nil or texto ~= self.texto_avance or paso ~= self.paso_avance then
        self.texto_avance, self.paso_avance = texto, paso
        self:mostrar(texto .. (pct and string.format(" %d %%", pct) or ""))
    end
end

--- Terminado (ok: true bien, false error): la página lo muestra en verde o rojo.
function Recibir:terminar(texto, ok)
    self.en_proceso = false
    self.texto_avance, self.paso_avance = nil, nil
    self.servidor:progresar(texto, 100, true, ok)
    self:mostrar(texto)
end

--- Cierra con un aviso (Wi-Fi apagado, error…) y refresca la pantalla completa.
function Recibir:cerrarConAviso(texto)
    -- si se cierra en medio de un archivo (p. ej. el bosquejo de Word, que al terminar abre la
    -- nota), la página primero ve el final y luego el aviso de cierre
    local p = self.servidor.progreso
    if not self.cerrada and p and p.fin == false then
        self:terminar(texto or "Listo. Mira el Kindle.", not (texto and texto:match("^No ")))
    end
    if not self.cerrada then UIManager:close(self, "full") end
    if texto then UIManager:show(InfoMessage:new{ text = texto }) end
end

--- Enciende el servidor; si el Wi-Fi está apagado, pregunta (Cancelar vuelve atrás).
function Recibir:encender()
    local function iniciar()
        if self.cerrada or self.servidor.tcp then return end
        local ok, err = self.servidor:iniciar()
        if not ok then return self:cerrarConAviso("No se pudo iniciar el servidor:\n" .. tostring(err)) end
        local ip = require("bsh_servidor_web").ip()
        self.direccion = "http://" .. (ip or "?") .. ":" .. self.servidor.puerto
        self:rehacer()
    end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or NetworkMgr:isConnected() then return iniciar() end
    UIManager:show(ConfirmBox:new{
        text = self.pregunta_wifi,
        ok_text = "Encender",
        cancel_text = "Cancelar",
        ok_callback = function()
            local bien, resultado = pcall(NetworkMgr.turnOnWifiAndWaitForConnection, NetworkMgr, iniciar)
            if not bien or resultado == false then return self:cerrarConAviso("No se pudo encender el Wi-Fi.") end
            UIManager:scheduleIn(ESPERA_WIFI, function()
                if not self.cerrada and not self.servidor.tcp then
                    self:cerrarConAviso("No se pudo conectar a una red Wi-Fi.")
                end
            end)
        end,
        cancel_callback = function() self:cerrarConAviso() end,
    })
end

function Recibir:onShow()
    UIManager:setDirty(self, "flashui")
    UIManager:nextTick(function() self:encender() end)
    return true
end

function Recibir:onCerrar()
    self:cerrarConAviso()
    return true
end

function Recibir:onCloseWidget()
    self.cerrada = true
    -- la página consulta /estado cada segundo: se anuncia el cierre y se deja encendido un
    -- momento para que alcance a decir que hay que volver a activar el servidor
    local servidor = self.servidor
    servidor:anunciarCierre()
    if servidor.tcp then
        UIManager:scheduleIn(2, function() servidor:detener() end)
    else
        servidor:detener()
    end
    if self.al_cerrar then UIManager:nextTick(self.al_cerrar) end
end

return Recibir
