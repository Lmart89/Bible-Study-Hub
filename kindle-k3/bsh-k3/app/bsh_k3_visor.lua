--[[--
Visor de HTML para el Kindle 3, base de todas las pantallas de lectura (Biblia, comentario,
diccionario, búsqueda, notas y favoritos). Teclas:

  * D-Pad: salta entre los enlaces de la página (versículos, citas, palabras, resultados, notas),
    en orden de lectura. Al pasar del último sigue en la página siguiente, y al revés.
  * Press: activa el enlace enfocado (Visor:activar).
  * Teclas laterales: página siguiente o anterior. En la última, Visor:alFinal decide (la Biblia
    pasa al capítulo siguiente).
  * Menu: el menú de la pantalla (Visor:menu). Back: Visor:onCerrar.

El foco es un sombreado gris pintado encima de la página ya dibujada: moverlo no vuelve a maquetar
ni a dibujar la página con MuPDF, y solo se refresca la zona que cambia. Los enlaces de cada página
se leen una vez por maquetación.

Las subclases ponen self.html y self.titulo antes de construir(), y pueden cambiar enfocable(uri).
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local datetime = require("datetime")
local Ajustes = require("bsh_ajustes_lectura")
local Input = Device.input
local Screen = Device.screen

local SOMBRA = 0.3 -- gris del foco (0 = nada, 1 = negro)

local Visor = InputContainer:extend{
    name = "bsh_k3_visor",
    covers_fullscreen = true,
    seccion_ajustes = "modulos", -- «biblia» o «modulos» (Ajustes.leer)
    css = "",
    titulo = "", -- en el recuadro de la barra: el libro y capítulo, o el módulo
}

function Visor:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Cerrar = { { Input.group.Back } }
        self.key_events.Menu = { { "Menu" } }
        self.key_events.PaginaSiguiente = { { Input.group.PgFwd } }
        self.key_events.PaginaAnterior = { { Input.group.PgBack } }
        self.key_events.FocoArriba = { { "Up" } }
        self.key_events.FocoAbajo = { { "Down" } }
        self.key_events.FocoIzquierda = { { "Left" } }
        self.key_events.FocoDerecha = { { "Right" } }
        self.key_events.Activar = { { "Press" } }
    end
    self.ajustes = Ajustes.leer(self.seccion_ajustes)
    self:iniciar()
    self:construir()
end

--- Para las subclases: prepara self.html y self.titulo.
function Visor:iniciar() end

local WIFI = "\u{F1EB}" -- símbolo de la fuente de iconos de KOReader (nerdfonts/symbols.ttf)

--- Hora, Wi-Fi y batería: { hora = "10:42", wifi = true si hay red, bateria = " 85%" o nil }.
function Visor.estado()
    local e = { hora = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) }
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    e.wifi = ok and NetworkMgr and NetworkMgr:isConnected() and true or false
    if Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        local nivel = powerd:getCapacity()
        local simbolo = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), nivel) or ""
        e.bateria = string.format("%s %d%%", simbolo, nivel)
    end
    return e
end

--- La hora, el Wi-Fi (negro si está conectado, gris si no) y la batería, en ese orden.
function Visor:grupoEstado()
    local e = Visor.estado()
    local cara = Font:getFace("smallinfofont")
    local separacion = HorizontalSpan:new{ width = 2 * Size.padding.default }
    local grupo = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = e.hora, face = cara, bold = true },
        separacion,
        TextWidget:new{ text = WIFI, face = cara, bold = true,
            fgcolor = e.wifi and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY },
    }
    if e.bateria then
        grupo[#grupo + 1] = separacion
        grupo[#grupo + 1] = TextWidget:new{ text = e.bateria, face = cara, bold = true }
    end
    self.texto_estado = e.hora .. "|" .. tostring(e.wifi) .. "|" .. (e.bateria or "")
    return grupo
end

--- Barra de arriba: el icono del menú (tecla Menu), el nombre del libro o del módulo en un
-- recuadro, y la hora, el Wi-Fi y la batería. Debajo, una línea gruesa.
function Visor:barra(screen_w)
    local relleno = Size.padding.large
    local tam = Screen:scaleBySize(32)
    local menu = IconWidget:new{ icon = "appbar.menu", width = tam, height = tam }
    -- ancho fijo, alineado a la derecha: cuando cambian la hora o la batería no se mueve nada más
    local grupo = self:grupoEstado()
    self.estado_widget = RightContainer:new{
        dimen = Geom:new{ w = grupo:getSize().w + Screen:scaleBySize(24), h = grupo:getSize().h },
        grupo,
    }
    local libre = screen_w - 4 * relleno - tam - self.estado_widget:getSize().w
    local titulo = TextWidget:new{ text = self.titulo or "", face = Font:getFace("cfont", 20), bold = true,
        max_width = libre - 2 * Size.padding.default - 2 * Size.border.button }
    local recuadro = FrameContainer:new{
        bordersize = Size.border.button, radius = Size.radius.button,
        padding = Size.padding.default, padding_top = Size.padding.small, padding_bottom = Size.padding.small,
        titulo,
    }
    local alto = math.max(recuadro:getSize().h, tam) + 2 * Size.padding.default
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = relleno },
            menu,
            HorizontalSpan:new{ width = relleno },
            CenterContainer:new{ dimen = Geom:new{ w = libre, h = alto }, recuadro },
            HorizontalSpan:new{ width = relleno },
            self.estado_widget,
            HorizontalSpan:new{ width = relleno },
        },
        LineWidget:new{ dimen = Geom:new{ w = screen_w, h = Size.line.thick * 2 } },
    }
