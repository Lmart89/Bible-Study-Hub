--[[--
«Ajustes avanzados»: pantalla completa que se abre desde el panel lateral. Va por categorías; cada
una abre su propia pantalla (la misma clase con otra «vista») con la flecha para volver:

  * Módulos → «Administrar módulos»: los instalados por tipo y la carpeta de donde se leen.
  * Red → «Opciones de red»: encender o apagar el Wi-Fi, elegir red, ver la dirección.
  * Pantalla → «Ajustes de pantalla»: contraste, iluminación, modo nocturno y tiempo de reposo.
  * Actualizaciones por Wi-Fi (actualizar = bsh_actualizar).
  * Aplicación: tiempos, reiniciar, acerca de y salir.

Red y Pantalla solo aparecen en la app independiente (dispositivo = bsh_dispositivo), igual que las
actualizaciones; el plugin de pruebas no las tiene. Los ajustes de lectura y de fuentes están en el
panel lateral, porque se ven sobre el texto.

El Kindle 3 (bsh_k3_ajustes_avanzados) usa esta misma pantalla con el D-Pad: cada vista deja sus filas en
self.filas_menu, en orden, y las vistas se abren con la clase de quien las abre.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Conf = require("bsh_conf")
local DB = require("bsh_db")
local Registro = require("bsh_registro")
local UI = require("bsh_ui")
local Input = Device.input
local Screen = Device.screen

-- símbolos de la fuente de iconos de KOReader (nerdfonts/symbols.ttf)
local ICONOS = {
    modulos = "\u{F1C0}", red = "\u{F1EB}", pantalla = "\u{F108}", descargar = "\u{F019}",
    anterior = "\u{F1DA}", tiempos = "\u{F0E7}", reiniciar = "\u{F021}", acerca = "\u{F05A}",
    salir = "\u{F011}", carpeta = "\u{F07C}", disco = "\u{F0A0}", senal = "\u{F012}",
    contraste = "\u{F042}", luz = "\u{F185}", luna = "\u{F186}", reloj = "\u{F017}",
    biblia = "\u{F02D}", comentario = "\u{F075}", diccionario = "\u{F1AB}", subir = "\u{F093}",
    archivo = "\u{F15B}",
}
local FLECHA = "›" -- abre otra pantalla

local TITULOS = {
    modulos = "Administrar módulos",
    red = "Opciones de red",
    pantalla = "Ajustes de pantalla",
}

local Config = InputContainer:extend{
    name = "bsh_ajustes_avanzados",
    covers_fullscreen = true,
    plugin_path = nil,
    sqlite = nil,        -- versión de SQLite, para «Acerca de»
    tiempos = false,
    al_cambiar_tiempos = nil, -- function(): devuelve el valor nuevo
    al_reiniciar = nil,  -- function(): reinicia la app
    al_salir = nil,      -- function(): cierra la app
    actualizar = nil,    -- bsh_actualizar ya configurado; sin él, no hay sección de actualizaciones
    dispositivo = nil,   -- bsh_dispositivo; sin él, no hay Red ni Pantalla
    al_cambiar_pantalla = nil, -- function(): el lector vuelve a dibujar el texto (contraste)
    vista = nil,         -- nil = la principal; "modulos", "red" o "pantalla"
    padre = nil,         -- en una vista: la pantalla principal (se pone al día al volver)
}

--- «1 Biblia · 9 comentarios · 1 diccionario»
local function resumenModulos(biblias, comentarios, diccionarios)
    local function cuenta(n, uno, varios) return n .. " " .. (n == 1 and uno or varios) end
    return cuenta(biblias, "Biblia", "Biblias") .. " · " .. cuenta(comentarios, "comentario", "comentarios")
        .. " · " .. cuenta(diccionarios, "diccionario", "diccionarios")
end

function Config:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    self:construir()
end

function Config:construir()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local relleno = Size.padding.large

    local barra
    if self.vista then
        barra = UI.barra{
            texto = TITULOS[self.vista],
            show_parent = self,
            izquierda = { { icono = "chevron.left", callback = function() self:onClose() end } },
            derecha = { { icono = "close", callback = function() self:cerrarTodo() end } },
        }
    else
        barra = UI.barra{
            texto = "Ajustes avanzados",
            show_parent = self,
            derecha = { { icono = "close", callback = function() self:onClose() end } },
        }
    end
    local filas = VerticalGroup:new{ align = "left", barra }
    self.filas_menu = {} -- las filas elegibles, en orden (el Kindle 3 las recorre con el D-Pad)

    -- lo que cada vista usa para armarse
    local h = {}
    function h.seccion(texto)
        filas[#filas + 1] = FrameContainer:new{
            padding = relleno, bordersize = 0,
            TextWidget:new{ text = texto, face = Font:getFace("x_smallinfofont"), fgcolor = Blitbuffer.COLOR_DARK_GRAY },
        }
    end
    function h.linea()
        filas[#filas + 1] = LineWidget:new{ dimen = Geom:new{ w = screen_w, h = Size.line.medium }, background = Blitbuffer.COLOR_GRAY }
    end
    function h.fila(icono, texto, valor, callback)
        local fila = UI.FilaMenu:new{ icono = ICONOS[icono], texto = texto, numero = valor, ancho = screen_w,
            callback = callback }
        filas[#filas + 1] = fila
        self.filas_menu[#self.filas_menu + 1] = fila
    end
    function h.texto(t)
        filas[#filas + 1] = FrameContainer:new{
            padding = relleno, padding_top = 0, bordersize = 0,
            TextBoxWidget:new{ text = t, face = Font:getFace("cfont", 18), width = screen_w - 2 * relleno },
        }
    end

    if self.vista == "modulos" then
        self:vistaModulos(h)
    elseif self.vista == "red" then
        self:vistaRed(h)
    elseif self.vista == "pantalla" then
        self:vistaPantalla(h)
    else
        self:vistaPrincipal(h)
    end

    self[1] = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        filas,
    }
end

--- Vistas ----------------------------------------------------------------------------

function Config:vistaPrincipal(h)
    h.seccion("Módulos")
    h.fila("modulos", "Administrar módulos", FLECHA, function() self:abrirVista("modulos") end)
    local D = self.dispositivo
    if D then
        h.linea()
        h.seccion("Red")
        h.fila("red", "Opciones de red", D.estadoRed() .. "  " .. FLECHA, function() self:abrirVista("red") end)
        h.linea()
        h.seccion("Pantalla")
        h.fila("pantalla", "Ajustes de pantalla", FLECHA, function() self:abrirVista("pantalla") end)
    end
    if self.actualizar then
        local A = self.actualizar
        h.linea()
        h.seccion("Actualizaciones · versión " .. A.version())
        h.fila("descargar", "Recibir actualización por Wi-Fi…", nil, function() UIManager:show(A.Pantalla:new{}) end)
        if A.hayAnterior() then
            h.fila("anterior", "Volver a la versión anterior", nil, function() A.preguntarAnterior() end)
        end
    end
    h.linea()
    h.seccion("Aplicación")
    if self.al_cambiar_tiempos then
        h.fila("tiempos", "Tiempos", self.tiempos and "Visibles" or "Ocultos", function() self:cambiarTiempos() end)
    end
    h.fila("reiniciar", "Reiniciar", nil, function() self:reiniciar() end)
    h.fila("acerca", "Acerca de", nil, function() self:abrirAcerca() end)
    h.fila("salir", "Salir", nil, function() self:salir() end)
end

function Config:vistaModulos(h)
    local tipos = {
        { "biblia", "Biblias" }, { "comentario", "Comentarios" }, { "diccionario", "Diccionarios" },
    }
    h.seccion("Instalados")
    for _, t in ipairs(tipos) do
        local lista = Registro.lista(t[1], self.plugin_path) or {}
        h.fila(t[1], t[2], #lista, function() self:mostrarModulos(t[2], lista) end)
    end
    h.linea()
    h.seccion("Importar a la carpeta de módulos")
    h.fila("subir", "Importar por Wi-Fi…", nil, function() self:importarWifi() end)
    h.fila("archivo", "Importar desde el Kindle…", nil, function() self:importarKindle() end)
    h.linea()
    h.seccion("Carpeta de módulos")
    h.texto(Conf.carpetaModulos(self.plugin_path))
    local propia = Conf.leer().carpeta_modulos
    h.fila("carpeta", "Elegir otra carpeta…", nil, function() self:elegirCarpeta(propia) end)
    if propia then -- sin carpeta propia, ya se usa la de la app
        h.fila("disco", "Usar la carpeta de la app", nil, function() self:usarCarpeta(nil) end)
    end
    h.seccion("Al cambiar de carpeta, la app se reinicia y comprueba los módulos.")
end

function Config:vistaRed(h)
    local D = self.dispositivo
    local estado, encendido = D.estadoRed()
    h.seccion("Wi-Fi")
    h.fila("red", encendido and "Apagar el Wi-Fi" or "Encender el Wi-Fi", estado, function()
        D.cambiarWifi(function() self:alCambiarRed() end)
        self:alCambiarRed()
    end)
    h.fila("senal", "Elegir red Wi-Fi…", nil, function()
        D.elegirRed(function() self:alCambiarRed() end)
    end)
    h.fila("acerca", "Información de la red", nil, function()
        UIManager:show(InfoMessage:new{ text = D.infoRed() })
    end)
    h.linea()
    h.seccion("El Wi-Fi gasta batería: apágalo cuando no lo uses.")
end

function Config:vistaPantalla(h)
    local D = self.dispositivo
    local _, contraste = D.contraste()
    h.seccion("Texto")
    h.fila("contraste", "Contraste", contraste.nombre, function() self:elegirContraste() end)
    h.fila("luna", "Modo nocturno", D.nocturno() and "Activado" or "Desactivado", function()
        D.cambiarNocturno()
        self:rehacer()
    end)
    if D.hayLuz() then
        h.linea()
        h.seccion("Iluminación")
        h.fila("luz", "Luz de la pantalla…", D.textoLuz(), function()
            D.mostrarLuz(function() self:rehacer() end)
        end)
    end
    h.linea()
    h.seccion("Reposo")
    h.fila("reloj", "Tiempo antes del reposo", D.textoReposo(), function() self:elegirReposo() end)
end

--- Navegación ----------------------------------------------------------------------

function Config:abrirVista(vista)
    -- con la clase de esta pantalla: en el Kindle 3, la de bsh_k3_ajustes_avanzados
    UIManager:show(getmetatable(self):new{
        plugin_path = self.plugin_path,
        dispositivo = self.dispositivo,
        al_reiniciar = self.al_reiniciar,
        al_cambiar_pantalla = self.al_cambiar_pantalla,
        vista = vista,
        padre = self,
    })
end

--- La ✕ de una vista cierra también la principal: vuelve al lector.
function Config:cerrarTodo()
    UIManager:close(self)
    if self.padre then UIManager:close(self.padre) end
end

function Config:rehacer()
    self:free()
    self:construir()
    UIManager:setDirty(self, "ui")
end

--- Módulos -----------------------------------------------------------------------------

function Config:mostrarModulos(titulo, lista)
    local lineas = { titulo .. ":" }
    for _, m in ipairs(lista) do
        lineas[#lineas + 1] = "• " .. m.nombre .. (m.archivo and m.archivo ~= m.nombre and "  (" .. m.archivo .. ")" or "")
    end
    if #lista == 0 then lineas[#lineas + 1] = "(ninguno)" end
    UIManager:show(InfoMessage:new{ text = table.concat(lineas, "\n"), show_icon = false })
end

--- Selector de carpetas de KOReader: se elige con una pulsación larga.
function Config:elegirCarpeta(actual)
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        title = "Mantén pulsada la carpeta para elegirla",
        select_file = false,
        path = actual or Conf.carpetaModulos(self.plugin_path),
        file_filter = function(archivo) return archivo:lower():match("%.eb[bcd]$") ~= nil end,
        onConfirm = function(ruta) self:confirmarCarpeta(ruta) end,
    })
end

--- Revisa la carpeta elegida antes de guardarla: sin Biblia la app no podría abrir.
function Config:confirmarCarpeta(ruta)
    local hallados = Registro.explorar(ruta)
    if #hallados.biblia == 0 then
        UIManager:show(InfoMessage:new{ text = "Esa carpeta no tiene ninguna Biblia (.ebb):\n" .. ruta })
        return
    end
    local dialogo
    dialogo = ButtonDialog:new{
        title = ruta .. "\n" .. resumenModulos(#hallados.biblia, #hallados.comentario, #hallados.diccionario),
        title_align = "center",
        info_face = Font:getFace("x_smallinfofont"),
        buttons = {
            { { text = "Usar y reiniciar", callback = function()
                UIManager:close(dialogo)
                self:usarCarpeta(ruta)
            end } },
            { { text = "Cancelar", callback = function() UIManager:close(dialogo) end } },
        },
    }
    UIManager:show(dialogo)
end

--- Importar módulos -----------------------------------------------------------------------

--- Por Wi-Fi: la página web recibe uno o varios módulos, uno tras otro; cada uno se comprueba y se
-- copia al llegar. Al tocar «Listo», si se importó alguno, ofrece reiniciar para cargarlos.
function Config:importarWifi()
    local DataStorage = require("datastorage")
    local Importar = require("bsh_importar")
    local Recibir = require("bsh_recibir")
    local carpeta = Conf.carpetaModulos(self.plugin_path)
    local importados = {}
    UIManager:show(Recibir:new{
        titulo = "Importar módulos",
        detalle = "Se copian a la carpeta de módulos de la app.",
        instrucciones = "Elige allí un módulo (.ebb, .ebc o .ebd). Puedes enviar varios, uno tras otro; "
            .. "al terminar, toca Listo.",
        boton = "Listo",
        pagina = {
            aceptar = "", -- cualquier archivo: el celular no conoce estas extensiones; se revisa en el Kindle
            elegir = "Elegir un módulo",
            ayuda = Importar.AYUDA .. " Hasta 64 MB cada uno; puedes elegir varios a la vez.",
            recibido = "Recibido. Mira el Kindle; puedes enviar otro módulo.",
            varios = true,
            reactivar = "Ajustes avanzados → Administrar módulos → Importar por Wi-Fi…",
        },
        destino = DataStorage:getSettingsDir() .. "/bsh-modulo-importar.tmp",
        recibir = function(pantalla, ruta, nombre)
            -- primero se muestra el paso (en el Kindle y en la página) y luego se comprueba y copia
            pantalla.en_proceso = true
            pantalla:avance("Comprobando «" .. tostring(nombre) .. "»…", 30)
            UIManager:scheduleIn(0.05, function()
                local ok, r, err = pcall(Importar.instalar, ruta, nombre, carpeta, true)
                os.remove(ruta)
                if not ok or not r then
                    return pantalla:terminar("No se importó. " .. tostring(ok and err or r), false)
                end
                importados[#importados + 1] = r
                pantalla:terminar("Importado: " .. Importar.describir(r) .. ". Puedes enviar otro o tocar Listo.", true)
            end)
        end,
        al_cerrar = function() self:alImportar(importados) end,
    })
end

--- Desde un archivo del Kindle (p. ej. copiado por USB a documents): se elige con una pulsación
-- larga y se copia; el original queda donde estaba.
function Config:importarKindle()
    local PathChooser = require("ui/widget/pathchooser")
    local Importar = require("bsh_importar")
    local inicio = Device.home_dir and (Device.home_dir .. "/documents") or Conf.carpetaModulos(self.plugin_path)
    UIManager:show(PathChooser:new{
        title = self.titulo_importar or "Mantén pulsado el módulo para importarlo",
        select_file = true,
        select_directory = false,
        path = inicio,
        file_filter = function(archivo) return Importar.tipo(archivo) ~= nil end,
        onConfirm = function(ruta)
            local archivo = ruta:match("[^/]+$")
            local r, err = Importar.instalar(ruta, archivo, Conf.carpetaModulos(self.plugin_path), false)
            if not r then
                UIManager:show(InfoMessage:new{ text = err })
                return
            end
            self:alImportar({ r })
        end,
    })
end

--- Tras importar: la lista y la opción de reiniciar ya para que la app cargue los módulos nuevos.
function Config:alImportar(importados)
    if #importados == 0 then return end
    local Importar = require("bsh_importar")
    local lineas = { #importados == 1 and "Se importó:" or ("Se importaron " .. #importados .. " módulos:") }
    for _, r in ipairs(importados) do lineas[#lineas + 1] = "• " .. Importar.describir(r) end
    lineas[#lineas + 1] = "\nLa app se reinicia para cargarlos."
    UIManager:show(ConfirmBox:new{
        text = table.concat(lineas, "\n"),
        ok_text = "Reiniciar",
        cancel_text = "Más tarde",
        ok_callback = function() self:reiniciar() end,
    })
end

--- Guarda la carpeta en bsh.conf (nil = la de la app) y reinicia para aplicarla.
function Config:usarCarpeta(ruta)
    if not Conf.guardar("carpeta_modulos", ruta) then
        UIManager:show(InfoMessage:new{ text = "No se pudo guardar bsh.conf." })
        return
    end
    self:reiniciar()
end

--- Red y pantalla ----------------------------------------------------------------------

--- El Wi-Fi cambió (o va cambiando): rehace esta vista y la fila de la principal.
function Config:alCambiarRed()
    self:rehacer()
    if self.padre then self.padre:rehacer() end
end

--- Diálogo de opciones: { { texto, valor } }, marca la actual con «✓».
local function elegir(titulo, opciones, actual, al_elegir)
    local dialogo
    local botones = {}
    for _, o in ipairs(opciones) do
        botones[#botones + 1] = { {
            text = (o[2] == actual and "✓  " or "") .. o[1],
            callback = function()
                UIManager:close(dialogo)
                al_elegir(o[2])
            end,
        } }
    end
    dialogo = ButtonDialog:new{ title = titulo, title_align = "center", buttons = botones }
    UIManager:show(dialogo)
end

function Config:elegirContraste()
    local D = self.dispositivo
    local opciones = {}
    for i, c in ipairs(D.CONTRASTES) do opciones[i] = { c.nombre, i } end
    elegir("Contraste del texto", opciones, (D.contraste()), function(i)
        D.fijarContraste(i)
        if self.al_cambiar_pantalla then self.al_cambiar_pantalla() end
        self:rehacer()
    end)
end

function Config:elegirReposo()
    local D = self.dispositivo
    local opciones = {}
    for i, m in ipairs(D.REPOSOS) do opciones[i] = { D.textoReposo(m), m } end
    elegir("Tiempo sin usar el Kindle antes del reposo", opciones, D.reposo(), function(m)
        D.fijarReposo(m)
        self:rehacer()
    end)
end

--- Aplicación ----------------------------------------------------------------------------

function Config:cambiarTiempos()
    self.tiempos = self.al_cambiar_tiempos()
    self:rehacer()
end

function Config:reiniciar()
    UIManager:close(self)
    if self.padre then UIManager:close(self.padre) end
    self.al_reiniciar()
end

function Config:salir()
    UIManager:show(ConfirmBox:new{
        text = "¿Confirma que desea salir?",
        ok_text = "Salir",
        cancel_text = "Cancelar",
        ok_callback = function()
            UIManager:close(self)
            self.al_salir()
        end,
    })
end

function Config:abrirAcerca()
    local Acerca = require("bsh_acerca")
    local biblia = Registro.lista("biblia", self.plugin_path)
    local comentarios = Registro.lista("comentario", self.plugin_path)
    local diccionarios = Registro.lista("diccionario", self.plugin_path)
    local datos = {
        { "Módulos", resumenModulos(#biblia, #comentarios, #diccionarios) },
        { "Carpeta de módulos", Conf.carpetaModulos(self.plugin_path) },
        { "Formato de módulos", tostring(DB.FORMATO) },
    }
    if self.sqlite then datos[#datos + 1] = { "SQLite", self.sqlite } end
    local ok, version = pcall(function() return require("version"):getCurrentRevision() end)
    if ok and version then datos[#datos + 1] = { "KOReader", version } end
    local o = { plugin_path = self.plugin_path, datos = datos }
    for k, v in pairs(self.acerca or {}) do o[k] = v end -- lo propio de cada app (Kindle 3)
    UIManager:show(Acerca:new(o))
end

function Config:onShow()
    UIManager:setDirty(self, "flashui")
    return true
end

function Config:onCloseWidget()
    UIManager:setDirty(nil, "flashui")
end

-- KOReader avisa a todas las pantallas cuando la red cambia
function Config:onNetworkConnected()
    if self.dispositivo and self.vista ~= "modulos" and self.vista ~= "pantalla" then self:rehacer() end
end
Config.onNetworkDisconnected = Config.onNetworkConnected

function Config:onClose()
    UIManager:close(self)
    return true
end

return Config
