--[[--
Pantalla «Acerca de» (alfa 11): logo, nombre, versión y datos de la instalación.
o.datos: { { "Etiqueta", "valor" }, … }, que prepara el lector con lo que ya tiene abierto.
Cada app puede cambiar el nombre, el texto de la versión y la descripción, y quitar la ✕ (sin_cerrar:
en el Kindle 3 se cierra con Back). Bajo la descripción va la dirección de GitHub (Conf.GITHUB), solo
cuando está puesta.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Conf = require("bsh_conf")
local UI = require("bsh_ui")
local Input = Device.input
local Screen = Device.screen

local Acerca = InputContainer:extend{
    name = "bsh_acerca",
    covers_fullscreen = true,
    plugin_path = nil,
    datos = nil,
    nombre = "Bible Study Hub",
    version = nil,     -- texto de la versión (por defecto, «Versión» y la del plugin)
    descripcion = "Estudio bíblico sin conexión para lectores de tinta electrónica con KOReader.",
    sin_cerrar = false, -- sin la ✕ de la esquina
    github = nil,      -- dirección del repositorio (por defecto, Conf.GITHUB); sin ella no se muestra
}

function Acerca:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    local barra = UI.barra{
        texto = "Acerca de",
        show_parent = self,
        derecha = not self.sin_cerrar and { { icono = "close", callback = function() self:onClose() end } } or nil,
    }
    local ancho = math.floor(screen_w * 0.85)
    local logo = Screen:scaleBySize(130)
    local contenido = VerticalGroup:new{
        align = "center",
        IconWidget:new{ file = self.plugin_path .. "/iconos/logo.svg", width = logo, height = logo },
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
        TextWidget:new{ text = self.nombre, face = Font:getFace("tfont", 28), bold = true },
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        TextWidget:new{ text = self.version or ("Versión " .. Conf.VERSION), face = Font:getFace("cfont", 18) },
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
        TextBoxWidget:new{
            text = self.descripcion,
            face = Font:getFace("cfont", 18),
            width = ancho,
            alignment = "center",
        },
    }
    -- espacio para la dirección de GitHub: aparece cuando Conf.GITHUB (o o.github) tiene algo
    local github = self.github or Conf.GITHUB
    if github and github ~= "" then
        contenido[#contenido + 1] = VerticalSpan:new{ width = Screen:scaleBySize(10) }
        contenido[#contenido + 1] = TextBoxWidget:new{
            text = "GitHub: " .. github,
            face = Font:getFace("cfont", 16),
            width = ancho,
            alignment = "center",
        }
    end
    contenido[#contenido + 1] = VerticalSpan:new{ width = Screen:scaleBySize(20) }
    for _, dato in ipairs(self.datos or {}) do
        contenido[#contenido + 1] = TextBoxWidget:new{
            text = dato[1] .. ": " .. dato[2],
            face = Font:getFace("x_smallinfofont"),
            width = ancho,
            alignment = "center",
        }
        contenido[#contenido + 1] = VerticalSpan:new{ width = Screen:scaleBySize(6) }
    end
    self[1] = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "center",
            barra,
            CenterContainer:new{
                dimen = Geom:new{ w = screen_w, h = screen_h - barra:getSize().h },
                contenido,
            },
        },
    }
end

function Acerca:onShow()
    UIManager:setDirty(self, "flashui")
    return true
end

function Acerca:onCloseWidget()
    UIManager:setDirty(nil, "flashui")
end

function Acerca:onClose()
    UIManager:close(self)
    return true
end

return Acerca
