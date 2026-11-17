--[[--
Panel lateral de la Biblia para el Kindle 3: ocupa ⅔ del ancho, debajo de la barra, encima del
lector. Es una ventana aparte: abrirlo o cerrarlo no vuelve a maquetar el capítulo de detrás.

Una sola tabla de botones (un solo foco): el D-Pad recorre las opciones, Press elige y Menu o Back
cierran. Cada opción cierra el panel antes de hacer lo suyo.

    UIManager:show(Panel:new{ titulo = "Para Juan 3:16", opciones = { { texto, accion }, … },
        arriba = alto de la barra }, nil, nil, 0, alto de la barra)
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Input = Device.input
local Screen = Device.screen

local Panel = InputContainer:extend{
    name = "bsh_k3_panel",
    titulo = "",
    opciones = nil,
    arriba = 0, -- alto de la barra del lector: el panel empieza debajo
}

function Panel:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local ancho = math.floor(screen_w * 2 / 3)
    local borde = Size.border.window * 2
    local interior = ancho - borde
    local relleno = Size.padding.large
    local alto = screen_h - self.arriba
    self.dimen = Geom:new{ x = 0, y = self.arriba, w = ancho, h = alto }
    if Device:hasKeys() then
        self.key_events.Cerrar = { { Input.group.Back }, { "Menu" } }
    end
    local filas = {}
    for _, o in ipairs(self.opciones or {}) do
        local accion = o[2]
        filas[#filas + 1] = { { text = o[1], align = "left", callback = function()
            UIManager:close(self)
            accion()
        end } }
    end
    self.tabla = ButtonTable:new{ width = interior - 2 * relleno, show_parent = self, buttons = filas }
    self[1] = FrameContainer:new{
        width = ancho, height = alto,
        padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "top",
            FrameContainer:new{
                width = interior, height = alto, padding = relleno, bordersize = 0,
                VerticalGroup:new{
                    align = "left",
                    TextWidget:new{ text = self.titulo, face = Font:getFace("x_smallinfofont"),
                        fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = interior - 2 * relleno },
                    VerticalSpan:new{ width = relleno },
                    self.tabla,
                },
            },
            LineWidget:new{ dimen = Geom:new{ w = borde, h = alto } },
        },
    }
end

function Panel:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

--- Al cerrarse, se repinta y refresca solo su zona: el texto de detrás no cambió.
function Panel:onCloseWidget()
    local zona = self.dimen
    UIManager:setDirty(nil, function() return "ui", zona end)
end

function Panel:onCerrar()
    UIManager:close(self)
    return true
end

return Panel
