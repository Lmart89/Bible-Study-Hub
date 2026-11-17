--[[--
Notas para el Kindle 3, sobre bsh_k3_visor. Las notas son los .md de BSH Notes, con sus respaldos
(bsh_usuario), las mismas del PW3.

Lista: D-Pad de una nota a otra, Press la abre, Del la borra (pregunta antes). Nota abierta: D-Pad
recorre sus enlaces (la referencia abre la Biblia), Back vuelve a la lista. Menu: las acciones de
cada modo. Teclas laterales: páginas.

Notas.editar: editor con el teclado físico. Back, Home o Cancelar preguntan si guardar o
descartar los cambios; Menu ofrece guardar y la ayuda de formato.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Azw3 = require("bsh_azw3")
local DB = require("bsh_db")
local Exportar = require("bsh_exportar")
local Libros = require("bsh_libros")
local Marcas = require("bsh_marcas")
local Compartidas = require("bsh_notas")
local Visor = require("bsh_k3_visor")

local CSS = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.4; text-align: justify; }
h2 { font-size: 1.15em; margin: 0 0 0.3em 0; text-align: left; }
h3 { font-size: 1.05em; margin: 0.7em 0 0.2em 0; text-align: left; }
p { margin: 0 0 0.5em 0; }
p.aviso, p.meta { font-style: italic; text-align: left; }
p.nota { margin-bottom: 0.9em; text-align: left; }
ul { margin: 0 0 0.5em 1.2em; padding: 0; }
li { margin: 0 0 0.2em 0; }
blockquote { margin: 0.3em 0 0.5em 1em; padding-left: 0.5em; border-left: 2px solid black; font-style: italic; }
blockquote.verso { font-style: normal; }
span.res { background-color: #cccccc; }
a { color: black; text-decoration: none; }
p.meta a { text-decoration: underline; }
]]

local AUTOR = "Bible Study Hub" -- autor del libro exportado si no se escribe otro

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function avisar(texto)
    Notification:notify(texto, Notification.SOURCE_ALWAYS_SHOW)
end

local function referencia(n)
    if not n.libro then return nil end
    local ref = Libros.nombre(n.libro) .. " " .. n.capitulo
    if n.verso then ref = ref .. ":" .. n.verso end
    return ref
end

local function fecha(t)
    return t and os.date("%d/%m/%Y %H:%M", t) or ""
end

local Notas = Visor:extend{
    name = "bsh_k3_notas",
    css = CSS,
    app = nil,
    usuario = nil,
    biblia = nil,
    libro = nil, capitulo = nil, verso = nil, -- el pasaje desde el que se abre
    filtro = "ref", -- "ref" | "todas" | "busqueda"
}

--- Editor -----------------------------------------------------------------------------

