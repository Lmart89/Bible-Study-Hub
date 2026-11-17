--[[--
Módulo de diccionarios.

Cada diccionario es un .ebd (SQLite con la marca del formato propio, ver bsh_db.lua)
en data/diccionarios/ (tools/convertir_theword.py):
    meta(clave, valor)                   -- nombre, abreviatura, autor
    entradas(id, termino, html)
    variantes(palabra, entrada_id)       -- palabras normalizadas: minúsculas y sin tildes

  * Diccionarios.palabrasDe(texto): palabras de un versículo (o capítulo) que vale la pena buscar
  * Diccionarios.encontradas(lista, palabras): las que tienen artículo en algún diccionario
    (el número que muestra el panel lateral)
  * Diccionarios.Pantalla: lista de esas palabras → artículo; buscar un término.
    Desde la alfa 8, como los comentarios, se consulta un diccionario a la vez (el elegido en la
    barra): la lista, los artículos y la búsqueda solo cargan los de ese diccionario.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local time = require("ui/time")
local DB = require("bsh_db")
local Ajustes = require("bsh_ajustes_lectura")
local Libros = require("bsh_libros")
local Registro = require("bsh_registro")
local UI = require("bsh_ui")
local Input = Device.input
local Screen = Device.screen

local CSS = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.4; text-align: justify; }
h2 { font-size: 1.15em; margin: 0 0 0.4em 0; text-align: left; }
h3 { font-size: 1em; margin: 0.9em 0 0.2em 0; text-align: left; border-bottom: 1px solid black; }
h4 { font-size: 1em; margin: 0.5em 0 0.1em 0; text-align: left; }
p { margin: 0 0 0.4em 0; }
p.aviso { color: #555555; font-style: italic; }
p.palabras { line-height: 2; text-align: left; }
a { color: black; text-decoration: underline; }
]]

-- Palabras muy frecuentes que no se buscan
local VACIAS = {}
for p in ([[
a al algo algun alguna alguno algunos ante aquel aquella aquellos asi aun bajo cada como con conmigo contra cual cuales
cuando de del desde donde dos el ella ellas ello ellos en entre era eran es esa esas ese eso esos esta estaba estas este
esto estos fue fueron ha habia han hasta hay he la las le les lo los mas me mi mis mucho muy nada ni no nos nosotros o os
otra otro otros para pero poco por porque pues que quien se sea segun ser si sin sino sobre son su sus tal tambien tan
tanto te ti tiene todo todos tu tus un una uno unos vosotros y ya yo dijo dice cosas cosa aquel vuestro vuestra
]]):gmatch("%a+") do VACIAS[p] = true end

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local Diccionarios = {}

--- Diccionarios instalados: { { archivo, ruta, nombre }, ... } por nombre.
-- Solo los .ebd con la marca del formato propio; la lista y las conexiones son del registro.
function Diccionarios.listar(plugin_path)
    return Registro.lista("diccionario", plugin_path)
end

