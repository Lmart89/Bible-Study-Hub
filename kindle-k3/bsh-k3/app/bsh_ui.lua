--[[--
Piezas de interfaz comunes (alfa 8):

  * UI.barra{...}: barra superior como la del lector (iconos grandes, botón central que ocupa el
    espacio libre y línea gruesa debajo). La usan los comentarios y el diccionario.
  * UI.FilaMenu: fila tocable del panel lateral y de la pantalla de ajustes.
  * UI.vistaPrevia{...}: ventana flotante centrada con HTML desplazable. No saca del módulo
    actual: tocar fuera, ✕ o Atrás la cierran.
  * UI.previaVerso{...}: vista previa de un pasaje bíblico tocado en una nota, un comentario o
    un diccionario (enlaces verso://libro-capítulo-versículo o …-versículo-hasta).
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Ajustes = require("bsh_ajustes_lectura")
local Libros = require("bsh_libros")
local Input = Device.input
local Screen = Device.screen

local UI = {}

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- Invierte un instante un marco ya pintado y luego llama a callback: confirma dónde se tocó.
-- Es el destello de los botones de KOReader (button.lua) y respeta su ajuste flash_ui.
local function destello(marco, callback)
    if not callback then return end
    local d = marco.dimen
    if not d or G_reader_settings:isFalse("flash_ui") then
        callback()
        return
    end
    marco.invert = true
    UIManager:widgetInvert(marco, d.x, d.y)
    UIManager:setDirty(nil, "fast", d)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    marco.invert = false
    UIManager:widgetInvert(marco, d.x, d.y)
    UIManager:setDirty(nil, "fast", d)
    callback()
end

--- Botón con icono: un icono de KOReader (icono = "close") o un SVG propio (archivo = ruta).
local BotonIcono = InputContainer:extend{
    icono = nil, archivo = nil, tam = nil, relleno = nil, callback = nil,
    atenuado = false, -- en gris y no responde al toque
    activo = false, -- con un recuadro: la opción está aplicada
}

function BotonIcono:init()
    local borde = Size.border.thick
    self[1] = FrameContainer:new{
        padding = self.relleno - borde,
        bordersize = borde,
        color = self.activo and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        IconWidget:new{ icon = self.icono, file = self.archivo, width = self.tam, height = self.tam, dim = self.atenuado },
    }
    if Device:isTouchDevice() then
        self.ges_events.Tocar = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        }
    end
end

function BotonIcono:onTocar()
    if self.atenuado then return true end
    destello(self[1], self.callback)
    return true
end

UI.BotonIcono = BotonIcono

--- Barra superior: iconos a la izquierda, botón central, iconos a la derecha y una línea gruesa.
-- o.izquierda / o.derecha: { { icono = "close" } o { archivo = ruta }, con su callback }, …
-- o.texto y o.al_tocar: el botón central. o.show_parent: la pantalla que la contiene.
function UI.barra(o)
    local screen_w = Screen:getWidth()
    -- como en el lector: icono 40 + relleno 12 por lado, zona de toque de ≈ 1 cm en el PW2
    local tam = Screen:scaleBySize(40)
    local relleno = Screen:scaleBySize(12)
    local borde = Size.padding.large
    local separacion = Screen:scaleBySize(6)
    local function grupo(iconos)
        local g = HorizontalGroup:new{ align = "center" }
        for i, it in ipairs(iconos or {}) do
            if i > 1 then g[#g + 1] = HorizontalSpan:new{ width = separacion } end
            g[#g + 1] = BotonIcono:new{ icono = it.icono, archivo = it.archivo, tam = tam, relleno = relleno,
                atenuado = it.atenuado, callback = it.callback }
        end
        return g
    end
    local izq, der = grupo(o.izquierda), grupo(o.derecha)
    local ancho = screen_w - 2 * borde - izq:getSize().w - der:getSize().w
    local centro = Button:new{
        text = o.texto or "",
        width = ancho - 2 * Size.padding.default,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        show_parent = o.show_parent,
        callback = function()
            if o.al_tocar then o.al_tocar() end
        end,
    }
    local alto = math.max(izq:getSize().h, der:getSize().h, centro:getSize().h)
    return VerticalGroup:new{
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = borde },
            izq,
            CenterContainer:new{ dimen = Geom:new{ w = ancho, h = alto }, centro },
            der,
            HorizontalSpan:new{ width = borde },
        },
        LineWidget:new{ dimen = Geom:new{ w = screen_w, h = Size.line.thick * 2 } },
    }
end

--- Fila de menú: «Etiqueta ........ número o valor». Tocarla llama a callback.
-- icono (opcional): un símbolo de la fuente de iconos de KOReader (nerdfonts/symbols.ttf, que el
-- texto usa como respaldo), p. ej. "\u{F02D}"; va en una columna fija para que los textos se alineen.
UI.FilaMenu = InputContainer:extend{
    texto = nil, numero = nil, ancho = nil, actual = false, callback = nil, icono = nil,
    deshabilitada = false, -- en gris y no responde al toque
}

function UI.FilaMenu:init()
    local relleno = Size.padding.large
    local cara = Font:getFace("cfont", 20)
    local color = self.deshabilitada and Blitbuffer.COLOR_DARK_GRAY or nil
    local num = TextWidget:new{ text = self.numero and tostring(self.numero) or "", face = cara, bold = true }
    local interior = self.ancho - 2 * relleno
    local icono, ancho_icono = nil, 0
    if self.icono then
        ancho_icono = Screen:scaleBySize(34)
        local simbolo = TextWidget:new{ text = self.icono, face = cara, fgcolor = color }
        icono = CenterContainer:new{ dimen = Geom:new{ w = ancho_icono, h = simbolo:getSize().h }, simbolo }
    end
    local etiqueta = TextWidget:new{ text = self.texto, face = cara, bold = self.actual, fgcolor = color,
        max_width = interior - ancho_icono - num:getSize().w - relleno }
    local fila = HorizontalGroup:new{ align = "center" }
    if icono then fila[#fila + 1] = icono end
    fila[#fila + 1] = etiqueta
    fila[#fila + 1] = HorizontalSpan:new{ width = interior - ancho_icono - etiqueta:getSize().w - num:getSize().w }
    fila[#fila + 1] = num
    self[1] = FrameContainer:new{
        width = self.ancho,
        padding = relleno,
        bordersize = 0,
        background = self.actual and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        fila,
    }
    if Device:isTouchDevice() then
        self.ges_events.Tocar = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        }
    end
end

function UI.FilaMenu:onTocar()
    if self.deshabilitada then return true end
    destello(self[1], self.callback)
    return true
end

local CSS_PREVIA = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.4; text-align: justify; }
p { margin: 0 0 0.4em 0; }
p.aviso { color: #555555; font-style: italic; }
a { color: black; }
]]

--- Ventana flotante centrada: título, ✕, línea y HTML desplazable (deslizar o tocar arriba/abajo).
-- o.titulo, o.html; o.ajustes (tabla de Ajustes.leer) para la letra; o.alto = fracción de la
-- pantalla (0.4); o.botones = { { texto, callback }, … } al pie (cada uno cierra la ventana antes).
-- Es una ventana aparte (recibe los toques) y blanca con borde negro grueso (tinta electrónica).
function UI.vistaPrevia(o)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local ancho = math.floor(screen_w * 0.9)
    local borde = Size.border.window * 2
    local relleno = Size.padding.large
    local interior = ancho - 2 * borde - 2 * relleno
    local ventana = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h } }
    local marco, vista
    local function cerrar()
        UIManager:close(ventana)
        return true
    end

    local cierre = BotonIcono:new{ icono = "close", tam = Screen:scaleBySize(32), relleno = Size.padding.default, callback = cerrar }
    local titulo = TextWidget:new{
        text = o.titulo or "",
        face = Font:getFace("cfont", 22),
        bold = true,
        max_width = interior - cierre:getSize().w - relleno,
    }
    local a = o.ajustes or Ajustes.leer("biblia")
    vista = ScrollHtmlWidget:new{
        html_body = o.html or "",
        css = CSS_PREVIA .. Ajustes.css(a),
        default_font_size = Ajustes.letra(a),
        width = interior,
        height = math.floor(screen_h * (o.alto or 0.4)),
        dialog = ventana,
        html_link_tapped_callback = o.al_enlace,
    }
    local grupo = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            titulo,
            HorizontalSpan:new{ width = interior - titulo:getSize().w - cierre:getSize().w },
            cierre,
        },
        LineWidget:new{ dimen = Geom:new{ w = interior, h = Size.line.thick } },
        VerticalSpan:new{ width = relleno },
        vista,
    }
    if o.botones and #o.botones > 0 then
        local fila = {}
        for _, b in ipairs(o.botones) do
            fila[#fila + 1] = { text = b.texto, callback = function()
                UIManager:close(ventana)
                if b.callback then b.callback() end
            end }
        end
        grupo[#grupo + 1] = VerticalSpan:new{ width = relleno }
        grupo[#grupo + 1] = ButtonTable:new{ width = interior, buttons = { fila }, show_parent = ventana }
    end
    marco = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = borde,
        radius = Size.radius.window,
        padding = relleno,
        grupo,
    }
    ventana[1] = CenterContainer:new{ dimen = Geom:new{ w = screen_w, h = screen_h }, marco }

    if Device:isTouchDevice() then
        ventana.ges_events = {
            TocarFuera = { GestureRange:new{ ges = "tap", range = ventana.dimen } },
            Deslizar = { GestureRange:new{ ges = "swipe", range = ventana.dimen } },
        }
    end
    if Device:hasKeys() then
        ventana.key_events = { Cerrar = { { Input.group.Back } } }
    end
    -- solo llegan aquí los toques que no atendió nada de dentro (✕, botones, el texto)
    ventana.onTocarFuera = function(_ventana, _arg, ges)
        if marco.dimen and marco.dimen:contains(ges.pos) then return true end
        return cerrar()
    end
    -- deslizar a los lados dentro pasa de página, como en el lector; fuera, cierra
    ventana.onDeslizar = function(_ventana, _arg, ges)
        if marco.dimen and marco.dimen:contains(ges.pos) then
            if ges.direction == "west" then vista:scrollText(1) elseif ges.direction == "east" then vista:scrollText(-1) end
            return true
        end
        return cerrar()
    end
    ventana.onCerrar = cerrar
    ventana.onShow = function()
        UIManager:setDirty(ventana, function() return "ui", marco.dimen end)
        return true
    end
    -- UIManager:close sin modo de refresco solo repinta en memoria: se refresca la zona del marco
    -- para que la tinta no siga mostrando la ventana (mismo arreglo que el panel del editor).
    ventana.onCloseWidget = function()
        UIManager:setDirty(nil, function() return "ui", marco.dimen end)
    end
    UIManager:show(ventana)
end

--- Vista previa de un pasaje tocado (verso://libro-capítulo-versículo o …-versículo-hasta), en la
-- Biblia que está abierta en el lector. o.uri; o.biblia (DB); o.al_abrir(libro, cap, verso)
-- opcional: botón «Abrir en el lector». o.resaltado opcional: el HTML del versículo ya preparado
-- (resultado de búsqueda con las palabras en negrita). Devuelve true si el enlace era un pasaje.
function UI.previaVerso(o)
    local libro, cap, desde, hasta = (o.uri or ""):match("^verso://(%d+)%-(%d+)%-(%d+)%-?(%d*)$")
    if not libro then return false end
    libro, cap, desde = tonumber(libro), tonumber(cap), tonumber(desde)
    hasta = math.min(math.max(tonumber(hasta) or desde, desde), desde + 30)
    local ref = Libros.nombre(libro) .. " " .. cap .. ":" .. desde .. (hasta ~= desde and ("-" .. hasta) or "")
    local html
    if o.resaltado then
        html = "<p><b>" .. desde .. "</b> " .. o.resaltado .. "</p>"
    elseif not o.biblia then
        html = '<p class="aviso">La Biblia no está abierta.</p>'
    else
        local partes = {}
        for _, f in ipairs(o.biblia:pasaje(libro, cap, desde, hasta)) do
            partes[#partes + 1] = "<p><b>" .. f[1] .. "</b> " .. (f[2] or "") .. "</p>"
        end
        html = #partes > 0 and table.concat(partes, "\n")
            or ('<p class="aviso">' .. escapar(ref) .. " no está en esta Biblia.</p>")
    end
    UI.vistaPrevia{
        titulo = ref,
        html = html,
        ajustes = Ajustes.leer("biblia"),
        botones = o.al_abrir and {
            { texto = "Cerrar" },
            { texto = "Abrir en el lector", callback = function() o.al_abrir(libro, cap, desde) end },
        } or nil,
    }
    return true
end

return UI