end

--- Rehace la hora, el Wi-Fi y la batería si cambiaron y esta pantalla está arriba; refresca
-- solo esa esquina.
function Visor:actualizarEstado()
    if self.cerrado or not self.estado_widget or UIManager:getNthTopWidget() ~= self then return end
    local antes = self.texto_estado
    local grupo = self:grupoEstado()
    if self.texto_estado == antes then return end
    self.estado_widget[1] = grupo
    -- la zona va desde el borde derecho: el contenido nuevo puede ser más ancho que el anterior
    local d = self.estado_widget.dimen
    local ancho = d.w + 2 * Size.padding.large
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = Screen:getWidth() - ancho, y = d.y or 0, w = ancho, h = d.h }
    end)
end

--- Cada minuto, la hora, el Wi-Fi y la batería.
function Visor:programarEstado()
    self.reloj = self.reloj or function()
        if self.cerrado then return end
        self:actualizarEstado()
        UIManager:scheduleIn(60, self.reloj)
    end
    UIManager:unschedule(self.reloj)
    UIManager:scheduleIn(60, self.reloj)
end

-- KOReader avisa a todas las pantallas cuando la red se conecta o se desconecta
function Visor:onNetworkConnected() self:actualizarEstado() end
function Visor:onNetworkDisconnected() self:actualizarEstado() end

--- Arma la pantalla con self.html. pagina: la página que se muestra (si no, la primera).
function Visor:construir(pagina)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local lateral, superior, inferior = Ajustes.medidas(self.ajustes)
    local barra = self:barra(screen_w)
    self.alto_barra = barra:getSize().h
    local alto = screen_h - self.alto_barra - superior - inferior
    self.html_widget = ScrollHtmlWidget:new{
        html_body = self.html or "",
        css = self.css .. Ajustes.css(self.ajustes),
        default_font_size = Ajustes.letra(self.ajustes),
        width = screen_w - 2 * lateral,
        height = alto,
        dialog = self,
    }
    self.html_widget.key_events = {} -- las teclas de página las lleva el visor
    local caja = self.html_widget.htmlbox_widget
    local pintar = caja.paintTo
    caja.paintTo = function(c, bb, x, y)
        pintar(c, bb, x, y)
        self:pintarFoco(bb, x, y)
    end
    self.enlaces = {} -- por página
    self.foco = nil
    if pagina and pagina > 1 then self:irAPagina(pagina) end
    self[1] = FrameContainer:new{
        width = screen_w, height = screen_h,
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
        VerticalGroup:new{
            align = "center",
            barra,
            VerticalSpan:new{ width = superior },
            self.html_widget,
        },
    }
end

--- Vuelve a armar la pantalla (otro HTML, otros ajustes). Con conservar, sigue en la misma página.
function Visor:rehacer(conservar)
    local pagina = conservar and self.html_widget and self:pagina() or nil
    if self.html_widget then self.html_widget.htmlbox_widget:freeBb() end
    self:free()
    self:construir(pagina)
    UIManager:setDirty(self, "partial")
end

function Visor:pagina() return self.html_widget.htmlbox_widget.page_number end
function Visor:paginas() return self.html_widget.htmlbox_widget.page_count end

function Visor:irAPagina(n)
    local total = self:paginas()
    n = math.max(1, math.min(total, n))
    if n == self:pagina() then return end
    self.html_widget:scrollToRatio((n - 1) / total)
