--[[--
Módulo de notas: libres o vinculadas a un versículo (o a un capítulo).

  * Notas.editar{...}: editor a pantalla completa (teclado de KOReader) con botones que
    insertan las marcas de formato (bsh_marcas)
  * Notas.Pantalla: lista (de una referencia, todas o resultado de búsqueda) → nota formateada

Las notas son archivos .md en BSH Notes, con respaldos en la base (bsh_usuario.lua).
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Notification = require("ui/widget/notification")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local Ajustes = require("bsh_ajustes_lectura")
local Azw3 = require("bsh_azw3")
local DB = require("bsh_db")
local Exportar = require("bsh_exportar")
local Libros = require("bsh_libros")
local Marcas = require("bsh_marcas")
local UI = require("bsh_ui")
local lfs = require("libs/libkoreader-lfs")
local Input = Device.input
local Screen = Device.screen

local CSS = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.4; text-align: justify; }
h2 { font-size: 1.15em; margin: 0 0 0.3em 0; text-align: left; }
h3 { font-size: 1.05em; margin: 0.7em 0 0.2em 0; text-align: left; }
p { margin: 0 0 0.5em 0; }
p.aviso, p.meta { color: #555555; font-style: italic; text-align: left; }
p.nota { margin-bottom: 0.9em; text-align: left; }
ul { margin: 0 0 0.5em 1.2em; padding: 0; }
li { margin: 0 0 0.2em 0; }
blockquote { margin: 0.3em 0 0.5em 1em; padding-left: 0.5em; border-left: 2px solid black; font-style: italic; }
blockquote.verso { font-style: normal; }
span.res { background-color: #cccccc; }
a { color: black; text-decoration: underline; }
]]

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function avisar(texto)
    Notification:notify(texto, Notification.SOURCE_ALWAYS_SHOW)
end

--- «Juan 3:16», «Juan 3» o nil (nota libre).
local function referencia(n)
    if not n.libro then return nil end
    local ref = Libros.nombre(n.libro) .. " " .. n.capitulo
    if n.verso then ref = ref .. ":" .. n.verso end
    return ref
end

local function fecha(t)
    return t and os.date("%d/%m/%Y %H:%M", t) or ""
end

--- Caracteres de un texto UTF-8: cuenta todos los bytes que no son de continuación.
local function caracteres(s)
    return select(2, (s or ""):gsub("[^\128-\191]", ""))
end

local Notas = {}

--- Nombre de icono para Button/IconWidget que apunta a un SVG del plugin.
-- IconWidget solo busca por nombre en sus carpetas (resources/icons/mdlight…); un nombre que
-- sube con «../» hasta la raíz y baja a la ruta absoluta del plugin funciona desde cualquiera
-- de ellas (en la raíz, «..» se queda en la raíz). Si no lo encuentra, KOReader muestra su
-- icono de «no encontrado», sin fallar.
local function icono(plugin_path, nombre)
    local ruta = plugin_path or ""
    if ruta:sub(1, 1) ~= "/" then
        ruta = (lfs.currentdir() or "") .. "/" .. ruta
    end
    return string.rep("../", 16) .. ruta:gsub("^/+", "") .. "/iconos/" .. nombre
end

--- Editor de una nota.
-- @param o { usuario, plugin_path, nota = nota existente o nil, libro, capitulo, verso (para una nueva),
--             al_guardar = function(id) }
function Notas.editar(o)
    local n = o.nota or { libro = o.libro, capitulo = o.capitulo, verso = o.verso, cuerpo = "" }
    local ref = referencia(n)
    local dialogo
    local tam = Screen:scaleBySize(30)
    local function boton(nombre, callback)
        return { icon = icono(o.plugin_path, nombre), icon_width = tam, icon_height = tam, callback = callback }
    end
    local function insertar(antes, despues)
        local campo = dialogo._input_widget
        campo:addChars(antes .. (despues or ""))
        for _ = 1, #(despues or "") do campo:leftChar() end
    end
    dialogo = InputDialog:new{
        title = (o.nota and "Editar nota" or "Nueva nota") .. (ref and (" · " .. ref) or " libre"),
        input = n.cuerpo,
        input_hint = "# Título\nEscribe aquí. **negrita**, *cursiva*, ==resaltado==",
        fullscreen = true,
        condensed = true,
        allow_newline = true,
        cursor_at_end = true,
        buttons = {
            -- iconos de formato: B negrita · I cursiva · A resaltado · T título · lista · « cita · ? ayuda
            {
                boton("negrita", function() insertar("**", "**") end),
                boton("cursiva", function() insertar("*", "*") end),
                boton("resaltar", function() insertar("==", "==") end),
                boton("titulo", function() insertar("\n# ") end),
                boton("lista", function() insertar("\n- ") end),
                boton("cita", function() insertar("\n> ") end),
                boton("ayuda", function() UIManager:show(InfoMessage:new{ text = Marcas.AYUDA }) end),
            },
            {
                { text = "Cancelar", id = "close", callback = function() UIManager:close(dialogo) end },
                { text = "Guardar", is_enter_default = false, callback = function()
                    local cuerpo = dialogo:getInputText():gsub("%s+$", "")
                    if cuerpo:match("^%s*$") then
                        avisar("La nota está vacía: no se guarda")
                        return
                    end
                    n.cuerpo = cuerpo
                    n.titulo = Marcas.titulo(cuerpo)
                    local id, err = o.usuario:guardarNota(n)
                    if not id then -- el editor sigue abierto: el texto no se pierde
                        UIManager:show(InfoMessage:new{ text = "No se pudo guardar la nota:\n" .. tostring(err) })
                        return
                    end
                    UIManager:close(dialogo)
                    avisar(o.nota and "Nota guardada" or "Nota creada")
                    if o.al_guardar then o.al_guardar(id) end
                end },
            },
        },
    }
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

--- Pantalla ---------------------------------------------------------------------------

local Pantalla = InputContainer:extend{
    name = "bsh_notas",
    covers_fullscreen = true,
    usuario = nil,
    plugin_path = nil,  -- para los iconos del editor
    biblia = nil,       -- DB de la Biblia (para citar el versículo en la nota)
    libro = nil, capitulo = nil, verso = nil, -- referencia desde la que se abre
    al_abrir = nil,     -- function(libro, cap, verso)
    al_cambiar = nil,   -- function(): se creó, editó o borró una nota (el lector actualiza sus marcas)
    al_cambiar_ajustes = nil, -- function(seccion): se cambiaron los ajustes de la Biblia
}

function Pantalla:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ajustes = Ajustes.leer("modulos") -- las notas usan los ajustes de «Otros módulos»
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    self.filtro = self.libro and "ref" or "todas" -- "ref" | "todas" | "busqueda"
    -- recoge lo que haya cambiado en BSH Notes desde otro editor o desde el PC
    if self.usuario:sincronizar() and self.al_cambiar then self.al_cambiar() end
    self:verLista()
    self.iniciada = true
end

function Pantalla:refRango()
    local ref = Libros.nombre(self.libro) .. " " .. self.capitulo
    if self.verso then ref = ref .. ":" .. self.verso end
    return ref
end

function Pantalla:verLista()
    local lista, titulo
    if self.filtro == "busqueda" then
        lista = self.usuario:buscarNotas(DB.consulta_fts(self.consulta or ""))
        titulo = "«" .. self.consulta .. "» en las notas"
    elseif self.filtro == "ref" then
        lista = self.usuario:notasDe(self.libro, self.capitulo, self.verso)
        titulo = "Notas de " .. self:refRango()
    else
        lista = self.usuario:todasLasNotas()
        titulo = "Todas las notas"
    end
    local html = { "<h2>" .. escapar(titulo) .. "</h2>" }
    for _, n in ipairs(lista) do
        -- extracto: el texto que sigue a la primera línea (la del título)
        local extracto = Marcas.plano((n.cuerpo:gsub("^%s*[^\n]*\n?", "", 1)))
        if #extracto > 140 then extracto = extracto:sub(1, 140):gsub("[\192-\255][\128-\191]*$", "") .. "…" end
        html[#html + 1] = string.format('<p class="nota"><a href="nota://%d"><b>%s</b></a><br/><i>%s · %s</i>%s</p>',
            n.id, escapar(n.titulo), escapar(referencia(n) or "Nota libre"), fecha(n.editada),
            extracto ~= "" and ("<br/>" .. escapar(extracto)) or "")
    end
    if #lista == 0 then
        html[#html + 1] = '<p class="aviso">' .. (self.filtro == "busqueda" and "Ninguna nota contiene ese texto."
            or "No hay notas todavía. Toca «Nueva nota».") .. "</p>"
    end
    self.html = table.concat(html, "\n")
    self.nota = nil
    self.estado = #lista .. (#lista == 1 and " nota" or " notas")
    self:refresh()
end

function Pantalla:verNota(id)
    local n = self.usuario:nota(id)
    if not n then return self:verLista() end
    local html = {}
    local ref = referencia(n)
    if ref then
        local m = string.format('<a href="verso://%d-%d-%d">%s</a>', n.libro, n.capitulo, n.verso or 1, escapar(ref))
        html[#html + 1] = '<p class="meta">' .. m .. " · editada " .. fecha(n.editada) .. "</p>"
        if n.verso and self.biblia then
            local texto = self.biblia:verso(n.libro, n.capitulo, n.verso)
            if texto then html[#html + 1] = '<blockquote class="verso">' .. escapar(texto) .. "</blockquote>" end
        end
    else
        html[#html + 1] = '<p class="meta">Nota libre · editada ' .. fecha(n.editada) .. "</p>"
    end
    html[#html + 1] = Marcas.html(n.cuerpo)
    self.html = table.concat(html, "\n")
    self.nota = n
    self.estado = n.titulo
    self:refresh()
end

function Pantalla:nueva()
    local libre = self.filtro ~= "ref"
    Notas.editar{
        usuario = self.usuario,
        plugin_path = self.plugin_path,
        libro = not libre and self.libro or nil,
        capitulo = not libre and self.capitulo or nil,
        verso = not libre and self.verso or nil,
        al_guardar = function(id)
            if self.al_cambiar then self.al_cambiar() end
            self:verNota(id)
        end,
    }
end

function Pantalla:editar()
    Notas.editar{
        usuario = self.usuario,
        plugin_path = self.plugin_path,
        nota = self.nota,
        al_guardar = function(id)
            if self.al_cambiar then self.al_cambiar() end
            self:verNota(id)
        end,
    }
end

function Pantalla:borrar()
    local n = self.nota
    UIManager:show(ConfirmBox:new{
        text = "¿Borrar la nota «" .. n.titulo .. "»?\nSi tiene respaldo, podrás recuperarla con «Recuperar».",
        ok_text = "Borrar",
        cancel_text = "Cancelar",
        ok_callback = function()
            self.usuario:borrarNota(n.id)
            avisar("Nota borrada")
            if self.al_cambiar then self.al_cambiar() end
            self:verLista()
        end,
    })
end

function Pantalla:buscar()
    local dialogo
    dialogo = InputDialog:new{
        title = "Buscar en las notas",
        input = self.consulta or "",
        input_hint = "gracia",
        buttons = {
            {
                { text = "Cancelar", id = "close", callback = function() UIManager:close(dialogo) end },
                { text = "Buscar", is_enter_default = true, callback = function()
                    local t = dialogo:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialogo)
                    if t == "" then return end
                    self.consulta = t
                    self.filtro = "busqueda"
                    self:verLista()
                end },
            },
        },
    }
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

--- Pregunta qué hacer con las notas que difieren de su último respaldo.
-- Sin cambios no pregunta. Lo usa también la exportación, antes de convertir una nota.
-- @param o { usuario, lista = notas a revisar, al_terminar = function() (opcional) }
function Notas.respaldar(o)
    local cambiadas = {}
    for _, n in ipairs(o.lista) do
        if o.usuario:cambiada(n) then cambiadas[#cambiadas + 1] = n end
    end
    if #cambiadas == 0 then
        if o.al_terminar then
            o.al_terminar()
        else
            avisar("Todo está respaldado")
        end
        return
    end
    local titulo
    if #cambiadas == 1 then
        local n = cambiadas[1]
        local r = o.usuario:respaldos(n.id)[1]
        titulo = r and string.format("Esta nota cambió desde el último respaldo\nRespaldo: %d caracteres · Actual: %d caracteres",
            caracteres(r.cuerpo), caracteres(n.cuerpo)) or "Esta nota aún no tiene respaldo"
    else
        titulo = #cambiadas .. " notas cambiaron desde su último respaldo"
    end
    local function aplicar(accion, aviso)
        return function()
            UIManager:close(o.dialogo)
            local fallos = 0
            for _, n in ipairs(cambiadas) do
                if not accion(n) then fallos = fallos + 1 end
            end
            avisar(fallos == 0 and aviso or (fallos .. " notas no se pudieron procesar"))
            if o.al_terminar then o.al_terminar() end
        end
    end
    o.dialogo = ButtonDialog:new{
        title = titulo,
        title_align = "center",
        buttons = {
            { { text = "Actualizar respaldo", callback = aplicar(function(n)
                o.usuario:respaldar(n)
                return true
            end, "Respaldo actualizado") } },
            { { text = "Conservar respaldo y crear copia", callback = aplicar(function(n)
                return o.usuario:copiaTemporal(n)
            end, "Copia guardada en BSH Notes/Copias") } },
            { { text = "Cancelar", callback = function() UIManager:close(o.dialogo) end } },
        },
    }
    UIManager:show(o.dialogo)
end

function Pantalla:respaldar(lista)
    Notas.respaldar{ usuario = self.usuario, lista = lista }
end

--- Convierte una nota a AZW3 en la carpeta de libros, tras preguntar por el respaldo si cambió.
local AUTOR = "Bible Study Hub" -- autor si no se escribe otro

local function construirAzw3(n, cab, titulo, autor)
    local ok, datos = pcall(Azw3.construir, { id = n.id, titulo = titulo, cuerpo = n.cuerpo,
        subtitulo = cab.subtitulo, autor = autor, interlineado = cab.interlineado })
    local texto
    if ok then
        local nombre = Exportar.nombre{ titulo = titulo } .. ".azw3"
        local escrito, err = Exportar.escribir(Exportar.carpetaLibros() .. "/" .. nombre, datos)
        texto = escrito and ("Exportada a documents:\n" .. nombre) or ("No se pudo guardar el archivo:\n" .. tostring(err))
    else
        logger.warn("[BSH] error al convertir la nota", n.id, datos)
        texto = "No se pudo convertir la nota:\n" .. tostring(datos)
    end
    UIManager:show(InfoMessage:new{ text = texto })
end

--- Exporta la nota a AZW3 en documents. Antes pide el título del libro (el de la nota, si no se
-- cambia) y el autor, que se recuerda para la próxima vez.
function Notas.exportarAzw3(usuario, n)
    Notas.respaldar{ usuario = usuario, lista = { n }, al_terminar = function()
        local cab = usuario:cabecera(n.id)
        local autor = (cab.autor and cab.autor ~= "") and cab.autor
            or G_reader_settings:readSetting("bsh_autor_exportar") or AUTOR
        local dialogo
        dialogo = MultiInputDialog:new{
            title = "Exportar AZW3",
            fields = {
                { description = "Título del libro", text = n.titulo or "", hint = "Título" },
                { description = "Autor", text = autor, hint = AUTOR },
            },
            buttons = { {
                { text = "Cancelar", id = "close", callback = function() UIManager:close(dialogo) end },
                { text = "Exportar", is_enter_default = true, callback = function()
                    local campos = dialogo:getFields()
                    local titulo = (campos[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    local nuevo = (campos[2] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if titulo == "" then titulo = n.titulo or "Nota" end
                    if nuevo == "" then nuevo = AUTOR end
                    G_reader_settings:saveSetting("bsh_autor_exportar", nuevo)
                    UIManager:close(dialogo)
                    construirAzw3(n, cab, titulo, nuevo)
                end },
            } },
        }
        UIManager:show(dialogo)
        dialogo:onShowKeyboard()
    end }
end

--- Elige uno de los respaldos de la nota abierta. La versión actual queda en Copias si difiere.
function Pantalla:restaurar()
    local n = self.nota
    local lista = self.usuario:respaldos(n.id)
    if #lista == 0 then
        avisar("Esta nota aún no tiene respaldo")
        return
    end
    local dialogo
    local filas = {}
    for _, r in ipairs(lista) do
        filas[#filas + 1] = { { text = fecha(r.fecha) .. " · " .. caracteres(r.cuerpo) .. " caracteres", callback = function()
            UIManager:close(dialogo)
            local id, err = self.usuario:restaurar(n, r)
            if not id then
                UIManager:show(InfoMessage:new{ text = "No se pudo restaurar:\n" .. tostring(err) })
                return
            end
            avisar("Nota restaurada")
            if self.al_cambiar then self.al_cambiar() end
            self:verNota(id)
        end } }
    end
    filas[#filas + 1] = { { text = "Cancelar", callback = function() UIManager:close(dialogo) end } }
    dialogo = ButtonDialog:new{ title = "Restaurar respaldo\nActual: " .. caracteres(n.cuerpo) .. " caracteres",
        title_align = "center", buttons = filas }
    UIManager:show(dialogo)
end

--- Notas borradas que conservan respaldo: tocar una vuelve a crear su archivo.
function Pantalla:recuperar()
    local lista = self.usuario:notasSinArchivo()
    if #lista == 0 then
        avisar("No hay notas borradas con respaldo")
        return
    end
    local dialogo
    local filas = {}
    for _, r in ipairs(lista) do
        filas[#filas + 1] = { { text = r.titulo, callback = function()
            UIManager:close(dialogo)
            local id, err = self.usuario:recuperar(r)
            if not id then
                UIManager:show(InfoMessage:new{ text = "No se pudo recuperar:\n" .. tostring(err) })
                return
            end
            avisar("Nota recuperada")
            if self.al_cambiar then self.al_cambiar() end
            self:verNota(id)
        end } }
    end
    filas[#filas + 1] = { { text = "Cancelar", callback = function() UIManager:close(dialogo) end } }
    dialogo = ButtonDialog:new{ title = "Recuperar nota borrada", title_align = "center", buttons = filas }
    UIManager:show(dialogo)
end

function Pantalla:botones()
    if self.nota then
        return {
            {
                { text = "Editar", callback = function() self:editar() end },
                { text = "Respaldar", callback = function() self:respaldar({ self.nota }) end },
                { text = "Restaurar", callback = function() self:restaurar() end },
                { text = "Borrar", callback = function() self:borrar() end },
            },
            {
                { text = "← Lista", callback = function() self:verLista() end },
                { text = "Exportar AZW3", callback = function() Notas.exportarAzw3(self.usuario, self.nota) end },
                { text = "Ajustes…", callback = function() self:abrirAjustes() end },
                { text = "Volver", callback = function() self:onClose() end },
            },
        }
    end
    local filas = {
        {
            { text = (self.filtro == "ref") and ("Nueva nota en " .. self:refRango()) or "Nueva nota libre",
              callback = function() self:nueva() end },
            { text = "Respaldar notas", callback = function() self:respaldar(self.usuario:todasLasNotas()) end },
        },
        {
            { text = "Buscar en notas…", callback = function() self:buscar() end },
            { text = "Recuperar…", callback = function() self:recuperar() end },
        },
    }
    if self.libro then
        table.insert(filas[2], 1, { text = self.filtro == "ref" and "Ver todas" or ("Solo " .. self:refRango()),
            callback = function()
                self.filtro = self.filtro == "ref" and "todas" or "ref"
                self:verLista()
            end })
    end
    filas[#filas + 1] = {
        { text = "Ajustes de lectura…", callback = function() self:abrirAjustes() end },
        { text = "Volver al texto", callback = function() self:onClose() end },
    }
    return filas
end

function Pantalla:buildLayout()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margen = Size.padding.large -- separación de los botones
    local lateral, superior, inferior = Ajustes.medidas(self.ajustes)
    local title_bar = TitleBar:new{
        width = screen_w,
        fullscreen = true,
        title = "Notas",
        subtitle = self.estado,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local botones = ButtonTable:new{ width = screen_w - 2 * margen, show_parent = self, buttons = self:botones() }
    local alto = screen_h - title_bar:getHeight() - botones:getSize().h - superior - inferior - 2 * margen
    self[1] = FrameContainer:new{
        width = screen_w, height = screen_h,
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
        VerticalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = screen_w },
            title_bar,
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
            VerticalSpan:new{ width = margen + inferior },
            botones,
        },
    }
end

function Pantalla:onEnlace(link)
    local uri = link and link.uri or ""
    local id = uri:match("^nota://(%d+)$")
    if id then
        self:verNota(tonumber(id))
        return
    end
    -- citas bíblicas (alfa 8): vista previa en una ventana flotante, sin salir de la nota
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

--- Ajustes de lectura con la sección Otros módulos: el resultado se ve aquí mismo.
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

Notas.Pantalla = Pantalla
return Notas
