--[[--
BSH - K3: Bible Study Hub para el Kindle 3, sin el gestor de archivos de KOReader. reader.lua
llama a App:abrir(); al cerrarse la última pantalla, UIManager termina y koreader.sh devuelve el
Kindle a su inicio.

Nombres de los módulos: bsh_* es el núcleo común con el PW3 (bsh_db, bsh_libros, bsh_notas…),
bsh_k3_* la capa propia del Kindle 3 y bsh_pw3_* la del PW3.

La app abre todas las pantallas desde aquí, para que Home (bsh_k3_teclas) sepa volver a la Biblia:
cierra lo que haya encima del lector, salvo una nota en edición, que antes pregunta (pedirSalida).
--]]--

local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Ajustes = require("bsh_ajustes_lectura")
local Libros = require("bsh_libros")
local Registro = require("bsh_registro")
local Teclas = require("bsh_k3_teclas")

local App = {
    path = "app",
    lector = nil,
}

-- Iconos del panel: símbolos de la fuente de iconos de KOReader (nerdfonts/symbols.ttf), que los
-- botones usan como respaldo. Así cada opción sigue siendo un botón con foco para el D-Pad.
local ICONOS = {
    comentario = "\u{F075}", diccionario = "\u{F02D}", notas = "\u{F249}", nueva = "\u{F044}",
    estrella = "\u{F005}", copiar = "\u{F0C5}", pasaje = "\u{F0CA}", buscar = "\u{F002}",
    favoritos = "\u{F02E}", todas = "\u{F07C}", lectura = "\u{F036}", letra = "\u{F031}",
    engranaje = "\u{F013}", salir = "\u{F011}",
}

--- Pantalla de reposo: el logo con «Bible Study Hub for Kindle 3» (app/suspension/suspension.svg,
-- de tools/suspension_k3.py) y, debajo, el recuadro «Kindle en suspensión» de KOReader. Son ajustes
-- de la configuración propia de la app (bsh-k3/settings.reader.lua), no los de KOReader.
local REPOSO = {
    screensaver_type = "random_image", -- una imagen de screensaver_dir: la única que hay
    screensaver_img_background = "white",
    screensaver_stretch_images = false,
    screensaver_cycle_images_alphabetically = false,
    screensaver_show_message = true,
    screensaver_message = "Kindle en suspensión",
    screensaver_message_container = "box",
    screensaver_message_vertical_position = 30, -- % desde abajo: justo bajo «for Kindle 3»
    screensaver_message_alpha = 100,
}

function App:configurarReposo()
    local lfs = require("libs/libkoreader-lfs")
    for clave, valor in pairs(REPOSO) do G_reader_settings:saveSetting(clave, valor) end
    G_reader_settings:saveSetting("screensaver_dir", lfs.currentdir() .. "/" .. self.path .. "/suspension")
end

function App:abrir()
    -- de la 1.7 o anterior: datos, ajustes y módulos pasan a los nombres actuales (bsh_migracion)
    require("bsh_migracion").ejecutar{ limpiar_app = true }
    self:configurarReposo()
    -- contraste del texto y tiempo antes del reposo (Ajustes avanzados → Ajustes de pantalla)
    require("bsh_dispositivo").iniciar()
    -- actualizaciones por Wi-Fi (módulo común con el PW3): nombre, paquetes bsh-k3-…tar y reinicio
    require("bsh_actualizar").configurar{ nombre = "Bible Study Hub for K3", prefijo = "bsh-k3",
        reiniciar = function() self:reiniciarKOReader() end }
    Teclas.activar{
        al_inicio = function() self:irAInicio() end,
        al_emergencia = function() self:emergencia() end,
    }
    local Carga = require("bsh_carga")
    UIManager:show(Carga:new{
        plugin_path = self.path,
        al_terminar = function() self:abrirLector() end,
    })
end

function App:abrirLector()
    local Lector = require("bsh_k3_lector")
    self.lector = Lector:new{ plugin_path = self.path, app = self }
    UIManager:show(self.lector)
end

--- El lector se cerró: la app termina (salvo al reiniciar).
function App:alCerrarLector()
    self.lector = nil
    if not self.reiniciando then Teclas.desactivar() end
end

