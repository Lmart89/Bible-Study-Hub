--[[--
Pantalla de carga (alfa 10): logo, nombre de la app y barra de progreso mientras el registro
revisa los módulos. Cada paso es un módulo; entre paso y paso se cede el control (scheduleIn)
para que UIManager dibuje la barra: Lua hace una sola cosa a la vez. Solo se refresca la zona de
la barra, sin parpadeos de pantalla completa.

La carga real dura menos de un segundo; por decisión de diseño la pantalla dura DURACION segundos
para que se vea el logo. Los pasos se reparten en ese tiempo y la barra avanza de forma pareja.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local time = require("ui/time")
local Registro = require("bsh_registro")
local Screen = Device.screen

local DURACION = 3 -- segundos que se muestra la pantalla (si la carga tarda más, lo que tarde)

local Carga = InputContainer:extend{
    name = "bsh_carga",
    covers_fullscreen = true,
    plugin_path = nil,
    al_terminar = nil, -- function(): abre el lector
}

function Carga:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    local ancho = math.floor(screen_w * 0.7)
    local logo = Screen:scaleBySize(170)
    self.barra = ProgressWidget:new{
        width = ancho,
        height = Screen:scaleBySize(14),
        percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK,
    }
    self.texto = TextWidget:new{
        text = "Verificando recursos…",
        face = Font:getFace("cfont", 18),
        max_width = ancho,
    }
    -- FrameContainer: al pintarse guarda su posición, que es la zona que se refresca
    self.zona = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        VerticalGroup:new{
            align = "center",
            self.barra,
            VerticalSpan:new{ width = Screen:scaleBySize(12) },
            CenterContainer:new{ dimen = Geom:new{ w = ancho, h = self.texto:getSize().h }, self.texto },
        },
    }
    self[1] = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            VerticalGroup:new{
                align = "center",
                IconWidget:new{ file = self.plugin_path .. "/iconos/logo.svg", width = logo, height = logo },
                VerticalSpan:new{ width = Screen:scaleBySize(16) },
                TextWidget:new{ text = "Bible Study Hub", face = Font:getFace("tfont", 30), bold = true },
                VerticalSpan:new{ width = Screen:scaleBySize(48) },
                self.zona,
            },
        },
    }
end

function Carga:mostrar(hechos, total, texto)
    self.barra:setPercentage(total > 0 and hechos / total or 1)
    self.texto:setText(texto)
    UIManager:setDirty(self, function() return "ui", self.zona.dimen or self.dimen end)
end

function Carga:siguiente()
    local paso = self.pasos[self.i + 1]
    if not paso then return self:terminar() end
    self:mostrar(self.i, #self.pasos, paso.texto)
    UIManager:scheduleIn(self:espera(self.i / #self.pasos), function()
        local inicio = time.now()
        local ok, err = pcall(paso.ejecutar)
        if not ok then logger.warn("[BSH] falló el paso", paso.texto, err) end
        self.trabajo = self.trabajo + time.since(inicio)
        self.i = self.i + 1
        self:siguiente()
    end)
end

--- Segundos que faltan para llegar a esa fracción de DURACION (nunca 0: así UIManager dibuja antes).
function Carga:espera(fraccion)
    return math.max(0.01, DURACION * fraccion - time.to_s(time.since(self.inicio)))
end

function Carga:terminar()
    logger.info("[BSH] carga:", #self.pasos, "pasos en", time.to_ms(self.trabajo), "ms de trabajo")
    self:mostrar(1, 1, "Abriendo la Biblia…")
    UIManager:scheduleIn(self:espera(1), function()
        if self.al_terminar then self.al_terminar() end
        UIManager:close(self)
    end)
end

function Carga:onShow()
    UIManager:setDirty(self, "flashui")
    UIManager:tickAfterNext(function()
        self.inicio = time.now()
        self.trabajo = 0
        self.i = 0
        self.pasos = Registro.pasos(self.plugin_path)
        self:siguiente()
    end)
    return true
end

return Carga