--- Edita una nota (o crea una). o: { usuario, nota, libro, capitulo, verso, al_guardar(id),
-- biblia (opcional: para «Citar» el versículo de la nota) }. Como el editor del PW3: fila de
-- formato (negrita, cursiva, resaltado, título, lista, cita y ayuda) bajo el texto y en Menu.
function Notas.editar(o)
    local n = o.nota or { libro = o.libro, capitulo = o.capitulo, verso = o.verso, cuerpo = "" }
    local original = n.cuerpo or ""
    local ref = referencia(n)
    local dialogo

    local function guardar()
        local cuerpo = dialogo:getInputText():gsub("%s+$", "")
        if cuerpo:match("^%s*$") then
            avisar("La nota está vacía: no se guarda")
            return false
        end
        n.cuerpo = cuerpo
        n.titulo = Marcas.titulo(cuerpo)
        local id, err = o.usuario:guardarNota(n)
        if not id then -- el editor sigue abierto: el texto no se pierde
            UIManager:show(InfoMessage:new{ text = "No se pudo guardar la nota:\n" .. tostring(err) })
            return false
        end
        UIManager:close(dialogo)
        avisar(o.nota and "Nota guardada" or "Nota creada")
        if o.al_guardar then o.al_guardar(id) end
        return true
    end

    --- Antes de salir: sin cambios sale; con cambios pregunta. despues: lo que sigue al salir.
    local function preguntar(despues)
        local texto = dialogo:getInputText()
        if texto == original or (not o.nota and texto:match("^%s*$")) then
            UIManager:close(dialogo)
            if despues then despues() end
            return
        end
        local confirmar
        confirmar = ButtonDialog:new{
            title = "¿Guardar los cambios de esta nota?",
            title_align = "center",
            buttons = {
                { { text = "Guardar y salir", callback = function()
                    UIManager:close(confirmar)
                    if guardar() and despues then despues() end
                end } },
                { { text = "Descartar cambios", callback = function()
                    UIManager:close(confirmar)
                    UIManager:close(dialogo)
                    if despues then despues() end
                end } },
                { { text = "Seguir editando", callback = function() UIManager:close(confirmar) end } },
            },
        }
        UIManager:show(confirmar)
    end

    --- Inserta marcas donde está el cursor (con despues, el cursor queda entre las dos) y vuelve
    -- al texto, como los botones de formato del PW3.
    local function insertar(antes, despues)
        local campo = dialogo._input_widget
        campo:addChars(antes .. (despues or ""))
        for _ = 1, #(despues or "") do campo:leftChar() end
        Notas.volverAlTexto(dialogo)
    end
    -- el versículo de la nota, como cita: «> texto (Juan 3:16)»
    local verso_texto = n.verso and o.biblia and o.biblia:verso(n.libro, n.capitulo, n.verso)
    local formatos = {
        { "negrita", "Negrita", function() insertar("**", "**") end },
        { "cursiva", "Cursiva", function() insertar("*", "*") end },
        { "resaltar", "Resaltado", function() insertar("==", "==") end },
        { "titulo", "Título", function() insertar("\n# ") end },
        { "lista", "Lista", function() insertar("\n- ") end },
        { "cita", "Cita", function() insertar("\n> ") end },
    }
    if verso_texto then
        formatos[#formatos + 1] = { "versiculo", "Citar " .. ref, function()
            insertar("\n> " .. verso_texto .. " (" .. ref .. ")\n")
        end }
    end
    local function ayuda() UIManager:show(InfoMessage:new{ text = Marcas.AYUDA }) end
    -- la fila de iconos de formato del PW3 (símbolos de la fuente de iconos): D-Pad abajo desde la
    -- última línea del texto llega a ella; arriba vuelve al texto
    local barra = {}
    for _, f in ipairs(formatos) do
        barra[#barra + 1] = { text = Notas.ICONOS_FORMATO[f[1]], callback = f[3] }
    end
    barra[#barra + 1] = { text = Notas.ICONOS_FORMATO.ayuda, callback = ayuda }

    dialogo = InputDialog:new{
        title = (o.nota and "Editar nota" or "Nueva nota") .. (ref and (" · " .. ref) or " libre"),
        input = original,
        input_hint = "# Título\nEscribe aquí. **negrita**, *cursiva*, ==resaltado==",
        fullscreen = true,
        condensed = true,
        allow_newline = true,
        cursor_at_end = true,
        buttons = {
            barra,
            {
                -- «close»: también lo llama Back desde el campo de texto
                { text = "Cancelar", id = "close", callback = function() preguntar() end },
                { text = "Guardar", callback = function() guardar() end },
            },
        },
    }
    -- Home (bsh_k3_app) pregunta antes de cerrar el editor
    dialogo.pedirSalida = function(_, despues) preguntar(despues) end
    dialogo.key_events.MenuEditor = { { "Menu" } }
    dialogo.onMenuEditor = function()
        local menu
        local filas = {}
        local function opcion(texto, accion)
            filas[#filas + 1] = { { text = texto, callback = function()
                UIManager:close(menu)
                accion()
            end } }
        end
        opcion(Notas.ICONOS_FORMATO.guardar .. "   Guardar", guardar)
        -- el formato en dos columnas: el D-Pad las recorre en rejilla
        local fila = {}
        for _, f in ipairs(formatos) do
            fila[#fila + 1] = { text = Notas.ICONOS_FORMATO[f[1]] .. "  " .. f[2], callback = function()
                UIManager:close(menu)
                f[3]()
            end }
            if #fila == 2 then
                filas[#filas + 1], fila = fila, {}
            end
        end
        if #fila > 0 then filas[#filas + 1] = fila end
        opcion(Notas.ICONOS_FORMATO.ayuda .. "   Ayuda de formato", ayuda)
        opcion("Salir de la edición", function() preguntar() end)
        opcion("Seguir editando", function() Notas.volverAlTexto(dialogo) end)
        menu = ButtonDialog:new{ title = "Nota · formato", title_align = "center", buttons = filas }
        UIManager:show(menu)
        return true
    end
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

-- iconos de los botones de formato (fuente de iconos de KOReader, los mismos que en el PW3)
Notas.ICONOS_FORMATO = {
    negrita = "\u{F032}", cursiva = "\u{F033}", resaltar = "\u{F1FC}", titulo = "\u{F1DC}",
    lista = "\u{F03A}", cita = "\u{F10D}", versiculo = "\u{F02D}", ayuda = "\u{F059}", guardar = "\u{F0C7}",
}

--- Devuelve el foco del D-Pad al texto (tras un botón o el menú de formato).
function Notas.volverAlTexto(dialogo)
    local FocusManager = require("ui/widget/focusmanager")
    if dialogo.moveFocusTo then
        pcall(dialogo.moveFocusTo, dialogo, 1, 1, FocusManager.FORCED_FOCUS)
    end
end

--- Exportar a AZW3 --------------------------------------------------------------------

--- Pide un texto con el teclado físico; Press (Enter) acepta.
local function pedir(titulo, actual, boton, al_aceptar)
    local dialogo
    dialogo = InputDialog:new{
        title = titulo,
        input = actual or "",
        buttons = { {
            { text = "Cancelar", id = "close", callback = function() UIManager:close(dialogo) end },
            { text = boton, is_enter_default = true, callback = function()
                local t = dialogo:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialogo)
                al_aceptar(t)
            end },
        } },
    }
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

--- Escribe el AZW3 en documents y deja el aviso para que koreader.sh actualice la biblioteca.
local function escribirAzw3(n, cab, titulo, autor)
    local ok, datos = pcall(Azw3.construir, { id = n.id, titulo = titulo, cuerpo = n.cuerpo,
        subtitulo = cab.subtitulo, autor = autor, interlineado = cab.interlineado })
    if not ok then
        logger.warn("[BSH-K3] error al convertir la nota", n.id, datos)
        return UIManager:show(InfoMessage:new{ text = "No se pudo convertir la nota:\n" .. tostring(datos) })
    end
    local nombre = Exportar.nombre{ titulo = titulo } .. ".azw3"
    local escrito, err = Exportar.escribir(Exportar.carpetaLibros() .. "/" .. nombre, datos)
    if not escrito then
        return UIManager:show(InfoMessage:new{ text = "No se pudo guardar el archivo:\n" .. tostring(err) })
    end
    local DataStorage = require("datastorage")
    local aviso = io.open(DataStorage:getSettingsDir() .. "/bsh_k3_exportado", "w")
    if aviso then aviso:close() end
    UIManager:show(InfoMessage:new{ text = "Exportada a documents:\n" .. nombre
        .. "\n\nAparecerá en la biblioteca al salir de Bible Study Hub for K3." })
end

--- Convierte la nota a AZW3 en documents. Antes, el respaldo si cambió; luego una sola ventana
-- con el título del libro y el autor (el último autor se recuerda). D-Pad: de un campo al otro;
-- Enter en el título pasa al autor, y en el autor exporta.
function Notas.exportar(usuario, n)
    Compartidas.respaldar{ usuario = usuario, lista = { n }, al_terminar = function()
        local cab = usuario:cabecera(n.id)
        local autor = (cab.autor and cab.autor ~= "") and cab.autor
            or G_reader_settings:readSetting("bsh_autor_exportar") or AUTOR
        local dialogo
        local function exportar()
            local campos = dialogo:getFields()
            local titulo = (campos[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local nuevo = (campos[2] or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if titulo == "" then titulo = n.titulo or "Nota" end
            if nuevo == "" then nuevo = AUTOR end
            G_reader_settings:saveSetting("bsh_autor_exportar", nuevo)
            UIManager:close(dialogo)
            escribirAzw3(n, cab, titulo, nuevo)
        end
        dialogo = MultiInputDialog:new{
            title = "Exportar a AZW3",
            fields = {
                { description = "Título del libro", text = n.titulo or "", hint = "Título" },
                { description = "Autor", text = autor, hint = AUTOR },
            },
            enter_callback = function()
                if dialogo.focused_field_idx == 1 then
                    dialogo:moveFocusTo(1, 2) -- el campo del autor
                else
                    exportar()
                end
            end,
            buttons = { {
                { text = "Cancelar", id = "close", callback = function() UIManager:close(dialogo) end },
                { text = "Exportar", callback = exportar },
            } },
        }
        UIManager:show(dialogo)
        dialogo:onShowKeyboard()
    end }
end

--- Pantalla ---------------------------------------------------------------------------

function Notas:iniciar()
    -- restaurar y recuperar (los de la pantalla compartida) lo llaman sin argumentos
    self.al_cambiar = function() self:avisarCambio() end
    -- recoge lo que haya cambiado en BSH Notes desde el PC o desde otro editor
    if self.usuario:sincronizar() then self:avisarCambio() end
    self:htmlLista()
end

--- Las notas cambiaron: la Biblia de detrás vuelve a marcar sus versículos.
function Notas:avisarCambio()
    self.cambiaron = true
end

function Notas:refRango()
    local ref = Libros.nombre(self.libro) .. " " .. self.capitulo
    if self.verso then ref = ref .. ":" .. self.verso end
    return ref
end

function Notas:htmlLista()
    local lista
    if self.filtro == "busqueda" then
        lista = self.usuario:buscarNotas(DB.consulta_fts(self.consulta or ""))
        self.titulo = "«" .. self.consulta .. "» en las notas"
    elseif self.filtro == "ref" and self.libro then
        lista = self.usuario:notasDe(self.libro, self.capitulo, self.verso)
        self.titulo = "Notas de " .. self:refRango()
    else
        self.filtro = "todas"
        lista = self.usuario:todasLasNotas()
        self.titulo = "Todas las notas"
    end
    self.titulo = self.titulo .. " · " .. #lista
    local html = {}
    for _, n in ipairs(lista) do
        local extracto = Marcas.plano((n.cuerpo:gsub("^%s*[^\n]*\n?", "", 1)))
        if #extracto > 140 then extracto = extracto:sub(1, 140):gsub("[\192-\255][\128-\191]*$", "") .. "…" end
        html[#html + 1] = string.format('<p class="nota"><a href="nota://%d"><b>%s</b><br/><i>%s · %s</i>%s</a></p>',
            n.id, escapar(n.titulo), escapar(referencia(n) or "Nota libre"), fecha(n.editada),
            extracto ~= "" and ("<br/>" .. escapar(extracto)) or "")
    end
    if #lista == 0 then
        html[1] = '<p class="aviso">' .. (self.filtro == "busqueda" and "Ninguna nota contiene ese texto."
            or "No hay notas aquí. Pulsa Menu para crear una o ver todas.") .. "</p>"
    end
    self.html = table.concat(html, "\n")
    self.nota = nil
end

--- Vuelve a la lista. id: la nota que queda enfocada (si no, la primera).
function Notas:verLista(id)
    self:htmlLista()
    self:rehacer()
    if not (id and self:enfocarUri("nota://" .. id)) and #self:enlacesPagina() > 0 then
        self:enfocar(1)
    end
end

function Notas:verNota(id)
    local n = self.usuario:nota(id)
    if not n then return self:verLista() end
    local html = {}
    local ref = referencia(n)
    if ref then
        local enlace = string.format('<a href="verso://%d-%d-%d">%s</a>', n.libro, n.capitulo, n.verso or 1, escapar(ref))
        html[#html + 1] = '<p class="meta">' .. enlace .. " · editada " .. fecha(n.editada) .. "</p>"
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
    self.titulo = n.titulo
    self:rehacer()
end

function Notas:construir(pagina)
    Visor.construir(self, pagina)
    if not self.iniciada then
        self.iniciada = true
        if #self:enlacesPagina() > 0 then self.foco = nil self:enfocar(1) end
    end
end

--- Teclas -------------------------------------------------------------------------------

function Notas:init()
    Visor.init(self)
    self.key_events.Borrar = { { "Del" } }
end

function Notas:activar(uri)
    local id = (uri or ""):match("^nota://(%d+)$")
    if id then return self:verNota(tonumber(id)) end
    local b, c, v = (uri or ""):match("^verso://(%d+)%-(%d+)%-(%d+)$")
    if b then self.app:irAVerso(tonumber(b), tonumber(c), tonumber(v)) end
end

--- La nota abierta o, en la lista, la enfocada.
function Notas:notaActual()
    if self.nota then return self.nota end
    local id = (self:uriEnfocada() or ""):match("^nota://(%d+)$")
    return id and self.usuario:nota(tonumber(id))
end

function Notas:onBorrar()
    local n = self:notaActual()
    if n then self:borrar(n) end
    return true
end

--- Back: de la nota a la lista; de la lista, a la Biblia.
function Notas:onCerrar()
    if self.nota then
        self:verLista(self.nota.id)
        return true
    end
    UIManager:close(self)
    return true
end

--- Acciones ----------------------------------------------------------------------------

function Notas:nueva()
    local libre = self.filtro ~= "ref"
    Notas.editar{
        usuario = self.usuario,
        biblia = self.biblia,
        libro = not libre and self.libro or nil,
        capitulo = not libre and self.capitulo or nil,
        verso = not libre and self.verso or nil,
        al_guardar = function(id)
            self:avisarCambio()
            self:verNota(id)
        end,
    }
end

function Notas:editarNota()
    Notas.editar{
        usuario = self.usuario,
        biblia = self.biblia,
        nota = self.nota,
        al_guardar = function(id)
            self:avisarCambio()
            self:verNota(id)
        end,
    }
end

function Notas:borrar(n)
    UIManager:show(ConfirmBox:new{
        text = "¿Borrar la nota «" .. n.titulo .. "»?\nSi tiene respaldo, podrás recuperarla con «Recuperar».",
        ok_text = "Borrar",
        cancel_text = "Cancelar",
        ok_callback = function()
            self.usuario:borrarNota(n.id)
            avisar("Nota borrada")
            self:avisarCambio()
            self:verLista()
        end,
    })
end

function Notas:buscar()
    pedir("Buscar en las notas", self.consulta, "Buscar", function(t)
        if t == "" then return end
        self.consulta = t
        self.filtro = "busqueda"
        self:verLista()
    end)
end

--- Importar bosquejo de Word: el .docx llega por Wi-Fi (bsh_recibir) y se convierte en una
-- nota libre (bsh_word), que se abre para revisarla o editarla.
function Notas:importarWord()
    local DataStorage = require("datastorage")
    local Recibir = require("bsh_recibir")
    UIManager:show(Recibir:new{
        titulo = "Importar bosquejo de Word",
        detalle = "El bosquejo o sermón se convierte en una nota",
        instrucciones = "Elige allí el documento de Word (.docx). Se convierte en una nota libre que "
            .. "puedes revisar y editar.",
        pagina = {
            aceptar = ".docx",
            elegir = "Elegir el documento de Word",
            ayuda = "El bosquejo o sermón en .docx. Se importan los títulos, las listas, las citas, la "
                .. "negrita, la cursiva y el resaltado; las imágenes no.",
            recibido = "Recibido. Mira el Kindle: allí se convierte en una nota.",
            reactivar = "Notas → Menu → Importar bosquejo de Word…",
        },
        pregunta_wifi = "El Wi-Fi está apagado o sin red.\n¿Encenderlo para recibir el documento?",
        destino = DataStorage:getSettingsDir() .. "/bsh-k3-importar.docx",
        recibir = function(pantalla, ruta, nombre) self:importarDocx(pantalla, ruta, nombre) end,
    })
end

--- Convierte el .docx recibido y guarda la nota. Si falla, la pantalla sigue esperando otro.
function Notas:importarDocx(pantalla, ruta, nombre)
    pantalla:mostrar("Documento recibido. Convirtiendo…")
    UIManager:forceRePaint()
    local Word = require("bsh_word")
    local ok, r, err = pcall(Word.leer, ruta, nombre)
    os.remove(ruta)
    if not ok then
        logger.warn("[BSH-K3] error al importar el documento", r)
        r, err = nil, r
    end
    if not r then
        return pantalla:mostrar("No se pudo importar: " .. tostring(err) .. ". Puedes enviar otro documento.")
    end
    local id, e = self.usuario:guardarNota{ titulo = Marcas.titulo(r.cuerpo), cuerpo = r.cuerpo,
        subtitulo = r.subtitulo }
    if not id then return pantalla:mostrar("No se pudo guardar la nota: " .. tostring(e)) end
    pantalla:cerrarConAviso()
    self:avisarCambio()
    if self.filtro == "ref" then self.filtro = "todas" end -- es una nota libre: al volver, se ve en la lista
    self:verNota(id)
    local aviso = "Bosquejo importado como nota libre."
    if r.omitido.imagenes > 0 then
        aviso = aviso .. "\nNo se importaron " .. (r.omitido.imagenes == 1 and "1 imagen."
            or (r.omitido.imagenes .. " imágenes."))
    end
    if r.omitido.tablas > 0 then aviso = aviso .. "\nLas tablas quedaron como líneas con « · » entre celdas." end
    UIManager:show(InfoMessage:new{ text = aviso, timeout = 4 })
end

-- Restaurar y recuperar son las de la pantalla compartida: usan usuario, nota, al_cambiar y verNota
Notas.restaurar = Compartidas.Pantalla.restaurar
Notas.recuperar = Compartidas.Pantalla.recuperar

function Notas:menu()
    local dialogo
    local filas = {}
    local function opcion(texto, accion)
        filas[#filas + 1] = { { text = texto, callback = function()
            UIManager:close(dialogo)
            accion()
        end } }
    end
    local n = self.nota
    if n then
        opcion("Editar", function() self:editarNota() end)
        opcion("Exportar a AZW3…", function() Notas.exportar(self.usuario, n) end)
        opcion("Respaldar", function() Compartidas.respaldar{ usuario = self.usuario, lista = { n } } end)
        opcion("Restaurar un respaldo…", function() self:restaurar() end)
        opcion("Borrar", function() self:borrar(n) end)
        opcion("Volver a la lista", function() self:verLista(n.id) end)
    else
        local enfocada = self:notaActual()
        if enfocada then
            opcion("Abrir «" .. enfocada.titulo .. "»", function() self:verNota(enfocada.id) end)
        end
        opcion(self.libro and self.filtro == "ref" and ("Nueva nota en " .. self:refRango()) or "Nueva nota libre",
            function() self:nueva() end)
        if self.libro and self.filtro ~= "ref" then
            opcion("Solo las de " .. self:refRango(), function()
                self.filtro = "ref"
                self:verLista()
            end)
        end
        if self.filtro ~= "todas" then
            opcion("Ver todas las notas", function()
                self.filtro = "todas"
                self:verLista()
            end)
        end
        opcion("Buscar en las notas…", function() self:buscar() end)
        opcion("Importar bosquejo de Word…", function() self:importarWord() end)
        opcion("Respaldar todas", function()
            Compartidas.respaldar{ usuario = self.usuario, lista = self.usuario:todasLasNotas() }
        end)
        opcion("Recuperar una nota borrada…", function() self:recuperar() end)
    end
    opcion("Ajustes de lectura…", function() self.app:abrirAjustes("modulos") end)
    opcion("Volver a la Biblia", function() UIManager:close(self) end)
    dialogo = ButtonDialog:new{
        title = n and ("Nota · " .. n.titulo) or "Notas",
        title_align = "center",
        buttons = filas,
    }
    UIManager:show(dialogo)
end

function Notas:aplicarAjustes()
    self.ajustes = require("bsh_ajustes_lectura").leer("modulos")
    self:rehacer(true)
end

function Notas:onCloseWidget()
    Visor.onCloseWidget(self)
    if self.cambiaron and self.app and self.app.lector then self.app.lector:actualizarNotas() end
end

return Notas
