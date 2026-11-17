--[[--
Módulo de comentarios.

Cada comentario es un archivo .ebc (SQLite con la marca del formato propio, ver bsh_db.lua)
en data/comentarios/ con este esquema (tools/convertir_theword.py):
    meta(clave, valor)                         -- nombre, autor, descripcion
    entradas(libro, capitulo, verso_desde, verso_hasta, html)
        verso_desde NULL = comentario del capítulo completo

Búsqueda (se muestra un comentario a la vez):
    1. entradas del versículo resaltado (incluye rangos como 3:16-17)
    2. si no hay ninguna, entradas del capítulo completo
Al cambiar de comentario se repite la búsqueda en el nuevo.
Comentarios.contarTodos() cuenta en todos los instalados (para el número del panel lateral):
una consulta con índice por archivo, sobre las conexiones ya abiertas del registro.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local time = require("ui/time")
local Ajustes = require("bsh_ajustes_lectura")
local DB = require("bsh_db")
local Libros = require("bsh_libros")
local Registro = require("bsh_registro")
local UI = require("bsh_ui")
local Input = Device.input
local Screen = Device.screen

local CSS = [[
@page { margin: 0; } /* MuPDF pone un margen de página por defecto que dejaba blanco alrededor */
body { margin: 0; line-height: 1.4; text-align: justify; }
h2 { font-size: 1.15em; margin: 0 0 0.4em 0; text-align: left; }
h3 { font-size: 1em; margin: 0.8em 0 0.2em 0; text-align: left; }
p { margin: 0 0 0.4em 0; }
p.aviso { color: #555555; font-style: italic; }
a { color: black; text-decoration: underline; }
]]

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local Comentarios = {}

--- Lista los comentarios instalados: { { archivo, ruta, nombre }, ... } ordenados por nombre.
-- Solo los .ebc con la marca del formato propio; la lista y las conexiones son del registro.
function Comentarios.listar(plugin_path)
    return Registro.lista("comentario", plugin_path)
end

local function referencia(libro, cap, desde, hasta)
    local ref = Libros.nombre(libro) .. " " .. cap
    if desde then
        ref = ref .. ":" .. desde
        if hasta and hasta ~= desde then ref = ref .. "-" .. hasta end
    end
    return ref
end

--- Busca en UN comentario. verso puede ser nil (solo capítulo).
-- modo: nil = la referencia (versículo o, si no hay entrada, capítulo);
--       "capitulo" = todas las entradas del capítulo; "libro" = introducción al libro (capitulo 0)
-- @treturn string html, number ms, number entradas
function Comentarios.buscar(comentario, libro, cap, verso, modo)
    local inicio = time.now()
    local db, err = Registro.conexion(comentario)
    if not db then
        return "<p>No se pudo abrir " .. escapar(comentario.archivo) .. ": " .. escapar(err) .. "</p>", 0, 0
    end
    local filas, aviso
    if modo == "libro" then
        filas = db:filas("SELECT NULL, NULL, html FROM entradas WHERE libro = ? AND capitulo = 0", libro)
    elseif modo == "capitulo" then
        filas = db:filas([[SELECT verso_desde, verso_hasta, html FROM entradas
            WHERE libro = ? AND capitulo = ? ORDER BY coalesce(verso_desde, 0)]], libro, cap)
    else
        if verso then
            filas = db:filas([[SELECT verso_desde, verso_hasta, html FROM entradas
                WHERE libro = ? AND capitulo = ? AND verso_desde IS NOT NULL
                  AND ? BETWEEN verso_desde AND coalesce(verso_hasta, verso_desde)
                ORDER BY verso_desde]], libro, cap, verso)
        end
        if not filas or #filas == 0 then
            filas = db:filas([[SELECT verso_desde, verso_hasta, html FROM entradas
                WHERE libro = ? AND capitulo = ? AND verso_desde IS NULL]], libro, cap)
            if verso and #filas > 0 then
                aviso = "No hay entrada para el versículo " .. verso .. "; se muestra el comentario del capítulo."
            end
        end
    end
    local ms = time.to_ms(time.since(inicio))

    local titulo
    if modo == "libro" then
        titulo = "Introducción a " .. Libros.nombre(libro)
    elseif modo == "capitulo" then
        titulo = referencia(libro, cap) .. " (capítulo completo)"
    else
        titulo = referencia(libro, cap, verso)
    end
    local html = { "<h2>" .. escapar(titulo) .. "</h2>" }
    if aviso then html[#html + 1] = '<p class="aviso">' .. escapar(aviso) .. "</p>" end
    for _, f in ipairs(filas) do
        if modo ~= "libro" then
            html[#html + 1] = "<h3>" .. escapar(referencia(libro, cap, f[1], f[2])) .. "</h3>"
        end
        html[#html + 1] = f[3] -- HTML del propio comentario (archivo local de confianza)
    end
    if #filas == 0 then
        html[#html + 1] = '<p class="aviso">Sin ' .. (modo == "libro" and "introducción" or "comentario")
            .. " para " .. escapar(modo == "libro" and Libros.nombre(libro) or referencia(libro, cap, verso))
            .. " en «" .. escapar(comentario.nombre) .. "».</p>"
    end
    logger.info("[BSH] comentario", comentario.archivo, titulo, "→", #filas, "entradas en", ms, "ms")
    return table.concat(html, "\n"), ms, #filas
end

--- Cuántas entradas mostraría Comentarios.buscar (versículo, o capítulo si no hay ninguna).
function Comentarios.contar(comentario, libro, cap, verso)
    local db = Registro.conexion(comentario)
    if not db then return 0 end
    local n = 0
    local ok, err = pcall(function()
        if verso then
            n = db:filas([[SELECT count(*) FROM entradas WHERE libro = ? AND capitulo = ?
                AND verso_desde IS NOT NULL AND ? BETWEEN verso_desde AND coalesce(verso_hasta, verso_desde)]],
                libro, cap, verso)[1][1]
        end
        if n == 0 then
            n = db:filas("SELECT count(*) FROM entradas WHERE libro = ? AND capitulo = ? AND verso_desde IS NULL",
                libro, cap)[1][1]
        end
    end)
    if not ok then logger.warn("[BSH] no se pudo contar en", comentario.archivo, err) end
    return n
end

--- Cuenta en todos los comentarios instalados. Devuelve una lista con el número de cada uno
-- en .n y el total.
function Comentarios.contarTodos(plugin_path, libro, cap, verso)
    local inicio = time.now()
    local lista = {}
    local total = 0
    for _, c in ipairs(Comentarios.listar(plugin_path)) do
        local n = Comentarios.contar(c, libro, cap, verso)
        -- copia: el número es de este pasaje, y el panel guarda varios pasajes en memoria
        lista[#lista + 1] = { archivo = c.archivo, ruta = c.ruta, nombre = c.nombre, db = c.db, n = n }
        total = total + n
    end
    logger.info("[BSH] conteo de comentarios", libro, cap, verso, "→", total, "en",
        time.to_ms(time.since(inicio)), "ms")
    return lista, total
end

--- Pantalla del comentario ---------------------------------------------------------
-- Barra superior (alfa 8): «Comentario ▾» elige otro comentario, ⋮ abre el menú (capítulo,
-- introducción, ajustes) y ✕ vuelve al texto. Las citas bíblicas se ven en una ventana flotante.

local ComentarioPantalla = InputContainer:extend{
    name = "bsh_comentario",
    covers_fullscreen = true,
    plugin_path = nil,
    biblia = nil, -- DB de la Biblia abierta en el lector (para la vista previa de las citas)
    libro = nil, cap = nil, verso = nil, -- verso nil = comentario del capítulo
    lista = nil, -- opcional: resultado de Comentarios.contarTodos
    al_abrir = nil, -- function(libro, cap, verso): «Abrir en el lector» desde la vista previa
    al_cambiar_ajustes = nil, -- function(seccion): se cambiaron los ajustes de la Biblia
}

function ComentarioPantalla:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ajustes = Ajustes.leer("modulos") -- letra, márgenes, interlineado y alineación
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    -- la lista llega ya contada desde el panel lateral (c.n); si no, se cuenta aquí
    self.lista = self.lista or Comentarios.contarTodos(self.plugin_path, self.libro, self.cap, self.verso)
    -- empieza por el último comentario elegido si tiene entrada; si no, por el primero que tenga
    local elegido = G_reader_settings:readSetting("bsh_comentario")
    self.indice = 1
    local primero_con_entrada
    for i, c in ipairs(self.lista) do
        if DB.sinExtension(c.archivo) == DB.sinExtension(elegido) then self.indice = i end
        if not primero_con_entrada and (c.n or 0) > 0 then primero_con_entrada = i end
    end
    local actual = self.lista[self.indice]
    if actual and (actual.n or 0) == 0 and primero_con_entrada then
        self.indice = primero_con_entrada
    end
    self.modo = nil -- nil = la referencia; "capitulo"; "libro"
    self:consultar()
    self:buildLayout()
end

function ComentarioPantalla:consultar()
    local c = self.lista[self.indice]
    if not c then
        self.html = "<h2>No hay comentarios instalados</h2><p>Copia comentarios .ebc en data/comentarios/ del plugin (tools/convertir_theword.py).</p>"
        return
    end
    self.html = Comentarios.buscar(c, self.libro, self.cap, self.verso, self.modo)
end

function ComentarioPantalla:buildLayout()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local lateral, superior, inferior = Ajustes.medidas(self.ajustes)
    local c = self.lista[self.indice]
    local barra = UI.barra{
        texto = (c and c.nombre or "Sin comentarios") .. " ▾",
        al_tocar = function() self:elegirComentario() end,
        derecha = {
            { archivo = self.plugin_path .. "/iconos/puntos.svg", callback = function() self:menuPuntos() end },
            { icono = "close", callback = function() self:onClose() end },
        },
        show_parent = self,
    }
    local alto = screen_h - barra:getSize().h - superior - inferior
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
            barra,
            VerticalSpan:new{ width = superior },
            ScrollHtmlWidget:new{
                html_body = self.html,
                css = CSS .. Ajustes.css(self.ajustes),
                default_font_size = Ajustes.letra(self.ajustes),
                width = screen_w - 2 * lateral,
                height = alto,
                dialog = self,
                html_link_tapped_callback = function(link)
                    -- citas bíblicas del comentario: vista previa sin salir del comentario
                    UI.previaVerso{
                        uri = link.uri,
                        biblia = self.biblia,
                        al_abrir = self.al_abrir and function(libro, cap, verso)
                            UIManager:close(self)
                            self.al_abrir(libro, cap, verso)
                        end,
                    }
                end,
            },
        },
    }
end

function ComentarioPantalla:refresh()
    self:free()
    self:buildLayout()
    UIManager:setDirty(self, "ui")
end

function ComentarioPantalla:verModo(modo)
    self.modo = modo
    self:consultar()
    self:refresh()
end

--- «Comentario ▾»: los comentarios instalados con sus entradas para el pasaje; ✓ el actual.
function ComentarioPantalla:elegirComentario()
    if #self.lista == 0 then return end
    local dialogo
    local filas = {}
    for i, c in ipairs(self.lista) do
        filas[#filas + 1] = { {
            text = (i == self.indice and "✓ " or "") .. c.nombre .. " (" .. (c.n or 0) .. ")",
            callback = function()
                UIManager:close(dialogo)
                if i == self.indice then return end
                self.indice = i
                G_reader_settings:saveSetting("bsh_comentario", c.archivo)
                self:consultar()
                self:refresh()
            end,
        } }
    end
    dialogo = ButtonDialog:new{ title = "Comentario", title_align = "center", buttons = filas }
    UIManager:show(dialogo)
end

--- ⋮: capítulo completo, introducción al libro y ajustes de lectura.
function ComentarioPantalla:menuPuntos()
    local dialogo
    local function opcion(texto, accion)
        return { { text = texto, callback = function()
            UIManager:close(dialogo)
            accion()
        end } }
    end
    dialogo = ButtonDialog:new{
        buttons = {
            opcion(self.modo == "capitulo" and "Solo la referencia" or "Todo el capítulo", function()
                self:verModo(self.modo ~= "capitulo" and "capitulo" or nil)
            end),
            opcion(self.modo == "libro" and "Solo la referencia" or "Introducción al libro", function()
                self:verModo(self.modo ~= "libro" and "libro" or nil)
            end),
            opcion("Ajustes de lectura…", function() self:abrirAjustes() end),
        },
    }
    UIManager:show(dialogo)
end

--- Ajustes de lectura con la sección Comentarios y diccionarios: el resultado se ve aquí mismo.
-- Si se cambian los de la Biblia, el lector de detrás se rehace para cuando se vuelva.
function ComentarioPantalla:abrirAjustes()
    Ajustes.dialogo{ seccion = "modulos", en = "modulos", al_cambiar = function(seccion)
        if seccion == "modulos" then
            self.ajustes = Ajustes.leer("modulos")
            self:refresh()
        elseif self.al_cambiar_ajustes then
            self.al_cambiar_ajustes(seccion)
        end
    end }
end

function ComentarioPantalla:onShow()
    UIManager:setDirty(self, "flashui")
    return true
end

function ComentarioPantalla:onCloseWidget()
    UIManager:setDirty(nil, "flashui")
end

function ComentarioPantalla:onClose()
    UIManager:close(self)
    return true
end

Comentarios.Pantalla = ComentarioPantalla
return Comentarios