--- Home: cierra todo lo que haya encima de la Biblia.
function App:irAInicio()
    if not self.lector then return end
    local top = UIManager:getNthTopWidget()
    while top and top ~= self.lector do
        if top.pedirSalida then -- una nota en edición: pregunta y vuelve a intentarlo
            return top:pedirSalida(function() self:irAInicio() end)
        end
        UIManager:close(top)
        top = UIManager:getNthTopWidget()
    end
    UIManager:setDirty(self.lector, "flashui")
end

--- Back mantenido: sale sin preguntar. Solo guarda la posición y cierra las bases.
function App:emergencia()
    logger.warn("[BSH-K3] cierre de emergencia")
    Teclas.desactivar()
    if self.lector then pcall(self.lector.cerrarBases, self.lector) end
    UIManager:quit(0)
end

--- Reinicia la app entera (lo usa una actualización): guarda la posición, cierra las bases y sale
-- con el código 85, con el que koreader.sh vuelve a abrir reader.lua con los archivos nuevos.
function App:reiniciarKOReader()
    Teclas.desactivar()
    if self.lector then pcall(self.lector.cerrarBases, self.lector) end
    UIManager:restartKOReader()
end

--- Vuelve a la pantalla de carga con todo cerrado y comprueba de nuevo los módulos.
function App:reiniciar()
    Registro.olvidar()
    self.reiniciando = true
    local top = UIManager:getNthTopWidget()
    while top do
        UIManager:close(top)
        top = UIManager:getNthTopWidget()
    end
    self.reiniciando = false
    self:abrir()
end

--- Abre un versículo en la Biblia, cerrando lo que haya encima (desde comentarios, notas…).
function App:irAVerso(libro, cap, verso)
    self:irAInicio()
    if self.lector then self.lector:irA(libro, cap, verso) end
end

--- Panel lateral ------------------------------------------------------------------------

