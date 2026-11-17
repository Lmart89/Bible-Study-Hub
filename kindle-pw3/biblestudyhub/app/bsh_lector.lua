--[[--
Pantalla del lector (alfa 3, ampliada en la alfa 4). Diseño de docs/PLAN_V3_ESTUDIO_BIBLICO.md §5:

  Barra superior:  ☰  ·  «Juan 3 ▾»  ·  hora · Wi-Fi · batería (como Bible Study Hub for K3)
  Texto:           el capítulo en ScrollHtmlWidget; se pasa de página deslizando
  Final:           ‹ capítulo anterior · Ir arriba · capítulo siguiente ›  (enlaces del HTML)

Tocar un versículo solo lo resalta (uno a la vez); tocarlo otra vez, tocar fuera o cambiar de
capítulo quita el resaltado. El panel lateral (☰) muestra cuántas entradas hay de cada módulo para
el versículo resaltado (o el capítulo), la búsqueda, guardar en favoritos, los ajustes de lectura,
fuentes y selección, y los ajustes avanzados (bsh_ajustes_avanzados.lua).

Los paneles (lateral) son capas dentro de esta misma pantalla, no ventanas aparte:
UIManager solo entrega los toques a la ventana superior.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local datetime = require("datetime")
local logger = require("logger")
local time = require("ui/time")
local Ajustes = require("bsh_ajustes_lectura")
local Comentarios = require("bsh_comentario")
local Conf = require("bsh_conf")
local DB = require("bsh_db")
local Diccionarios = require("bsh_diccionario")
local Favoritos = require("bsh_favoritos")
local Libros = require("bsh_libros")
local Notas = require("bsh_notas")
local Registro = require("bsh_registro")
local Selector = require("bsh_selector")
local UI = require("bsh_ui")
local Usuario = require("bsh_usuario")
local _ = require("gettext")
local BotonIcono = UI.BotonIcono
local FilaMenu = UI.FilaMenu
local Input = Device.input
local Screen = Device.screen

-- Iconos del panel lateral: símbolos de la fuente de iconos de KOReader (nerdfonts/symbols.ttf),
-- los mismos de BSH - K3.
local ICONOS = {
    biblia = "\u{F02D}", comentario = "\u{F075}", diccionario = "\u{F1AB}", notas = "\u{F249}",
    favoritos = "\u{F02E}", buscar = "\u{F002}", copiar = "\u{F0C5}", lectura = "\u{F036}",
    letra = "\u{F031}", toque = "\u{F25A}", estrella = "\u{F005}", estrella_vacia = "\u{F006}",
    engranaje = "\u{F013}", salir = "\u{F011}",
}
local WIFI = "\u{F1EB}" -- en la barra, entre la hora y la batería

local POR_PAGINA = 20
-- Dónde y cómo buscar (Libros.GRUPOS, DB.MODOS); se recuerda entre sesiones.
local AJUSTE_BUSQUEDA = "bsh_busqueda"

-- el interlineado y la alineación los añade Ajustes.css() al final
local CSS = [[
@page { margin: 0; } /* MuPDF pone un margen de página por defecto que dejaba blanco alrededor */
body { margin: 0; line-height: 1.45; text-align: justify; }
h2 { font-size: 1.1em; margin: 0 0 0.5em 0; text-align: left; }
p { margin: 0 0 0.5em 0; }
a { color: black; text-decoration: none; }
a b, a.v { font-weight: bold; text-decoration: underline; }
p.sel { background-color: #cccccc; }
p.finp { margin-bottom: 1em; }
span.mn { font-size: 0.75em; }
p.nav { text-align: center; margin-top: 1.2em; padding-top: 0.5em; border-top: 1px solid black; }
p.nav a { text-decoration: underline; }
p.mas { text-align: center; margin-top: 0.8em; }
p.cab { text-align: left; margin-bottom: 0.3em; }
p.libros { text-align: left; font-size: 0.85em; margin: 0.4em 0 0.8em 0; padding-bottom: 0.4em; border-bottom: 1px solid black; }
p.libros a { text-decoration: underline; }
]]

--- Aviso breve. Sin fuente, Notification lo trata como SOURCE_OTHER, que KOReader oculta
-- con los ajustes por defecto: se marca como «mostrar siempre».
local function avisar(texto)
    Notification:notify(texto, Notification.SOURCE_ALWAYS_SHOW)
end

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- Pantalla -------------------------------------------------------------------------

local Pantalla = InputContainer:extend{
    name = "bsh_lector",
    covers_fullscreen = true,
    plugin_path = nil,
    al_reiniciar = nil, -- function(): vuelve a abrir la app desde la pantalla de carga
    actualizar = nil,   -- bsh_actualizar, en la app independiente: actualizaciones por Wi-Fi en Ajustes
    dispositivo = nil,  -- bsh_dispositivo, en la app independiente: red, pantalla y reposo en Ajustes
}

function Pantalla:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    if Device:isTouchDevice() then
        -- Solo llegan aquí los toques que nadie consumió: fuera de un versículo
        self.ges_events.TapFuera = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        }
        -- ScrollHtmlWidget solo pasa página con deslizamientos verticales y deja
        -- subir los horizontales: aquí se convierten en página siguiente/anterior.
        self.ges_events.Deslizar = {
            GestureRange:new{ ges = "swipe", range = function() return self.dimen end },
        }
    end

    local pos = G_reader_settings:readSetting("bsh_pos") or { 43, 3 }
    self.libro, self.cap = pos[1], pos[2]
    -- { rango = id de Libros.GRUPOS, desde, hasta (con «Elegir libros…»), modo = id de DB.MODOS }
    self.busqueda = G_reader_settings:readSetting(AJUSTE_BUSQUEDA) or { rango = "toda", modo = "todas" }
    self.toque_completo = G_reader_settings:nilOrTrue("bsh_toque_completo")
    self.tiempos = G_reader_settings:isTrue("bsh_tiempos")
    self.ajustes = Ajustes.leer("biblia") -- letra, márgenes, interlineado y alineación
    self.panel_abierto = false
    self.conteos_modulos = {} -- comentarios y diccionario por pasaje ya consultado
    self.n_conteos = 0
    self.estado1, self.estado2 = "", ""

    self.usuario = Usuario.abrir()
    self.ruta_db = Registro.rutaBiblia(self.plugin_path)
    local db, err
    if self.ruta_db then
        db, err = DB.abrir(self.ruta_db)
    else
        err = "No hay ninguna Biblia .ebb válida en esta carpeta. Cámbiala con el engranaje."
    end
    if not db then
        self.html = "<h2>No se pudo abrir la Biblia</h2><p>" .. escapar(self.ruta_db or Conf.carpetaModulos(self.plugin_path))
            .. "</p><p>" .. escapar(err) .. "</p>"
        self.tiempos = true
        self.estado1 = "Copia la Biblia convertida (.ebb) en la carpeta de módulos"
    else
        self.db = db
        local d = db:diagnostico()
        self.sqlite = d.sqlite
        self.estado1 = string.format("SQLite %s · %d versículos · FTS5 «dios»: %s (%d ms)",
            d.sqlite, d.versos, tostring(d.fts5), d.ms_fts)
        self:cargarCapitulo(self.libro, self.cap)
    end
    self:buildLayout()
end

--- Contenido -------------------------------------------------------------------

--- Lee un capítulo. Con verso_sel lo deja resaltado; con ir_al_verso además se desplaza hasta él.
function Pantalla:cargarCapitulo(libro, cap, verso_sel, ir_al_verso)
    local max_cap = self.db:capitulos(libro)
    if max_cap == 0 then return end
    cap = math.max(1, math.min(cap, max_cap))
    self.libro, self.cap = libro, cap
    self.modo = "capitulo"
    local versos, ms = self.db:capitulo(libro, cap)
    self.versos = versos
    self.con_nota = self.usuario and self.usuario:versosConNota(libro, cap) or {}
    self.verso_sel = verso_sel
    self.ir_a_verso = ir_al_verso and verso_sel or nil
    self.estado2 = string.format("Capítulo leído de SQLite en %d ms", ms)
    self:htmlCapitulo()
end

--- Capítulo anterior / siguiente (cruza de libro). Devuelve libro, cap.
function Pantalla:capituloVecino(delta)
    local libro, cap = self.libro, self.cap + delta
    if cap < 1 then
        libro = libro > 1 and libro - 1 or Libros.total
        cap = self.db:capitulos(libro)
    elseif cap > self.db:capitulos(libro) then
        libro = libro < Libros.total and libro + 1 or 1
        cap = 1
    end
    return libro, cap
end

--- Rehace el HTML del capítulo ya leído (p. ej. al cambiar el resaltado), sin volver a consultar.
function Pantalla:htmlCapitulo()
    local libro, cap = self.libro, self.cap
    local html = { "<h2>" .. escapar(Libros.nombre(libro)) .. " " .. cap .. "</h2>" }
    for _, fila in ipairs(self.versos) do
        local v = fila[1]
        -- con la Biblia convertida de theWord, el versículo ya viene en HTML (cursivas,
        -- saltos de línea de la poesía, palabras de Jesús); si no, se escapa el texto plano
        local cuerpo = fila[3] or escapar(fila[2])
        local href = string.format("verso://%d-%d-%d", libro, cap, v)
        local clases = {}
        if v == self.verso_sel then clases[#clases + 1] = "sel" end
        if fila[4] == 1 then clases[#clases + 1] = "finp" end
        local clase = #clases > 0 and (' class="' .. table.concat(clases, " ") .. '"') or ""
        -- ▪ junto al número: el versículo tiene al menos una nota
        local marca = (self.con_nota and self.con_nota[v]) and ' <span class="mn">▪</span>' or ""
        if self.toque_completo then
            html[#html + 1] = string.format('<p%s><a href="%s"><b>%d</b>%s %s</a></p>', clase, href, v, marca, cuerpo)
        else
            html[#html + 1] = string.format('<p%s><a class="v" href="%s">%d</a>%s %s</p>', clase, href, v, marca, cuerpo)
        end
    end
    -- navegación al final del capítulo (en lugar de una barra inferior)
    local la, ca = self:capituloVecino(-1)
    local ls, cs = self:capituloVecino(1)
    html[#html + 1] = string.format(
        '<p class="nav"><a href="verso://anterior">‹ %s %d</a> &#160;·&#160; <a href="verso://arriba">Ir arriba</a> &#160;·&#160; <a href="verso://siguiente">%s %d ›</a></p>',
        escapar(Libros.abreviatura(la)), ca, escapar(Libros.abreviatura(ls)), cs)
    self.html = table.concat(html, "\n")
end

function Pantalla:rangoActual()
    local b = self.busqueda
    return Libros.rango(b.rango, self.libro, b.desde, b.hasta)
end

function Pantalla:guardarBusqueda()
    G_reader_settings:saveSetting(AJUSTE_BUSQUEDA, self.busqueda)
end

function Pantalla:buscar(texto, pagina)
    local nombre_rango, desde, hasta = self:rangoActual()
    local modo = DB.modo(self.busqueda.modo)
    local filas, total, ms, err, por_libro = self.db:buscar(texto, desde, hasta, pagina, POR_PAGINA, modo.id)
    if not filas and err then
        UIManager:show(InfoMessage:new{ text = "Error en la búsqueda:\n" .. err
            .. (modo.id == "avanzada" and "\n\nRevisa la sintaxis o usa otro modo de búsqueda." or "") })
        return false
    end
    filas = filas or {}
    self.modo, self.consulta, self.pagina, self.total = "busqueda", texto, pagina, total
    self.verso_sel = nil
    local paginas = math.max(1, math.ceil(total / POR_PAGINA))
    local sep = " &#160;·&#160; "
    local html = {
        string.format("<h2>«%s» · %d %s</h2>", escapar(texto), total, total == 1 and "resultado" or "resultados"),
        '<p class="cab"><a class="v" href="verso://rango">Dónde: ' .. escapar(nombre_rango) .. '</a>' .. sep
            .. '<a class="v" href="verso://modo">Cómo: ' .. escapar(modo.nombre) .. '</a></p>',
        string.format('<p class="cab">Pág. %d/%d%s<a class="v" href="verso://nueva">Nueva búsqueda</a>%s<a class="v" href="verso://volver">Volver a %s %d</a></p>',
            pagina, paginas, sep, sep, escapar(Libros.abreviatura(self.libro)), self.cap),
    }
    -- en la primera página, cuántos hay en cada libro: tocar uno busca solo en ese libro
    if pagina == 1 and por_libro and #por_libro > 1 then
        local libros = {}
        for _, f in ipairs(por_libro) do
            libros[#libros + 1] = string.format('<a href="verso://libro-%d">%s</a>&#160;%d',
                f[1], escapar(Libros.abreviatura(f[1])), f[2])
        end
        html[#html + 1] = '<p class="libros">Por libro: ' .. table.concat(libros, " · ") .. "</p>"
    end
    if pagina > 1 then
        html[#html + 1] = '<p class="mas"><a class="v" href="verso://menos">← Resultados anteriores</a></p>'
    end
    for _, f in ipairs(filas) do
        local extracto = escapar(f[4]):gsub("\1", "<b>"):gsub("\2", "</b>")
        html[#html + 1] = string.format('<p><a class="v" href="verso://%d-%d-%d">%s %d:%d</a> %s</p>',
            f[1], f[2], f[3], escapar(Libros.nombre(f[1])), f[2], f[3], extracto)
    end
    if total == 0 then
        html[#html + 1] = "<p>Sin resultados.</p>"
    end
    if pagina < paginas then
        html[#html + 1] = '<p class="mas"><a class="v" href="verso://mas">Más resultados →</a></p>'
    end
    self.html = table.concat(html, "\n")
    self.estado2 = string.format("Búsqueda FTS5 en %d ms (conteo + página de %d)", ms, POR_PAGINA)
    return true
end

--- Interfaz --------------------------------------------------------------------

--- Hora, Wi-Fi y batería: { hora = "10:42", wifi = true si hay red, bateria = " 85%" o nil }.
function Pantalla.estado()
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
function Pantalla:grupoEstado()
    local e = Pantalla.estado()
    local cara = Font:getFace("infofont")
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

--- Rehace la hora, el Wi-Fi y la batería si cambiaron. Si el lector está arriba, refresca solo
-- esa esquina; si no, queda listo para cuando vuelva a dibujarse.
function Pantalla:actualizarEstado()
    if self.cerrado or not self.estado_widget then return end
    local antes = self.texto_estado
    local grupo = self:grupoEstado()
    if self.texto_estado == antes then return end
    self.estado_widget[1] = grupo
    if UIManager:getNthTopWidget() ~= self then return end
    -- la zona va desde el borde derecho: el contenido nuevo puede ser más ancho que el anterior
    local d = self.estado_widget.dimen
    local ancho = d.w + 2 * Size.padding.large
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = Screen:getWidth() - ancho, y = d.y or 0, w = ancho, h = d.h }
    end)
end

--- Cada minuto, la hora, el Wi-Fi y la batería.
function Pantalla:programarEstado()
    self.reloj = self.reloj or function()
        if self.cerrado then return end
        self:actualizarEstado()
        UIManager:scheduleIn(60, self.reloj)
    end
    UIManager:unschedule(self.reloj)
    UIManager:scheduleIn(60, self.reloj)
end

-- KOReader avisa a todas las pantallas cuando la red cambia y al despertar el Kindle
function Pantalla:onNetworkConnected() self:actualizarEstado() end
function Pantalla:onNetworkDisconnected() self:actualizarEstado() end
function Pantalla:onResume()
    if self.dispositivo then self.dispositivo.alDespertar() end -- el reposo cuenta desde ahora
    self:actualizarEstado()
    self:programarEstado()
end

function Pantalla:barraSuperior(screen_w)
    -- Iconos grandes y zona de toque de ≈ 1 cm (dedos anchos): icono 40 + relleno 12 por lado.
    -- En el PW2 (212 ppp) son ≈ 51 px de icono y ≈ 81 px de zona táctil.
    local tam = Screen:scaleBySize(40)
    local relleno = Screen:scaleBySize(12)
    local borde = Size.padding.large          -- separación de los bordes de la pantalla
    local separacion = Screen:scaleBySize(6)  -- entre iconos
    local izquierda = BotonIcono:new{ icono = "appbar.menu", tam = tam, relleno = relleno,
        callback = function() self:abrirPanel() end }
    -- a la derecha, la hora, el Wi-Fi y la batería (la búsqueda, favoritos y los ajustes avanzados
    -- están en el panel lateral). Ancho fijo, alineado a la derecha: si cambia la hora no se mueve nada.
    local grupo = self:grupoEstado()
    self.estado_widget = RightContainer:new{
        dimen = Geom:new{ w = grupo:getSize().w + Screen:scaleBySize(24) + separacion, h = grupo:getSize().h },
        grupo,
    }
    local derecha = self.estado_widget
    -- el botón de referencia ocupa todo el espacio que dejan los iconos
    local ancho_ref = screen_w - 2 * borde - izquierda:getSize().w - derecha:getSize().w
    local ref = self.libro and string.format("%s %d", Libros.nombre(self.libro), self.cap) or "—"
    if self.verso_sel and self.modo == "capitulo" then ref = ref .. ":" .. self.verso_sel end
    local boton_ref = Button:new{
        text = ref .. " ▾",
        width = ancho_ref - 2 * Size.padding.default,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        show_parent = self,
        callback = function() self:abrirSelector() end,
    }
    local alto = math.max(izquierda:getSize().h, boton_ref:getSize().h)
    return VerticalGroup:new{
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = borde },
            izquierda,
            CenterContainer:new{ dimen = Geom:new{ w = ancho_ref, h = alto }, boton_ref },
            derecha,
            HorizontalSpan:new{ width = borde },
        },
        LineWidget:new{ dimen = Geom:new{ w = screen_w, h = Size.line.thick * 2 } },
    }
end

function Pantalla:buildLayout()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margen = Size.padding.large -- para la línea de estado
    local lateral, superior, inferior = Ajustes.medidas(self.ajustes)
    local ancho = screen_w - 2 * margen
    local ancho_texto = screen_w - 2 * lateral

    local barra = self:barraSuperior(screen_w)
    self.alto_barra = barra:getSize().h

    local cara_estado = Font:getFace("x_smallinfofont")
    local estado = VerticalGroup:new{}
    if self.tiempos then
        estado[1] = TextWidget:new{ text = self.estado1, face = cara_estado, max_width = ancho, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        estado[2] = TextWidget:new{ text = self.estado2, face = cara_estado, max_width = ancho, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    end
    -- márgenes superior e inferior del menú de márgenes (con 0 abajo, el texto llega al borde)
    local alto_contenido = screen_h - self.alto_barra - estado:getSize().h - superior - inferior

    -- Mide cuánto tarda KOReader (MuPDF) en maquetar el HTML
    local inicio = time.now()
    self.html_widget = ScrollHtmlWidget:new{
        html_body = self.html or "",
        css = CSS .. Ajustes.css(self.ajustes),
        default_font_size = Ajustes.letra(self.ajustes),
        width = ancho_texto,
        height = alto_contenido,
        dialog = self,
        html_link_tapped_callback = function(link)
            self:onEnlace(link)
        end,
    }
    local ms_html = time.to_ms(time.since(inicio))
    local paginas_html = self.html_widget.htmlbox_widget.page_count
    logger.info("[BSH] HTML maquetado en", ms_html, "ms,", paginas_html, "páginas")
    if self.tiempos then
        estado[2]:setText(string.format("%s · HTML %d ms, %d pág.", self.estado2, ms_html, paginas_html))
    end

    -- En modo «versículo completo» el toque selecciona; las páginas se pasan deslizando.
    -- setTapScrollEnabled() no existe en KOReader v2025.10 (el del Kindle): se anula
    -- el manejador del toque en la propia instancia, que funciona en todas las versiones.
    if self.modo == "capitulo" and self.toque_completo then
        self.html_widget.onTapScrollText = function() return false end
    end
    -- Posición: ir al versículo pedido o conservar la página en la que se estaba
    if self.ir_a_verso and #self.versos > 1 then
        self.html_widget:scrollToRatio((self.ir_a_verso - 1) / #self.versos)
        self.ir_a_verso = nil
    elseif self.pagina_conservar and paginas_html > 1 then
        self.html_widget:scrollToRatio((self.pagina_conservar - 1) / paginas_html)
    end
    self.pagina_conservar = nil

    local base = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = screen_w },
            barra,
            estado,
            VerticalSpan:new{ width = superior },
            self.html_widget,
        },
    }

    if self.panel_abierto and self.db then
        self[1] = self:capaPanel(base, screen_w, screen_h)
    else
        self[1] = base
    end
end

--- Panel lateral sobre la pantalla base (≈ ⅔ del ancho, debajo de la barra superior).
-- Tocar fuera del panel lo cierra; los toques no atraviesan hasta el texto.
function Pantalla:capaPanel(base, screen_w, screen_h)
    local ancho = math.floor(screen_w * 2 / 3)
    local borde = Size.border.window * 2
    local marco = ancho - borde
    -- el contenido deja sitio a la barra de desplazamiento (3 × su ancho, como ScrollableContainer)
    local interior = marco - 3 * Screen:scaleBySize(6)
    if self.panel_desplazable then self.panel_desplazado = self.panel_desplazable:getScrolledOffset() end
    local c = self.conteo
    local ref = string.format("%s %d", Libros.nombre(self.libro), self.cap)
    if self.verso_sel then ref = ref .. ":" .. self.verso_sel end

    local function linea()
        return LineWidget:new{ dimen = Geom:new{ w = interior, h = Size.line.medium }, background = Blitbuffer.COLOR_GRAY }
    end
    local function fila(icono, texto, numero, callback, actual)
        return FilaMenu:new{ icono = ICONOS[icono], texto = texto, numero = numero, ancho = interior, actual = actual,
            callback = function()
                self:cerrarPanel()
                if callback then callback() end
            end }
    end
    local function conIcono(icono, texto) return ICONOS[icono] .. "   " .. texto end
    local en_favoritos = self.usuario and self.verso_sel and self.modo == "capitulo"
        and self.usuario:contar(self.libro, self.cap, self.verso_sel) > 0

    local contenido = VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            padding = Size.padding.large, bordersize = 0,
            TextWidget:new{ text = "Para " .. ref, face = Font:getFace("x_smallinfofont"),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = interior - 2 * Size.padding.large },
        },
        linea(),
        fila("biblia", "Biblia", nil, nil, true),
        fila("comentario", "Comentario", c.comentarios, function() self:abrirComentario() end),
        fila("diccionario", "Diccionario", c.diccionario, function() self:abrirDiccionario() end),
        fila("notas", "Notas", c.notas, function() self:abrirNotas() end),
        fila("favoritos", "Favoritos", c.favoritos, function() self:abrirFavoritos() end),
        -- lo que hacía la estrella de la barra: guardar el versículo resaltado (o cambiar su lista)
        fila(en_favoritos and "estrella" or "estrella_vacia", en_favoritos and "En favoritos…" or "Guardar en favoritos…",
            nil, function() self:estrella() end),
        fila("buscar", "Búsqueda", nil, function() self:pedirBusqueda() end),
        fila("copiar", "Copiar", nil, function() self:copiar() end),
        linea(),
        FrameContainer:new{
            padding = Size.padding.large, bordersize = 0,
            TextWidget:new{ text = "Lectura", face = Font:getFace("x_smallinfofont"),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = interior, h = 0 }, -- se recalcula abajo
            ButtonTable:new{
                width = interior - 2 * Size.padding.large,
                show_parent = self,
                buttons = {
                    { { text = conIcono("lectura", "Ajustes de lectura…"), align = "left", callback = function()
                        self:cerrarPanel()
                        self:abrirAjustes()
                    end } },
                    { { text = conIcono("letra", "Ajustes de fuentes…"), align = "left", callback = function()
                        self:cerrarPanel()
                        self:abrirFuentes()
                    end } },
                    { { text = conIcono("toque", self.toque_completo and "Modo de selección: versículo"
                            or "Modo de selección: número"), align = "left",
                        callback = function() self:cambiarToque() end } },
                },
            },
        },
    }
    -- el CenterContainer de los ajustes necesita el alto de su contenido
    local ajustes = contenido[#contenido]
    ajustes.dimen.h = ajustes[1]:getSize().h + Size.padding.large
    -- lo que abría el engranaje de la barra
    contenido[#contenido + 1] = linea()
    contenido[#contenido + 1] = fila("engranaje", "Ajustes avanzados", nil, function() self:abrirConfig() end)
    contenido[#contenido + 1] = fila("salir", "Salir", nil, function() self:salir() end)

    local alto = screen_h - self.alto_barra
    local desplazable = ScrollableContainer:new{
        dimen = Geom:new{ w = marco, h = alto },
        show_parent = self,
        contenido,
    }
    -- vuelve a donde estaba si el panel se rehace abierto (p. ej. al cambiar el modo de selección)
    if self.panel_desplazado then desplazable:setScrolledOffset(self.panel_desplazado) end
    self.panel_desplazable = desplazable
    self.cropping_widget = desplazable -- los destellos de los botones se recortan al panel

    local panel = FrameContainer:new{
        width = ancho,
        height = screen_h - self.alto_barra,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "top",
            -- son muchas opciones: si no caben, el panel se desliza hacia arriba y abajo
            desplazable,
            LineWidget:new{ dimen = Geom:new{ w = borde, h = screen_h - self.alto_barra } },
        },
    }
    panel.overlap_offset = { 0, self.alto_barra }

    local capa = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
        OverlapGroup:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            panel,
        },
    }
    if Device:isTouchDevice() then
        capa.ges_events = {
            TocarCapa = { GestureRange:new{ ges = "tap", range = function() return capa.dimen end } },
            DeslizarCapa = { GestureRange:new{ ges = "swipe", range = function() return capa.dimen end } },
        }
        capa.onTocarCapa = function(_capa, _arg, ges)
            if panel.dimen and panel.dimen:contains(ges.pos) then return true end
            self:cerrarPanel()
            return true
        end
        capa.onDeslizarCapa = function() return true end
    end

    local capas = OverlapGroup:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        base,
        capa,
    }
    -- Se pinta de abajo arriba (base, luego panel), pero los eventos llegan primero a la capa superior.
    capas.propagateEvent = function(grupo, event)
        for i = #grupo, 1, -1 do
            if grupo[i]:handleEvent(event) then return true end
        end
        return false
    end
    return capas
end

--- Reconstruye la pantalla. Con conservar_pagina se mantiene la página actual del texto.
function Pantalla:refresh(conservar_pagina)
    if conservar_pagina and self.html_widget then
        self.pagina_conservar = self.html_widget.htmlbox_widget.page_number
    end
    self:free()
    self:buildLayout()
    UIManager:setDirty(self, "ui")
end

--- Acciones --------------------------------------------------------------------

--- Resalta un versículo (o quita el resaltado con nil) sin volver a consultar la base.
function Pantalla:seleccionar(verso)
    if self.modo ~= "capitulo" then return end
    self.verso_sel = verso
    self:htmlCapitulo()
    self:refresh(true)
end

function Pantalla:onEnlace(link)
    local uri = link and link.uri
    logger.info("[BSH] toque en enlace:", uri or "(sin uri)")
    if not uri or not self.db then return end
    if uri == "verso://mas" or uri == "verso://menos" then
        local pagina = self.pagina + (uri == "verso://mas" and 1 or -1)
        if self:buscar(self.consulta, pagina) then self:refresh() end
        return
    elseif uri == "verso://rango" or uri == "verso://modo" then
        local elegir = uri == "verso://rango" and self.elegirRango or self.elegirModo
        elegir(self, function()
            if self:buscar(self.consulta, 1) then self:refresh() end
        end)
        return
    elseif uri == "verso://nueva" then
        self:pedirBusqueda()
        return
    elseif uri:match("^verso://libro%-%d+$") then
        local n = tonumber(uri:match("%d+$"))
        self.busqueda.rango, self.busqueda.desde, self.busqueda.hasta = "libros", n, n
        self:guardarBusqueda()
        if self:buscar(self.consulta, 1) then self:refresh() end
        return
    elseif uri == "verso://volver" then
        self:cargarCapitulo(self.libro, self.cap)
        self:refresh()
        return
    elseif uri == "verso://anterior" or uri == "verso://siguiente" then
        self:moverCapitulo(uri == "verso://siguiente" and 1 or -1)
        return
    elseif uri == "verso://arriba" then
        self.html_widget:scrollToRatio(0)
        return
    end
    local libro, cap, verso = uri:match("^verso://(%d+)%-(%d+)%-(%d+)$")
    libro, cap, verso = tonumber(libro), tonumber(cap), tonumber(verso)
    if not libro then return end

    if self.modo == "busqueda" then
        -- desde un resultado: vista previa del versículo con las palabras buscadas en negrita, sin
        -- dejar los resultados; «Abrir en el lector» lleva al capítulo con el versículo resaltado
        local ok, resaltado = pcall(self.db.versoResaltado, self.db, self.consulta, self.busqueda.modo, libro, cap, verso)
        UI.previaVerso{
            uri = uri,
            biblia = self.db,
            resaltado = ok and resaltado or nil,
            al_abrir = function(l, c, v)
                self:cargarCapitulo(l, c, v, true)
                self:refresh()
            end,
        }
        return
    end
    -- en el capítulo: tocar el resaltado lo quita; tocar otro lo mueve
    self:seleccionar(verso ~= self.verso_sel and verso or nil)
end

--- Toque que no cayó en un versículo ni en un botón: quita el resaltado.
function Pantalla:onTapFuera()
    if self.modo == "capitulo" and self.verso_sel then
        self:seleccionar(nil)
        return true
    end
end

--- Deslizar a la izquierda: capítulo siguiente; a la derecha: anterior. En los resultados de
-- búsqueda, página siguiente o anterior. (Arriba/abajo ya los atiende ScrollHtmlWidget y no llegan aquí.)
function Pantalla:onDeslizar(_arg, ges)
    if not self.html_widget then return end
    if self.modo == "capitulo" and (ges.direction == "west" or ges.direction == "east") then
        self:moverCapitulo(ges.direction == "west" and 1 or -1)
        return true
    end
    if ges.direction == "west" then
        self.html_widget:scrollText(1)
        return true
    elseif ges.direction == "east" then
        self.html_widget:scrollText(-1)
        return true
    end
end

--- Panel lateral: cuenta las entradas de cada módulo para el versículo resaltado (o el capítulo).
function Pantalla:abrirPanel()
    if not self.db then return end
    local verso = self.modo == "capitulo" and self.verso_sel or nil
    local inicio = time.now()
    local modulos = self:conteoModulos(verso)
    self.conteo = {
        lista_comentarios = modulos.lista,
        comentarios = modulos.total,
        lista_diccionarios = modulos.diccionarios,
        palabras = modulos.palabras,
        diccionario = #modulos.palabras,
        favoritos = self.usuario and self.usuario:contar(self.libro, self.cap, verso) or 0,
        notas = self.usuario and self.usuario:contarNotas(self.libro, self.cap, verso) or 0,
    }
    logger.info("[BSH] panel: conteos en", time.to_ms(time.since(inicio)), "ms")
    self.panel_abierto = true
    self:refresh(true)
end

--- Comentarios y palabras de diccionario del pasaje. Se guardan en memoria: los módulos no cambian
-- mientras la app está abierta (las notas y favoritos sí, y por eso se cuentan siempre).
function Pantalla:conteoModulos(verso)
    local clave = self.libro .. ":" .. self.cap .. ":" .. (verso or 0)
    local c = self.conteos_modulos[clave]
    if c then return c end
    c = {}
    c.lista, c.total = Comentarios.contarTodos(self.plugin_path, self.libro, self.cap, verso)
    -- diccionario: palabras del versículo (o de todo el capítulo) con artículo en algún diccionario
    local texto
    if verso then
        texto = self.db:verso(self.libro, self.cap, verso)
    else
        local partes = {}
        for _, f in ipairs(self.versos or {}) do partes[#partes + 1] = f[2] end
        texto = table.concat(partes, " ")
    end
    c.diccionarios = Diccionarios.listar(self.plugin_path)
    c.palabras = Diccionarios.encontradas(c.diccionarios, Diccionarios.palabrasDe(texto))
    if self.n_conteos >= 100 then -- no crece sin límite en una sesión larga
        self.conteos_modulos, self.n_conteos = {}, 0
    end
    self.conteos_modulos[clave] = c
    self.n_conteos = self.n_conteos + 1
    return c
end

function Pantalla:cerrarPanel()
    if not self.panel_abierto then return end
    self.panel_abierto = false
    self.panel_desplazable, self.panel_desplazado, self.cropping_widget = nil, nil, nil
    self:refresh(true)
end

function Pantalla:abrirComentario()
    local verso = self.modo == "capitulo" and self.verso_sel or nil
    UIManager:show(Comentarios.Pantalla:new{
        plugin_path = self.plugin_path,
        biblia = self.db, -- vista previa de las citas bíblicas
        libro = self.libro,
        cap = self.cap,
        verso = verso,
        lista = self.conteo and self.conteo.lista_comentarios,
        al_abrir = function(libro, cap, v) self:irA(libro, cap, v) end,
        al_cambiar_ajustes = function(seccion) self:aplicarAjustes(seccion) end,
    })
end

function Pantalla:abrirDiccionario()
    local verso = self.modo == "capitulo" and self.verso_sel or nil
    local ref = string.format("%s %d", Libros.nombre(self.libro), self.cap) .. (verso and (":" .. verso) or "")
    UIManager:show(Diccionarios.Pantalla:new{
        plugin_path = self.plugin_path,
        biblia = self.db, -- vista previa de las citas bíblicas
        ref = ref,
        palabras = self.conteo and self.conteo.palabras,
        lista = self.conteo and self.conteo.lista_diccionarios,
        al_abrir = function(libro, cap, v) self:irA(libro, cap, v) end,
        al_cambiar_ajustes = function(seccion) self:aplicarAjustes(seccion) end,
    })
end

--- Abre un versículo en el lector (desde un enlace de comentario, diccionario o favoritos).
function Pantalla:irA(libro, cap, verso)
    if not self.db or libro < 1 or libro > Libros.total then return end
    self:cargarCapitulo(libro, cap, verso, true)
    self:refresh()
end

function Pantalla:abrirNotas()
    if not self.usuario then
        UIManager:show(InfoMessage:new{ text = "No se pudo abrir la base de notas." })
        return
    end
    local verso = self.modo == "capitulo" and self.verso_sel or nil
    UIManager:show(Notas.Pantalla:new{
        usuario = self.usuario,
        plugin_path = self.plugin_path,
        biblia = self.db,
        libro = self.libro, capitulo = self.cap, verso = verso,
        al_abrir = function(libro, cap, v) self:irA(libro, cap, v) end,
        al_cambiar = function()
            -- actualiza las marcas de nota del capítulo que se está leyendo
            if self.modo == "capitulo" then
                self.con_nota = self.usuario:versosConNota(self.libro, self.cap)
                self:htmlCapitulo()
                self:refresh(true)
            end
        end,
        al_cambiar_ajustes = function(seccion) self:aplicarAjustes(seccion) end,
    })
end

function Pantalla:abrirFavoritos()
    if not self.usuario then
        UIManager:show(InfoMessage:new{ text = "No se pudo abrir la base de favoritos." })
        return
    end
    UIManager:show(Favoritos.Pantalla:new{
        usuario = self.usuario,
        db = self.db,
        al_abrir = function(libro, cap, verso)
            self:cargarCapitulo(libro, cap, verso, true)
            self:refresh()
        end,
    })
end

function Pantalla:abrirSelector()
    if not self.db then return end
    UIManager:show(Selector:new{
        db = self.db,
        libro = self.libro,
        cap = self.cap,
        al_elegir = function(libro, cap, verso)
            self:cargarCapitulo(libro, cap, verso, verso ~= nil)
            self:refresh()
        end,
    })
end

--- ★: guarda el versículo resaltado en una lista personalizada.
function Pantalla:estrella()
    if not self.usuario then
        UIManager:show(InfoMessage:new{ text = "No se pudo abrir la base de favoritos." })
        return
    end
    if self.modo ~= "capitulo" or not self.verso_sel then
        avisar("Toca un versículo para guardarlo en favoritos")
        return
    end
    Favoritos.dialogo{
        usuario = self.usuario,
        libro = self.libro, cap = self.cap, verso = self.verso_sel,
        al_cambiar = function() self:refresh(true) end, -- actualiza la estrella
    }
end

--- Engranaje: pantalla completa con los ajustes generales de la app.
function Pantalla:abrirConfig()
    local Config = require("bsh_ajustes_avanzados")
    UIManager:show(Config:new{
        plugin_path = self.plugin_path,
        sqlite = self.sqlite,
        tiempos = self.tiempos,
        al_cambiar_tiempos = function()
            self:cambiarTiempos()
            return self.tiempos
        end,
        al_reiniciar = function() self:reiniciar() end,
        al_salir = function() self:onClose() end,
        actualizar = self.actualizar,
        dispositivo = self.dispositivo,
        al_cambiar_pantalla = function() self:refresh(true) end, -- el contraste: dibujar de nuevo
    })
end

--- «Salir» del panel lateral: pregunta antes de cerrar la app.
function Pantalla:salir()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = "¿Confirma que desea salir?",
        ok_text = "Salir",
        cancel_text = "Cancelar",
        ok_callback = function() self:onClose() end,
    })
end

--- Vuelve a la pantalla de carga con todo cerrado y comprueba de nuevo todos los módulos.
function Pantalla:reiniciar()
    Registro.olvidar()
    UIManager:close(self)
    if self.al_reiniciar then self.al_reiniciar() end
end

--- Copia el versículo resaltado con su referencia al portapapeles de KOReader.
function Pantalla:copiar()
    if self.modo ~= "capitulo" or not self.verso_sel then
        avisar("Toca un versículo para copiarlo")
        return
    end
    local ref = string.format("%s %d:%d", Libros.nombre(self.libro), self.cap, self.verso_sel)
    local texto = self.db:verso(self.libro, self.cap, self.verso_sel) or ""
    Device.input.setClipboardText(string.format("%s %s (RVR1960)", texto, ref))
    avisar("Copiado: " .. ref)
end

function Pantalla:moverCapitulo(delta)
    if not self.db then return end
    local libro, cap = self:capituloVecino(delta)
    self:cargarCapitulo(libro, cap)
    self:refresh()
end

function Pantalla:pedirTexto(titulo, actual, pista, al_aceptar)
    local dialogo
    dialogo = InputDialog:new{
        title = titulo,
        input = actual or "",
        input_hint = pista,
        buttons = {
            {
                { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dialogo) end },
                { text = _("Aceptar"), is_enter_default = true, callback = function()
                    local texto = dialogo:getInputText()
                    UIManager:close(dialogo)
                    al_aceptar(texto)
                end },
            },
        },
    }
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

--- Cuadro de búsqueda: el texto, «Dónde» (grupo de libros) y «Cómo» (modo). Al cambiar una
-- opción se cierra y se vuelve a abrir con lo escrito (texto = lo que había en el cuadro).
function Pantalla:pedirBusqueda(texto)
    if not self.db then return end
    local nombre_rango = self:rangoActual()
    local modo = DB.modo(self.busqueda.modo)
    local dialogo
    local function reabrir(elegir)
        local escrito = dialogo:getInputText()
        UIManager:close(dialogo)
        elegir(self, function() self:pedirBusqueda(escrito) end, function() self:pedirBusqueda(escrito) end)
    end
    dialogo = InputDialog:new{
        title = "Buscar en la Biblia",
        description = modo.ayuda,
        input = texto or self.consulta or "",
        input_hint = "amor",
        buttons = {
            { { text = "Dónde: " .. nombre_rango .. "  ▾", callback = function() reabrir(self.elegirRango) end } },
            { { text = "Cómo: " .. modo.nombre .. "  ▾", callback = function() reabrir(self.elegirModo) end } },
            {
                { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dialogo) end },
                { text = "Buscar", is_enter_default = true, callback = function()
                    local escrito = dialogo:getInputText()
                    if escrito:match("^%s*$") then return end
                    UIManager:close(dialogo)
                    if self:buscar(escrito, 1) then self:refresh() end
                end },
            },
        },
    }
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

--- Lista de opciones en dos columnas con ✓ en la actual. opciones: { {texto, actual, al_tocar}, ... }
local function elegirEn(titulo, opciones, al_cancelar)
    local dialogo
    local filas, fila = {}, {}
    for _, o in ipairs(opciones) do
        fila[#fila + 1] = { text = (o.actual and "✓ " or "") .. o.texto, callback = function()
            UIManager:close(dialogo)
            o.al_tocar()
        end }
        if #fila == (opciones.columnas or 2) then
            filas[#filas + 1], fila = fila, {}
        end
    end
    if #fila > 0 then filas[#filas + 1] = fila end
    filas[#filas + 1] = { { text = _("Cancelar"), callback = function()
        UIManager:close(dialogo)
        if al_cancelar then al_cancelar() end
    end } }
    -- tocar fuera también cancela (y así vuelve el cuadro de búsqueda con lo escrito)
    dialogo = ButtonDialog:new{ title = titulo, title_align = "center", buttons = filas, tap_close_callback = al_cancelar }
    UIManager:show(dialogo)
    return dialogo
end

--- Dónde buscar: grupos de libros, el libro actual o un tramo «desde … hasta …».
function Pantalla:elegirRango(al_elegir, al_cancelar)
    local b = self.busqueda
    local opciones = {}
    for _, g in ipairs(Libros.GRUPOS) do
        local texto = g.nombre
        if g.id == "actual" then
            texto = "Libro actual: " .. Libros.nombre(self.libro)
        elseif g.id == "libros" and b.rango == "libros" then
            texto = (Libros.rango("libros", nil, b.desde, b.hasta)) .. "…"
        end
        opciones[#opciones + 1] = { texto = texto, actual = g.id == b.rango, al_tocar = function()
            if g.id == "libros" then
                self:elegirLibros(al_elegir, al_cancelar)
                return
            end
            b.rango = g.id
            self:guardarBusqueda()
            al_elegir()
        end }
    end
    elegirEn("Dónde buscar", opciones, al_cancelar)
end

--- Tramo de libros: primero desde cuál, luego hasta cuál (el mismo para buscar en uno solo).
function Pantalla:elegirLibros(al_elegir, al_cancelar)
    UIManager:show(Selector:new{
        solo_libro = true,
        titulo = "Buscar desde el libro…",
        al_elegir = function(desde)
            UIManager:show(Selector:new{
                solo_libro = true,
                titulo = "…hasta el libro (" .. Libros.abreviatura(desde) .. " o uno posterior)",
                libro_min = desde,
                al_elegir = function(hasta)
                    local b = self.busqueda
                    b.rango, b.desde, b.hasta = "libros", desde, hasta
                    self:guardarBusqueda()
                    al_elegir()
                end,
                onClose = function(sel)
                    UIManager:close(sel)
                    if al_cancelar then al_cancelar() end
                    return true
                end,
            })
        end,
        onClose = function(sel)
            UIManager:close(sel)
            if al_cancelar then al_cancelar() end
            return true
        end,
    })
end

--- Cómo buscar: los modos de DB.MODOS, uno por fila con su explicación en el cuadro.
function Pantalla:elegirModo(al_elegir, al_cancelar)
    local opciones = { columnas = 1 }
    for _, m in ipairs(DB.MODOS) do
        opciones[#opciones + 1] = { texto = m.nombre, actual = m.id == self.busqueda.modo, al_tocar = function()
            self.busqueda.modo = m.id
            self:guardarBusqueda()
            al_elegir()
        end }
    end
    elegirEn("Cómo buscar", opciones, al_cancelar)
end

--- Ajustes de lectura (sección Biblia). Desde aquí también se pueden cambiar los de los
-- comentarios y diccionarios, aunque su resultado solo se ve con uno de ellos abierto.
function Pantalla:abrirAjustes()
    Ajustes.dialogo{ seccion = "biblia", en = "biblia", al_cambiar = function(seccion) self:aplicarAjustes(seccion) end }
end

--- Tipo de letra, con las mismas dos secciones que los ajustes de lectura.
function Pantalla:abrirFuentes()
    Ajustes.dialogoFuentes{ seccion = "biblia", en = "biblia", al_cambiar = function(seccion) self:aplicarAjustes(seccion) end }
end

--- Vuelve a leer los ajustes de la Biblia y rehace el lector (también si está tapado por un
-- comentario o diccionario: se verá así al volver).
function Pantalla:aplicarAjustes(seccion)
    if seccion ~= "biblia" then return end
    self.ajustes = Ajustes.leer("biblia")
    self:refresh(true)
end

function Pantalla:cambiarToque()
    self.toque_completo = not self.toque_completo
    G_reader_settings:saveSetting("bsh_toque_completo", self.toque_completo)
    if self.modo == "capitulo" then
        self:htmlCapitulo()
    end
    self:refresh(true)
end

function Pantalla:cambiarTiempos()
    self.tiempos = not self.tiempos
    G_reader_settings:saveSetting("bsh_tiempos", self.tiempos)
    self:refresh(true)
end

--- Ciclo de vida ---------------------------------------------------------------

function Pantalla:onShow()
    UIManager:setDirty(self, "flashui")
    self:programarEstado()
    return true
end

function Pantalla:onCloseWidget()
    self.cerrado = true
    if self.reloj then UIManager:unschedule(self.reloj) end
    if self.db then
        G_reader_settings:saveSetting("bsh_pos", { self.libro, self.cap })
        self.db:cerrar()
        self.db = nil
    end
    if self.usuario then
        self.usuario:cerrar()
        self.usuario = nil
    end
    Registro.cerrar()
    UIManager:setDirty(nil, "flashui")
end

function Pantalla:onClose()
    UIManager:close(self)
    return true
end

return Pantalla