end

--- Enlaces --------------------------------------------------------------------------

--- ¿Se puede enfocar este enlace? Por defecto, todos.
function Visor:enfocable(uri) return uri ~= nil and uri ~= "" end

--- Enlaces de una página agrupados por dirección, en orden de lectura. Un enlace de varias líneas
-- (un versículo entero) es un grupo con un rectángulo por línea.
function Visor:enlacesPagina(n)
    n = n or self:pagina()
    if self.enlaces[n] then return self.enlaces[n] end
    local caja = self.html_widget.htmlbox_widget
    local lista = {}
    if caja.document then
        local page = caja.document:openPage(n)
        lista = page:getPageLinks() or {}
        page:close()
    end
    table.sort(lista, function(a, b)
        if a.y0 ~= b.y0 then return a.y0 < b.y0 end
        return a.x0 < b.x0
    end)
    local grupos, por_uri = {}, {}
    for _, l in ipairs(lista) do
        if self:enfocable(l.uri) then
            local g = por_uri[l.uri]
            if not g then
                g = { uri = l.uri, rects = {} }
                por_uri[l.uri] = g
                grupos[#grupos + 1] = g
            end
            g.rects[#g.rects + 1] = { x = l.x0, y = l.y0, w = l.x1 - l.x0, h = l.y1 - l.y0 }
        end
    end
    self.enlaces[n] = grupos
    return grupos
end

--- Primera página donde aparece una dirección, y su índice en ella.
function Visor:buscarEnlace(uri)
    for p = 1, self:paginas() do
        for i, g in ipairs(self:enlacesPagina(p)) do
            if g.uri == uri then return p, i end
        end
    end
end

function Visor:uriEnfocada()
    return self.foco and self.foco.uri
end

--- Zona de pantalla de un grupo, para refrescar solo eso.
function Visor:zonaDe(foco)
    if not foco then return nil end
    local caja = self.html_widget.htmlbox_widget
    local ox, oy = caja.dimen.x or 0, caja.dimen.y or 0
    local x0, y0, x1, y1
    for _, r in ipairs(foco.rects) do
        x0 = math.min(x0 or r.x, r.x)
        y0 = math.min(y0 or r.y, r.y)
        x1 = math.max(x1 or r.x + r.w, r.x + r.w)
        y1 = math.max(y1 or r.y + r.h, r.y + r.h)
    end
    if not x0 then return nil end
    return Geom:new{ x = ox + x0 - 4, y = oy + y0 - 2, w = x1 - x0 + 8, h = y1 - y0 + 4 }
end

function Visor:pintarFoco(bb, x, y)
    local f = self.foco
    if not f or f.pagina ~= self:pagina() then return end
    for _, r in ipairs(f.rects) do
        bb:darkenRect(x + r.x - 2, y + r.y, r.w + 4, r.h, SOMBRA)
    end
end

--- Enfoca el grupo i de la página actual (nil quita el foco) y refresca solo lo que cambió.
function Visor:enfocar(i)
    local antes = self.foco
    local grupo = i and self:enlacesPagina()[i]
    self.foco = grupo and { pagina = self:pagina(), indice = i, uri = grupo.uri, rects = grupo.rects } or nil
    local zona_antes = antes and antes.pagina == self:pagina() and self:zonaDe(antes)
    local zona = self:zonaDe(self.foco)
    if zona_antes and zona then
        zona = zona:combine(zona_antes)
    else
        zona = zona or zona_antes
    end
    if zona then UIManager:setDirty(self, function() return "ui", zona end) end
    self:alEnfocar(self.foco and self.foco.uri)
end

--- Para las subclases: el foco cambió (uri o nil).
function Visor:alEnfocar() end

--- Enfoca una dirección: va a su página si hace falta. Devuelve true si la encontró.
function Visor:enfocarUri(uri)
    local p, i = self:buscarEnlace(uri)
    if not p then return false end
    self.foco = nil
    self:irAPagina(p)
    self:enfocar(i)
    return true
end

--- Mueve el foco delta enlaces. Si se sale de la página, sigue en la de al lado.
function Visor:moverFoco(delta)
    local grupos = self:enlacesPagina()
    local actual = self.foco and self.foco.pagina == self:pagina() and self.foco.indice
    local i
    if actual then
        i = actual + delta
    else
        i = delta > 0 and 1 or #grupos
    end
    if i >= 1 and i <= #grupos then
        self:enfocar(i)
        return true
    end
    -- fuera de la página: la de al lado, con su primer (o último) enlace
    local anterior = self.foco and self.foco.uri
    local pagina = self:pagina()
    if (delta > 0 and pagina >= self:paginas()) or (delta < 0 and pagina <= 1) then
        if not actual and #grupos == 0 then self:alFinal(delta) end
        return true
    end
    self.foco = nil
    self.html_widget:scrollText(delta)
    grupos = self:enlacesPagina()
    if #grupos == 0 then return true end
    i = delta > 0 and 1 or #grupos
    -- un enlace que sigue desde la página anterior (un versículo partido) no cuenta como otro
    if grupos[i].uri == anterior and grupos[i + delta] then i = i + delta end
    self:enfocar(i)
    return true
end

--- Teclas laterales: página siguiente o anterior, sin foco. En el extremo, alFinal(delta).
function Visor:pasarPagina(delta)
    local pagina = self:pagina()
    if (delta > 0 and pagina >= self:paginas()) or (delta < 0 and pagina <= 1) then
        return self:alFinal(delta)
    end
    self.foco = nil
    self.html_widget:scrollText(delta)
    self:alEnfocar(nil)
end

--- Para las subclases: se intentó pasar de la última (o de la primera) página.
function Visor:alFinal() end

--- Para las subclases: Press sobre un enlace (uri), o sin foco (uri nil).
function Visor:activar() end

--- Para las subclases: la tecla Menu.
function Visor:menu() end

--- Filas de enlaces de una página: los enlaces cuyo primer renglón empieza a la misma altura.
local function filasDe(grupos)
    local filas = {}
    for i, g in ipairs(grupos) do
        local r = g.rects[1]
        local fila = filas[#filas]
        if fila and math.abs(r.y - fila.y) <= r.h / 2 then
            fila[#fila + 1] = i
        else
            filas[#filas + 1] = { y = r.y, i }
        end
    end
    return filas
end

local function centroX(g) return g.rects[1].x + g.rects[1].w / 2 end

--- Rejilla (self.rejilla): sube o baja una fila y enfoca el enlace más cercano en horizontal.
-- Pasada la última fila sigue en la página siguiente, y antes de la primera, en la anterior.
function Visor:moverFila(delta)
    local grupos = self:enlacesPagina()
    local actual = self.foco and self.foco.pagina == self:pagina() and self.foco.indice
    if not actual then return self:moverFoco(delta) end
    local filas = filasDe(grupos)
    local fila_actual
    for f, fila in ipairs(filas) do
        for _, i in ipairs(fila) do
            if i == actual then fila_actual = f end
        end
    end
    local x = centroX(grupos[actual])
    local destino = filas[fila_actual + delta]
    if not destino then
        local pagina = self:pagina()
        if (delta > 0 and pagina >= self:paginas()) or (delta < 0 and pagina <= 1) then return true end
        self.foco = nil
        self.html_widget:scrollText(delta)
        grupos = self:enlacesPagina()
        filas = filasDe(grupos)
        destino = delta > 0 and filas[1] or filas[#filas]
        if not destino then return true end
    end
    local mejor, distancia
    for _, i in ipairs(destino) do
        local d = math.abs(centroX(grupos[i]) - x)
        if not distancia or d < distancia then mejor, distancia = i, d end
    end
    self:enfocar(mejor)
    return true
end

function Visor:onFocoArriba()
    if self.rejilla then return self:moverFila(-1) end
    return self:moverFoco(-1)
end

function Visor:onFocoAbajo()
    if self.rejilla then return self:moverFila(1) end
    return self:moverFoco(1)
end
function Visor:onFocoIzquierda() return self:moverFoco(-1) end
function Visor:onFocoDerecha() return self:moverFoco(1) end
function Visor:onPaginaSiguiente() self:pasarPagina(1) return true end
function Visor:onPaginaAnterior() self:pasarPagina(-1) return true end
function Visor:onActivar() self:activar(self:uriEnfocada()) return true end
function Visor:onMenu() self:menu() return true end

function Visor:onCerrar()
    UIManager:close(self)
    return true
end

function Visor:onShow()
    UIManager:setDirty(self, "flashui")
    self:programarEstado()
    return true
end

function Visor:onCloseWidget()
    self.cerrado = true
    if self.reloj then UIManager:unschedule(self.reloj) end
    if self.html_widget then self.html_widget.htmlbox_widget:freeBb() end
    UIManager:setDirty(nil, "flashui")
end

return Visor
