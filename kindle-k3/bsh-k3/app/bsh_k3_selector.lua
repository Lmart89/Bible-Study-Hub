--[[--
Selector de pasaje para el Kindle 3: libro → capítulo → versículo.

Cada paso es una sola tabla de botones (un solo foco), que empieza en el libro o capítulo que se
lee. D-Pad: mover; Press: elegir. Teclas laterales: otra página de capítulos o versículos (Salmos
tiene 150; Salmos 119, 176). Back: el paso anterior o, en el de libros, cerrar.

    Selector:new{ db = db, libro = 43, cap = 3, al_elegir = function(libro, cap, verso) end }
    verso es nil con «Solo el capítulo».

    Selector:new{ solo_libro = true, titulo = "Buscar desde el libro…", libro_min = 45,
        al_elegir = function(libro) end, al_cancelar = function() end }
    solo elige el libro (el tramo de la búsqueda); los anteriores a libro_min no se pueden elegir.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Libros = require("bsh_libros")
local Input = Device.input
local Screen = Device.screen

local COLUMNAS = 6
local POR_PAGINA = 60 -- 10 filas de 6

local Selector = InputContainer:extend{
    name = "bsh_k3_selector",
    covers_fullscreen = true,
    db = nil,
    libro = nil, cap = nil,
    al_elegir = nil,
    solo_libro = false, -- termina al elegir el libro: al_elegir(libro)
    titulo = nil,       -- título del paso del libro (por defecto «Elegir libro»)
    libro_min = 1,      -- con solo_libro: el primer libro que se puede elegir
    al_cancelar = nil,  -- function(): Back en el paso del libro
}

function Selector:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Atras = { { Input.group.Back } }
        self.key_events.PaginaSiguiente = { { Input.group.PgFwd } }
        self.key_events.PaginaAnterior = { { Input.group.PgBack } }
    end
    self.paso = "libro"
    self.pagina = 1
    self.libro = self.libro or self.libro_min or 1
    self:construir()
end

--- Filas de COLUMNAS botones. Devuelve también la fila y columna del elemento «actual».
local function cuadricula(items, actual)
    local filas, fila = {}, {}
    local fx, fy
    for i, it in ipairs(items) do
        fila[#fila + 1] = it
        if i == actual then fx, fy = #fila, #filas + 1 end
        if #fila == COLUMNAS then
            filas[#filas + 1] = fila
            fila = {}
        end
    end
    if #fila > 0 then filas[#filas + 1] = fila end
    return filas, fx, fy
end

--- Libros: el Antiguo Testamento y, desde una fila nueva, el Nuevo.
function Selector:filasLibros()
    local function items(desde, hasta)
        local t = {}
        for n = desde, hasta do
            t[#t + 1] = { text = Libros.abreviatura(n), enabled = n >= (self.libro_min or 1), callback = function()
                if self.solo_libro then
                    UIManager:close(self)
                    if self.al_elegir then self.al_elegir(n) end
                    return
                end
                self.libro = n
                self.paso, self.pagina = "capitulo", 1
                self:rehacer()
            end }
        end
        return t
    end
    local at, ax, ay = cuadricula(items(1, Libros.ULTIMO_AT), self.libro)
    local nt, nx, ny = cuadricula(items(Libros.ULTIMO_AT + 1, Libros.total), self.libro - Libros.ULTIMO_AT)
    for _, f in ipairs(nt) do at[#at + 1] = f end
    if self.libro > Libros.ULTIMO_AT then ax, ay = nx, ny and (ny + math.ceil(Libros.ULTIMO_AT / COLUMNAS)) end
    return at, ax, ay
end

--- Números de la página actual. actual: el número que queda enfocado si está en ella.
function Selector:filasNumeros(total, actual, al_elegir)
    local items = {}
    local desde = (self.pagina - 1) * POR_PAGINA + 1
    for n = desde, math.min(total, desde + POR_PAGINA - 1) do
        items[#items + 1] = { text = tostring(n), callback = function() al_elegir(n) end }
    end
    return cuadricula(items, actual and (actual - desde + 1))
end

function Selector:construir()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margen = Size.padding.large
    local ancho = screen_w - 2 * margen
    local titulo, nota, filas, fx, fy
    self.total = 0
    if self.paso == "libro" then
        titulo = self.titulo or "Elegir libro"
        nota = "Antiguo Testamento arriba · Nuevo Testamento abajo"
        filas, fx, fy = self:filasLibros()
    elseif self.paso == "capitulo" then
        self.total = self.db:capitulos(self.libro)
        titulo = Libros.nombre(self.libro) .. " · capítulo"
        filas, fx, fy = self:filasNumeros(self.total, self.cap, function(n)
            self.cap = n
            self.paso, self.pagina = "verso", 1
            self:rehacer()
        end)
    else
        self.total = self.db:versiculos(self.libro, self.cap)
        titulo = string.format("%s %d · versículo", Libros.nombre(self.libro), self.cap)
        filas, fx, fy = self:filasNumeros(self.total, nil, function(n) self:elegir(n) end)
        filas[#filas + 1] = { { text = "Solo el capítulo", callback = function() self:elegir(nil) end } }
    end
    self.paginas = math.max(1, math.ceil(self.total / POR_PAGINA))
    if self.paso ~= "libro" then
        nota = string.format("%d en total", self.total)
        if self.paginas > 1 then
            nota = nota .. string.format(" · página %d de %d (teclas laterales)", self.pagina, self.paginas)
        end
    end
    local tabla = ButtonTable:new{ width = ancho, show_parent = self, buttons = filas }
    if fx and fy then tabla:moveFocusTo(fx, fy) end
    local cara = Font:getFace("x_smallinfofont")
    self[1] = FrameContainer:new{
        width = screen_w, height = screen_h,
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = margen, margin = 0,
        VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = titulo, face = Font:getFace("cfont", 20), bold = true, max_width = ancho },
            TextWidget:new{ text = nota .. " · Back: atrás", face = cara, fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = ancho },
            VerticalSpan:new{ width = Size.padding.default },
            LineWidget:new{ dimen = Geom:new{ w = ancho, h = Size.line.thick * 2 } },
            VerticalSpan:new{ width = margen },
            tabla,
        },
    }
end

function Selector:rehacer()
    self:free()
    self:construir()
    UIManager:setDirty(self, "partial")
end

function Selector:onPaginaSiguiente()
    if self.pagina < (self.paginas or 1) then
        self.pagina = self.pagina + 1
        self:rehacer()
    end
    return true
end

function Selector:onPaginaAnterior()
    if self.pagina > 1 then
        self.pagina = self.pagina - 1
        self:rehacer()
    end
    return true
end

function Selector:onAtras()
    if self.paso == "libro" then
        UIManager:close(self)
        if self.al_cancelar then self.al_cancelar() end
        return true
    end
    self.paso = self.paso == "verso" and "capitulo" or "libro"
    -- vuelve a la página del número que se había elegido
    self.pagina = self.paso == "capitulo" and math.ceil(self.cap / POR_PAGINA) or 1
    self:rehacer()
    return true
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

return Selector
