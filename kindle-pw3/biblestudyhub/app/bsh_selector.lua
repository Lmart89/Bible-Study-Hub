--[[--
Selector de referencia en tres pasos: libro → capítulo → versículo.

No hay listas desplegables en KOReader: cada paso es una cuadrícula de botones a pantalla
completa (más cómodo de tocar en tinta electrónica). Capítulos y versículos se paginan
(Salmos tiene 150 capítulos; Salmos 119, 176 versículos).

    Selector:new{ db = db, libro = 43, cap = 3, al_elegir = function(libro, cap, verso) end }
    verso es nil si se elige «Solo el capítulo».

    Selector:new{ solo_libro = true, titulo = "Buscar desde…", libro_min = 40, al_elegir = function(libro) end }
    solo elige el libro (para el tramo de la búsqueda); los anteriores a libro_min salen apagados.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Libros = require("bsh_libros")
local Input = Device.input
local Screen = Device.screen

local COLUMNAS = 6
local POR_PAGINA = 60 -- 10 filas de 6

local Selector = InputContainer:extend{
    name = "bsh_selector",
    covers_fullscreen = true,
    db = nil,
    libro = nil, cap = nil,
    al_elegir = nil,
    solo_libro = false, -- termina al elegir el libro: al_elegir(libro)
    titulo = nil,       -- título del paso del libro (por defecto «Elegir libro»)
    libro_min = 1,      -- con solo_libro: primer libro que se puede elegir
}

function Selector:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    self.paso = "libro"
    self.pagina = 1
    self:buildLayout()
end

--- Filas de botones a partir de una lista { {text, callback}, ... } (rellena la última fila).
local function cuadricula(items)
    local filas, fila = {}, {}
    for _, it in ipairs(items) do
        fila[#fila + 1] = it
        if #fila == COLUMNAS then
            filas[#filas + 1] = fila
            fila = {}
        end
    end
    if #fila > 0 then
        while #fila < COLUMNAS do fila[#fila + 1] = { text = "", enabled = false } end
        filas[#filas + 1] = fila
    end
    return filas
end

function Selector:botonesLibros(desde, hasta)
    local items = {}
    for n = desde, hasta do
        items[#items + 1] = { text = Libros.abreviatura(n), enabled = n >= (self.libro_min or 1), callback = function()
            if self.solo_libro then
                UIManager:close(self)
                if self.al_elegir then self.al_elegir(n) end
                return
            end
            self.libro = n
            self.paso, self.pagina = "capitulo", 1
            self:refresh()
        end }
    end
    return cuadricula(items)
end

--- Números 1..total de la página actual, cada uno con su callback.
function Selector:botonesNumeros(total, al_tocar)
    local items = {}
    local desde = (self.pagina - 1) * POR_PAGINA + 1
    for n = desde, math.min(total, desde + POR_PAGINA - 1) do
        items[#items + 1] = { text = tostring(n), callback = function() al_tocar(n) end }
    end
    return cuadricula(items)
end

function Selector:buildLayout()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margen = Size.padding.large
    local ancho = screen_w - 2 * margen
    local titulo, contenido = nil, VerticalGroup:new{ align = "center" }
    local cara = Font:getFace("smalltfont")

    local function seccion(texto, filas)
        contenido[#contenido + 1] = TextWidget:new{ text = texto, face = cara, max_width = ancho }
        contenido[#contenido + 1] = VerticalSpan:new{ width = Size.padding.default }
        contenido[#contenido + 1] = ButtonTable:new{ width = ancho, show_parent = self, buttons = filas }
        contenido[#contenido + 1] = VerticalSpan:new{ width = margen }
    end

    local total, paginas = 0, 1
    if self.paso == "libro" then
        titulo = self.titulo or "Elegir libro"
        seccion("Antiguo Testamento", self:botonesLibros(1, Libros.ULTIMO_AT))
        seccion("Nuevo Testamento", self:botonesLibros(Libros.ULTIMO_AT + 1, Libros.total))
    elseif self.paso == "capitulo" then
        total = self.db:capitulos(self.libro)
        titulo = Libros.nombre(self.libro) .. " · capítulo"
        seccion(string.format("%d capítulos", total), self:botonesNumeros(total, function(n)
            self.cap = n
            self.paso, self.pagina = "verso", 1
            self:refresh()
        end))
    else
        total = self.db:versiculos(self.libro, self.cap)
        titulo = string.format("%s %d · versículo", Libros.nombre(self.libro), self.cap)
        seccion(string.format("%d versículos", total), self:botonesNumeros(total, function(n)
            self:elegir(n)
        end))
    end
    paginas = math.max(1, math.ceil(total / POR_PAGINA))

    -- fila inferior: páginas y, en el paso del versículo, «Solo el capítulo»
    local fila = {}
    if paginas > 1 then
        fila[#fila + 1] = { text = "◀", enabled = self.pagina > 1, callback = function()
            self.pagina = self.pagina - 1
            self:refresh()
        end }
        fila[#fila + 1] = { text = string.format("%d / %d", self.pagina, paginas), enabled = false }
        fila[#fila + 1] = { text = "▶", enabled = self.pagina < paginas, callback = function()
            self.pagina = self.pagina + 1
            self:refresh()
        end }
    end
    if self.paso == "verso" then
        fila[#fila + 1] = { text = "Solo el capítulo", callback = function() self:elegir(nil) end }
    end
    if #fila > 0 then
        contenido[#contenido + 1] = ButtonTable:new{ width = ancho, show_parent = self, buttons = { fila } }
    end

    local title_bar = TitleBar:new{
        width = screen_w,
        fullscreen = true,
        title = titulo,
        with_bottom_line = true,
        left_icon = self.paso ~= "libro" and "chevron.left" or nil,
        left_icon_tap_callback = function() self:atras() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self[1] = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = screen_w },
            title_bar,
            VerticalSpan:new{ width = margen },
            contenido,
        },
    }
end

function Selector:refresh()
    self:free()
    self:buildLayout()
    UIManager:setDirty(self, "ui")
end

function Selector:atras()
    self.paso = self.paso == "verso" and "capitulo" or "libro"
    self.pagina = 1
    self:refresh()
end

function Selector:elegir(verso)
    UIManager:close(self)
    if self.al_elegir then self.al_elegir(self.libro, self.cap, verso) end
end

function Selector:onShow()
    UIManager:setDirty(self, "flashui")
    return true
end

function Selector:onCloseWidget()
    UIManager:setDirty(nil, "flashui")
end

function Selector:onClose()
    UIManager:close(self)
    return true
end

return Selector