function App:abrirPanel()
    local l = self.lector
    local c = l:conteoModulos()
    local ref = l:referencia()
    local notas = l.usuario and l.usuario:contarNotas(l.libro, l.cap, l.verso_sel) or 0
    local opciones = {}
    local function opcion(icono, texto, accion) opciones[#opciones + 1] = { ICONOS[icono] .. "   " .. texto, accion } end
    opcion("comentario", "Comentario · " .. tostring(c.total_comentarios), function() self:abrirComentario() end)
    opcion("diccionario", "Diccionario · " .. #c.palabras, function() self:abrirDiccionario() end)
    opcion("notas", "Notas · " .. notas, function() self:abrirNotas("ref") end)
    opcion("nueva", "Nueva nota en " .. ref, function() self:nuevaNota() end)
    if l.verso_sel then
        opcion("estrella", "Guardar en favoritos", function() self:guardarFavorito() end)
        opcion("copiar", "Copiar el versículo", function() l:copiar() end)
    end
    opcion("pasaje", "Ir a pasaje…", function() self:abrirSelector() end)
    opcion("buscar", "Buscar en la Biblia…", function() self:pedirBusqueda() end)
    opcion("favoritos", "Favoritos", function() self:abrirFavoritos() end)
    opcion("todas", "Todas las notas", function() self:abrirNotas("todas") end)
    opcion("lectura", "Ajustes de lectura…", function() self:abrirAjustes() end)
    opcion("letra", "Tipo de letra…", function() self:abrirFuentes() end)
    opcion("engranaje", "Ajustes avanzados…", function() self:abrirConfig() end)
    opcion("salir", "Salir", function() l:onCerrar() end)
    local Panel = require("bsh_k3_panel")
    UIManager:show(Panel:new{ titulo = "Para " .. ref, opciones = opciones, arriba = l.alto_barra },
        nil, nil, 0, l.alto_barra)
end

--- Pantallas -----------------------------------------------------------------------------

function App:abrirComentario()
    local l = self.lector
    local c = l:conteoModulos()
    local Comentario = require("bsh_k3_comentario")
    UIManager:show(Comentario:new{
        plugin_path = self.path, app = self, biblia = l.db,
        libro = l.libro, cap = l.cap, verso = l.verso_sel, lista = c.comentarios,
    })
end

function App:abrirDiccionario()
    local l = self.lector
    local c = l:conteoModulos()
    local Diccionario = require("bsh_k3_diccionario")
    UIManager:show(Diccionario:new{
        plugin_path = self.path, app = self, biblia = l.db,
        ref = l:referencia(), palabras = c.palabras, lista = c.diccionarios,
    })
end

--- filtro: «ref» (las notas del pasaje) o «todas».
function App:abrirNotas(filtro)
    local l = self.lector
    if not l.usuario then return end
    local Notas = require("bsh_k3_notas")
    UIManager:show(Notas:new{
        app = self, usuario = l.usuario, biblia = l.db,
        libro = l.libro, capitulo = l.cap, verso = l.verso_sel, filtro = filtro,
    })
end

function App:nuevaNota()
    local l = self.lector
    if not l.usuario then return end
    require("bsh_k3_notas").editar{
        app = self, usuario = l.usuario, biblia = l.db,
        libro = l.libro, capitulo = l.cap, verso = l.verso_sel,
        al_guardar = function() l:actualizarNotas() end,
    }
end

function App:guardarFavorito()
    local l = self.lector
    require("bsh_favoritos").dialogo{
        usuario = l.usuario, libro = l.libro, cap = l.cap, verso = l.verso_sel,
    }
end

function App:abrirFavoritos()
    local l = self.lector
    local Favoritos = require("bsh_k3_favoritos")
    UIManager:show(Favoritos:new{ app = self, usuario = l.usuario, db = l.db })
end

function App:abrirSelector()
    local l = self.lector
    if not l.db then return end
    local Selector = require("bsh_k3_selector")
    UIManager:show(Selector:new{
        db = l.db, libro = l.libro, cap = l.cap,
        al_elegir = function(libro, cap, verso) l:irA(libro, cap, verso) end,
    })
end

--- Búsqueda: dónde (Libros.GRUPOS) y cómo (DB.MODOS), como en el PW3 -----------------------

local AJUSTE_BUSQUEDA = "bsh_busqueda" -- { rango, desde, hasta, modo }; se recuerda

function App:busqueda()
    self._busqueda = self._busqueda or G_reader_settings:readSetting(AJUSTE_BUSQUEDA) or { rango = "toda", modo = "todas" }
    return self._busqueda
end

function App:guardarBusqueda()
    G_reader_settings:saveSetting(AJUSTE_BUSQUEDA, self:busqueda())
end

--- Nombre, primer y último libro de dónde se busca.
function App:rangoBusqueda()
    local b = self:busqueda()
    return Libros.rango(b.rango, self.lector and self.lector.libro, b.desde, b.hasta)
end

--- Cuadro de búsqueda: el texto y, debajo (D-Pad abajo desde el texto), «Dónde» y «Cómo». Al
-- cambiar una opción el cuadro vuelve con lo escrito. Enter busca.
function App:pedirBusqueda(actual)
    local l = self.lector
    if not l.db then return end
    local DB = require("bsh_db")
    local modo = DB.modo(self:busqueda().modo)
    local dialogo
    local function reabrir(elegir)
        local escrito = dialogo:getInputText()
        UIManager:close(dialogo)
        local volver = function() self:pedirBusqueda(escrito) end
        elegir(self, volver, volver)
    end
    dialogo = InputDialog:new{
        title = "Buscar en la Biblia",
        description = modo.ayuda .. "\nD-Pad abajo: dónde y cómo buscar.",
        input = actual or self.consulta or "",
        input_hint = "amor",
        buttons = {
            { { text = "Dónde: " .. (self:rangoBusqueda()) .. "  ▾", callback = function() reabrir(self.elegirRango) end } },
            { { text = "Cómo: " .. modo.nombre .. "  ▾", callback = function() reabrir(self.elegirModo) end } },
            {
                { text = "Cancelar", id = "close", callback = function() UIManager:close(dialogo) end },
                { text = "Buscar", is_enter_default = true, callback = function()
                    local texto = dialogo:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    if texto == "" then return end
                    UIManager:close(dialogo)
                    self:abrirResultados(texto)
                end },
            },
        },
    }
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

function App:abrirResultados(texto)
    local l = self.lector
    self.consulta = texto
    local Busqueda = require("bsh_k3_busqueda")
    UIManager:show(Busqueda:new{ app = self, db = l.db, libro = l.libro, consulta = texto })
end

--- Lista de opciones con ✓ en la actual. opciones: { {texto, actual, al_tocar}, …, columnas = n }
local function elegirEn(titulo, opciones, al_cancelar)
    local ButtonDialog = require("ui/widget/buttondialog")
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
    filas[#filas + 1] = { { text = "Cancelar", callback = function()
        UIManager:close(dialogo)
        if al_cancelar then al_cancelar() end
    end } }
    -- Back también cancela (y así vuelve el cuadro de búsqueda con lo escrito)
    dialogo = ButtonDialog:new{ title = titulo, title_align = "center", buttons = filas, tap_close_callback = al_cancelar }
    UIManager:show(dialogo)
    return dialogo
end

--- Dónde buscar: grupos de libros, el libro actual o un tramo «desde … hasta …».
function App:elegirRango(al_elegir, al_cancelar)
    local b = self:busqueda()
    local libro = self.lector and self.lector.libro
    local opciones = {}
    for _, g in ipairs(Libros.GRUPOS) do
        local texto = g.nombre
        if g.id == "actual" then
            texto = "Libro actual: " .. Libros.nombre(libro)
        elseif g.id == "libros" and b.rango == "libros" then
            texto = (Libros.rango("libros", nil, b.desde, b.hasta)) .. "…"
        end
        opciones[#opciones + 1] = { texto = texto, actual = g.id == b.rango, al_tocar = function()
            if g.id == "libros" then return self:elegirLibros(al_elegir, al_cancelar) end
            b.rango = g.id
            self:guardarBusqueda()
            al_elegir()
        end }
    end
    elegirEn("Dónde buscar", opciones, al_cancelar)
end

--- Tramo de libros: primero desde cuál y luego hasta cuál (el mismo para buscar solo en uno).
function App:elegirLibros(al_elegir, al_cancelar)
    local Selector = require("bsh_k3_selector")
    UIManager:show(Selector:new{
        solo_libro = true,
        titulo = "Buscar desde el libro…",
        al_cancelar = al_cancelar,
        al_elegir = function(desde)
            UIManager:show(Selector:new{
                solo_libro = true,
                titulo = "…hasta el libro (" .. Libros.abreviatura(desde) .. " o uno posterior)",
                libro_min = desde,
                libro = desde,
                al_cancelar = al_cancelar,
                al_elegir = function(hasta)
                    local b = self:busqueda()
                    b.rango, b.desde, b.hasta = "libros", desde, hasta
                    self:guardarBusqueda()
                    al_elegir()
                end,
            })
        end,
    })
end

--- Cómo buscar: los modos, uno por fila; su explicación sale en el cuadro.
function App:elegirModo(al_elegir, al_cancelar)
    local DB = require("bsh_db")
    local b = self:busqueda()
    local opciones = { columnas = 1 }
    for _, m in ipairs(DB.MODOS) do
        opciones[#opciones + 1] = { texto = m.nombre, actual = m.id == b.modo, al_tocar = function()
            b.modo = m.id
            self:guardarBusqueda()
            al_elegir()
        end }
    end
    elegirEn("Cómo buscar", opciones, al_cancelar)
end

function App:abrirAjustes(seccion)
    Ajustes.dialogo{ seccion = seccion or "biblia", en = seccion or "biblia", al_cambiar = function(cambiada)
        self:ajustesCambiados(cambiada)
    end }
end

function App:abrirFuentes(seccion)
    Ajustes.dialogoFuentes{ seccion = seccion or "biblia", en = seccion or "biblia", al_cambiar = function(cambiada)
        self:ajustesCambiados(cambiada)
    end }
end

--- Rehace la pantalla que usa esos ajustes: la Biblia o, con «modulos», la que esté encima.
function App:ajustesCambiados(seccion)
    if seccion == "biblia" then
        if self.lector then self.lector:aplicarAjustes() end
        return
    end
    local top = UIManager:getNthTopWidget()
    local n = 1
    while top and top ~= self.lector do
        if top.aplicarAjustes then return top:aplicarAjustes() end
        n = n + 1
        top = UIManager:getNthTopWidget(n)
    end
end

function App:abrirConfig()
    require("bsh_k3_ajustes_avanzados").mostrar(self)
end

--- El contraste cambió: se vuelven a dibujar la Biblia y los visores abiertos (comentario,
-- notas…); los ajustes de encima se ven al volver.
function App:pantallaCambiada()
    local n = 1
    local w = UIManager:getNthTopWidget(n)
    while w do
        if w.html_widget and w.rehacer then w:rehacer(true) end
        n = n + 1
        w = UIManager:getNthTopWidget(n)
    end
end

--- Nombre corto de un pasaje, para títulos.
function App.ref(libro, cap, verso)
    return Libros.nombre(libro) .. " " .. cap .. (verso and (":" .. verso) or "")
end

return App