--- Palabras de un texto para buscar: { { norm = "amor", original = "amó" }, ... } sin repetir,
-- en el orden en que aparecen; sin palabras vacías ni de menos de 3 letras.
function Diccionarios.palabrasDe(texto)
    local vistas, out = {}, {}
    -- ¡ ¿ « » (UTF-8) se quitan; el resto de signos ASCII separan palabras
    texto = (texto or ""):gsub("\194[\161\171\187\191]", " ")
    for trozo in texto:gmatch("[^%s%p]+") do
        local norm = Libros.normalizar(trozo)
        if #norm >= 3 and norm:match("^%a+$") and not VACIAS[norm] and not vistas[norm] then
            vistas[norm] = true
            out[#out + 1] = { norm = norm, original = trozo }
        end
    end
    return out
end

--- Palabras (de palabrasDe) que tienen artículo en algún diccionario de la lista.
-- @treturn table subconjunto en el mismo orden
function Diccionarios.encontradas(lista, palabras)
    local inicio = time.now()
    local hay = {}
    for _, dic in ipairs(lista) do
        local db = Registro.conexion(dic)
        if db then
            -- de 200 en 200 para no pasar el límite de parámetros de SQLite
            for i = 1, #palabras, 200 do
                local marcas, valores = {}, {}
                for j = i, math.min(#palabras, i + 199) do
                    marcas[#marcas + 1] = "?"
                    valores[#valores + 1] = palabras[j].norm
                end
                local ok, filas = pcall(db.filas, db, "SELECT DISTINCT palabra FROM variantes WHERE palabra IN ("
                    .. table.concat(marcas, ",") .. ")", unpack(valores))
                if ok then
                    for _, f in ipairs(filas) do hay[f[1]] = true end
                end
            end
        end
    end
    local out = {}
    for _, p in ipairs(palabras) do
        if hay[p.norm] then out[#out + 1] = p end
    end
    logger.info("[BSH] diccionario:", #palabras, "palabras →", #out, "con artículo en",
        time.to_ms(time.since(inicio)), "ms")
    return out
end

--- HTML con los artículos de un término en los diccionarios de la lista (la pantalla pasa solo el
-- elegido; con uno solo no se repite su nombre). Si no lo tiene tal cual, propone los términos que
-- empiezan igual.
function Diccionarios.articulo(lista, termino)
    local norm = Libros.normalizar(termino)
    local html = { "<h2>" .. escapar(termino) .. "</h2>" }
    local total, parecidos = 0, {}
    for _, dic in ipairs(lista) do
        local db = Registro.conexion(dic)
        if db then
            local filas = db:filas([[SELECT e.termino, e.html FROM variantes v JOIN entradas e ON e.id = v.entrada_id
                WHERE v.palabra = ? ORDER BY length(e.termino) LIMIT 8]], norm)
            if #filas > 0 then
                if #lista > 1 then html[#html + 1] = "<h3>" .. escapar(dic.nombre) .. "</h3>" end
                local vistos = {}
                for _, f in ipairs(filas) do
                    if not vistos[f[2]] then -- el DRAE repite artículos idénticos
                        vistos[f[2]] = true
                        html[#html + 1] = "<h4>" .. escapar(f[1]) .. "</h4>" .. f[2]
                        total = total + 1
                    end
                end
            else
                for _, f in ipairs(db:filas([[SELECT DISTINCT e.termino FROM variantes v JOIN entradas e ON e.id = v.entrada_id
                    WHERE v.palabra >= ? AND v.palabra < ? ORDER BY v.palabra LIMIT 6]], norm, norm .. "\255")) do
                    parecidos[#parecidos + 1] = f[1]
                end
            end
        end
    end
    if total == 0 then
        local donde = #lista == 1 and ("«" .. escapar(lista[1].nombre) .. "» no tiene «") or "Ningún diccionario tiene «"
        html[#html + 1] = '<p class="aviso">' .. donde .. escapar(termino) .. "».</p>"
    end
    if #parecidos > 0 then
        local enlaces = {}
        for _, t in ipairs(parecidos) do
            enlaces[#enlaces + 1] = string.format('<a href="dic://%s">%s</a>', escapar(Libros.normalizar(t)), escapar(t))
        end
        html[#html + 1] = '<p class="palabras">' .. (total == 0 and "Términos parecidos: " or "En otros diccionarios: ")
            .. table.concat(enlaces, " · ") .. "</p>"
    end
    return table.concat(html, "\n"), total
end

--- Pantalla ------------------------------------------------------------------------------
-- Barra superior (alfa 8): ‹ vuelve al término anterior (o a la lista de palabras), «Nelson ▾»
-- cambia de diccionario, 🔍 busca un término en el elegido, ⋮ abre el menú y ✕ vuelve al texto.
-- Las citas bíblicas se ven en una ventana flotante.

local Pantalla = InputContainer:extend{
    name = "bsh_diccionario",
    covers_fullscreen = true,
    plugin_path = nil,
    biblia = nil,       -- DB de la Biblia abierta en el lector (para la vista previa de las citas)
    ref = nil,          -- «Juan 3:16» o «Juan 3»
    palabras = nil,     -- resultado de Diccionarios.encontradas
    lista = nil,        -- diccionarios (Diccionarios.listar)
    al_abrir = nil,     -- function(libro, cap, verso): «Abrir en el lector» desde la vista previa
    al_cambiar_ajustes = nil, -- function(seccion): se cambiaron los ajustes de la Biblia
}

function Pantalla:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ajustes = Ajustes.leer("modulos") -- letra, márgenes, interlineado y alineación
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    self.lista = self.lista or Diccionarios.listar(self.plugin_path)
    -- palabras del pasaje con artículo en cada diccionario (las del panel son las de todos juntos)
    for _, d in ipairs(self.lista) do
        d.palabras = Diccionarios.encontradas({ d }, self.palabras or {})
    end
    -- empieza por el último diccionario elegido si tiene palabras; si no, por el primero que tenga
    local elegido = G_reader_settings:readSetting("bsh_diccionario")
    self.indice = 1
    local primero_con_palabras
    for i, d in ipairs(self.lista) do
        if DB.sinExtension(d.archivo) == DB.sinExtension(elegido) then self.indice = i end
        if not primero_con_palabras and #d.palabras > 0 then primero_con_palabras = i end
    end
    local actual = self.lista[self.indice]
    if actual and #actual.palabras == 0 and primero_con_palabras then
        self.indice = primero_con_palabras
    end
    self.historia = {} -- términos vistos, para «‹»
    self:verLista()
    self.iniciada = true
end

function Pantalla:verLista()
    local html = { "<h2>" .. escapar(self.ref or "") .. "</h2>" }
    local d = self.lista[self.indice]
    if not d then
        html[#html + 1] = '<p class="aviso">No hay diccionarios .ebd en data/diccionarios/ del plugin (tools/convertir_theword.py).</p>'
    elseif #d.palabras == 0 then
        html[#html + 1] = '<p class="aviso">Ninguna palabra de este pasaje tiene artículo en «' .. escapar(d.nombre)
            .. "». Busca un término con la lupa o elige otro diccionario arriba.</p>"
    else
        html[#html + 1] = "<p>Palabras con artículo en «" .. escapar(d.nombre) .. "»:</p>"
        local enlaces = {}
        for _, p in ipairs(d.palabras) do
            enlaces[#enlaces + 1] = string.format('<a href="dic://%s">%s</a>', p.norm, escapar(p.original))
        end
        html[#html + 1] = '<p class="palabras">' .. table.concat(enlaces, " · ") .. "</p>"
    end
    self.html = table.concat(html, "\n")
    self.termino = nil
    self:refresh()
end

function Pantalla:verTermino(termino, sin_historia)
    if not sin_historia then
        -- false = la lista de palabras del pasaje
        self.historia[#self.historia + 1] = self.termino or false
    end
    -- solo en el diccionario elegido
    local html = Diccionarios.articulo({ self.lista[self.indice] }, termino)
    self.html = html
    self.termino = termino
    self:refresh()
end

--- ‹: el término anterior, la lista de palabras o, desde la lista, cerrar.
function Pantalla:atras()
    if #self.historia == 0 then
        if self.termino then return self:verLista() end
        return self:onClose()
    end
    local anterior = table.remove(self.historia)
    if anterior then
        self:verTermino(anterior, true)
    else
        self:verLista()
    end
end

--- «Nelson ▾»: los diccionarios instalados con sus palabras del pasaje; ✓ el actual. Al cambiar,
-- se repite en el nuevo lo que se estaba viendo (el término o la lista de palabras).
function Pantalla:elegirDiccionario()
    if #self.lista == 0 then return end
    local dialogo
    local filas = {}
    for i, d in ipairs(self.lista) do
        filas[#filas + 1] = { {
            text = (i == self.indice and "✓ " or "") .. d.nombre .. " (" .. #d.palabras .. ")",
            callback = function()
                UIManager:close(dialogo)
                if i == self.indice then return end
                self.indice = i
                G_reader_settings:saveSetting("bsh_diccionario", d.archivo)
                if self.termino then self:verTermino(self.termino, true) else self:verLista() end
            end,
        } }
    end
    dialogo = ButtonDialog:new{ title = "Diccionario", title_align = "center", buttons = filas }
    UIManager:show(dialogo)
end

--- 🔍: busca un término solo en el diccionario elegido.
function Pantalla:buscarTermino()
    local d = self.lista[self.indice]
    if not d then return end
    local dialogo
    dialogo = InputDialog:new{
        title = "Buscar en «" .. d.nombre .. "»",
        input_hint = "templo",
        buttons = {
            {
                { text = "Cancelar", id = "close", callback = function() UIManager:close(dialogo) end },
                { text = "Buscar", is_enter_default = true, callback = function()
                    local t = dialogo:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialogo)
                    if t ~= "" then self:verTermino(t) end
                end },
            },
        },
    }
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

--- ⋮: volver a las palabras del pasaje y ajustes de lectura (buscar está en la lupa).
function Pantalla:menuPuntos()
    local dialogo
    dialogo = ButtonDialog:new{
        buttons = {
            { { text = "Palabras de " .. (self.ref or "el pasaje"), enabled = self.termino ~= nil, callback = function()
                UIManager:close(dialogo)
                self.historia[#self.historia + 1] = self.termino
                self:verLista()
            end } },
            { { text = "Ajustes de lectura…", callback = function()
                UIManager:close(dialogo)
                self:abrirAjustes()
            end } },
        },
    }
    UIManager:show(dialogo)
end

function Pantalla:buildLayout()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local lateral, superior, inferior = Ajustes.medidas(self.ajustes)
    local barra = UI.barra{
        izquierda = { { icono = "chevron.left", callback = function() self:atras() end } },
        texto = ((self.lista[self.indice] or {}).nombre or "Sin diccionarios") .. " ▾",
        al_tocar = function() self:elegirDiccionario() end,
        derecha = {
            { icono = "appbar.search", callback = function() self:buscarTermino() end },
            { archivo = self.plugin_path .. "/iconos/puntos.svg", callback = function() self:menuPuntos() end },
            { icono = "close", callback = function() self:onClose() end },
        },
        show_parent = self,
    }
    local alto = screen_h - barra:getSize().h - superior - inferior
    self[1] = FrameContainer:new{
        width = screen_w, height = screen_h,
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
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
                html_link_tapped_callback = function(link) self:onEnlace(link) end,
            },
        },
    }
end

function Pantalla:onEnlace(link)
    local uri = link and link.uri or ""
    local termino = uri:match("^dic://(.+)$")
    if termino then
        self:verTermino(termino)
        return
    end
    -- citas bíblicas: vista previa sin salir del diccionario
    UI.previaVerso{
        uri = uri,
        biblia = self.biblia,
        al_abrir = self.al_abrir and function(libro, cap, verso)
            UIManager:close(self)
            self.al_abrir(libro, cap, verso)
        end,
    }
end

function Pantalla:refresh()
    if not self.iniciada then -- primera vez (desde init): todavía no está en pantalla
        self:buildLayout()
        return
    end
    self:free()
    self:buildLayout()
    UIManager:setDirty(self, "ui")
end

--- Ajustes de lectura con la sección Comentarios y diccionarios: el resultado se ve aquí mismo.
-- Si se cambian los de la Biblia, el lector de detrás se rehace para cuando se vuelva.
function Pantalla:abrirAjustes()
    Ajustes.dialogo{ seccion = "modulos", en = "modulos", al_cambiar = function(seccion)
        if seccion == "modulos" then
            self.ajustes = Ajustes.leer("modulos")
            self:refresh()
        elseif self.al_cambiar_ajustes then
            self.al_cambiar_ajustes(seccion)
        end
    end }
end

function Pantalla:onShow()
    UIManager:setDirty(self, "flashui")
    return true
end

function Pantalla:onCloseWidget()
    UIManager:setDirty(nil, "flashui")
end

function Pantalla:onClose()
    UIManager:close(self)
    return true
end

Diccionarios.Pantalla = Pantalla
return Diccionarios
