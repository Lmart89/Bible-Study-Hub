--[[--
Lector de la Biblia para el Kindle 3: la pantalla principal («home») de BSH - K3.

  * D-Pad: versículo anterior o siguiente (y los enlaces del final: capítulo anterior, arriba,
    siguiente). El capítulo se maqueta una sola vez; el resaltado se pinta encima (bsh_k3_visor).
  * Teclas laterales: página siguiente o anterior; pasada la última página, el capítulo siguiente,
    y antes de la primera, el anterior (en su última página).
  * Press: con un versículo resaltado abre el panel para ese versículo; sobre «‹ Jn 2» o «Jn 4 ›»,
    cambia de capítulo.
  * Menu: el panel lateral (bsh_k3_panel). Back: pregunta si salir.
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local Conf = require("bsh_conf")
local DB = require("bsh_db")
local Libros = require("bsh_libros")
local Registro = require("bsh_registro")
local Usuario = require("bsh_usuario")
local Visor = require("bsh_k3_visor")

local CSS = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.45; text-align: justify; }
h2 { font-size: 1.1em; margin: 0 0 0.5em 0; text-align: left; }
p { margin: 0 0 0.5em 0; }
a { color: black; text-decoration: none; }
* { color: #000000 !important; }
p.finp { margin-bottom: 1em; }
span.mn { font-size: 0.75em; }
p.nav { text-align: center; margin-top: 1.2em; padding-top: 0.5em; border-top: 1px solid black; }
p.nav a { text-decoration: underline; }
]]

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function avisar(texto)
    Notification:notify(texto, Notification.SOURCE_ALWAYS_SHOW)
end

local Lector = Visor:extend{
    name = "bsh_k3_lector",
    seccion_ajustes = "biblia",
    css = CSS,
    plugin_path = nil,
    app = nil, -- bsh_k3_app: abre las demás pantallas
}

--- Atajos de letra del teclado: G ir a pasaje, S buscar, F favoritos, N notas del pasaje.
function Lector:init()
    Visor.init(self)
    if self.key_events then
        self.key_events.IrAPasaje = { { "G" } }
        self.key_events.Buscar = { { "S" } }
        self.key_events.VerFavoritos = { { "F" } }
        self.key_events.VerNotas = { { "N" } }
    end
end

function Lector:onIrAPasaje() if self.db then self.app:abrirSelector() end return true end
function Lector:onBuscar() if self.db then self.app:pedirBusqueda() end return true end
function Lector:onVerFavoritos() if self.db then self.app:abrirFavoritos() end return true end
function Lector:onVerNotas() if self.db then self.app:abrirNotas("ref") end return true end

function Lector:iniciar()
    local pos = G_reader_settings:readSetting("bsh_pos") or { 43, 3 }
    self.libro, self.cap = pos[1], pos[2]
    self.conteos = {} -- comentarios y diccionario por pasaje ya consultado
    self.n_conteos = 0
    self.usuario = Usuario.abrir()
    self.ruta_db = Registro.rutaBiblia(self.plugin_path)
    local db, err
    if self.ruta_db then
        db, err = DB.abrir(self.ruta_db)
    else
        err = "No hay ninguna Biblia .ebb válida en la carpeta de módulos. Cámbiala en Menu → Ajustes avanzados."
    end
    if not db then
        self.titulo = "Biblia"
        self.html = "<h2>No se pudo abrir la Biblia</h2><p>" .. escapar(self.ruta_db or Conf.carpetaModulos(self.plugin_path))
            .. "</p><p>" .. escapar(err) .. "</p>"
        return
    end
    self.db = db
    self.sqlite = db:diagnostico().sqlite
    self:leerCapitulo(self.libro, self.cap)
end

--- Lee un capítulo y arma su HTML (sin mostrarlo).
function Lector:leerCapitulo(libro, cap)
    local max_cap = self.db:capitulos(libro)
    if max_cap == 0 then return false end
    cap = math.max(1, math.min(cap, max_cap))
    self.libro, self.cap = libro, cap
    local inicio = time.now()
    self.versos = self.db:capitulo(libro, cap)
    self.con_nota = self.usuario and self.usuario:versosConNota(libro, cap) or {}
    self.verso_sel = nil
    self.titulo = Libros.nombre(libro) .. " " .. cap
    local html = { "<h2>" .. escapar(self.titulo) .. "</h2>" }
    for _, fila in ipairs(self.versos) do
        local v = fila[1]
        -- con la Biblia convertida de theWord el versículo ya viene en HTML; si no, se escapa
        local cuerpo = fila[3] or escapar(fila[2])
        local clase = fila[4] == 1 and ' class="finp"' or ""
        local marca = self.con_nota[v] and ' <span class="mn">▪</span>' or "" -- tiene nota
        html[#html + 1] = string.format('<p%s><a href="verso://%d-%d-%d"><b>%d</b>%s %s</a></p>',
            clase, libro, cap, v, v, marca, cuerpo)
    end
    local la, ca = self:capituloVecino(-1)
    local ls, cs = self:capituloVecino(1)
    html[#html + 1] = string.format(
        '<p class="nav"><a href="verso://anterior">‹ %s %d</a> &#160;·&#160; <a href="verso://arriba">Arriba</a>'
            .. ' &#160;·&#160; <a href="verso://siguiente">%s %d ›</a></p>',
        escapar(Libros.abreviatura(la)), ca, escapar(Libros.abreviatura(ls)), cs)
    self.html = table.concat(html, "\n")
    logger.info("[BSH-K3] capítulo leído en", time.to_ms(time.since(inicio)), "ms")
    return true
end

--- Capítulo anterior o siguiente (cruza de libro). Devuelve libro, cap.
function Lector:capituloVecino(delta)
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

--- Muestra un capítulo. verso: lo resalta y va a su página; ultima: abre en la última página.
function Lector:irA(libro, cap, verso, ultima)
    if not self.db or libro < 1 or libro > Libros.total then return end
    if not self:leerCapitulo(libro, cap) then return end
    self:rehacer()
    if verso then
        self:enfocarUri(string.format("verso://%d-%d-%d", self.libro, self.cap, verso))
    elseif ultima then
        self:irAPagina(self:paginas())
    end
end

function Lector:moverCapitulo(delta)
    local libro, cap = self:capituloVecino(delta)
    self:irA(libro, cap, nil, delta < 0)
end

--- Visor -------------------------------------------------------------------------------

function Lector:alEnfocar(uri)
    local _, _, v = (uri or ""):match("^verso://(%d+)%-(%d+)%-(%d+)$")
    self.verso_sel = tonumber(v)
end

function Lector:alFinal(delta)
    if self.db then self:moverCapitulo(delta) end
end

function Lector:activar(uri)
    if uri == "verso://anterior" then return self:moverCapitulo(-1) end
    if uri == "verso://siguiente" then return self:moverCapitulo(1) end
    if uri == "verso://arriba" then
        self.foco = nil
        self:irAPagina(1)
        return
    end
    self:menu()
end

--- Panel lateral para el versículo resaltado (o el capítulo).
function Lector:menu()
    if not self.db then
        return self.app:abrirConfig()
    end
    self.app:abrirPanel()
end

function Lector:referencia()
    local ref = Libros.nombre(self.libro) .. " " .. self.cap
    if self.verso_sel then ref = ref .. ":" .. self.verso_sel end
    return ref
end

--- Comentarios y palabras de diccionario del pasaje. Quedan en memoria: los módulos no cambian
-- mientras la app está abierta (notas y favoritos sí, y por eso se cuentan siempre).
function Lector:conteoModulos()
    local Comentarios = require("bsh_comentario")
    local Diccionarios = require("bsh_diccionario")
    local verso = self.verso_sel
    local clave = self.libro .. ":" .. self.cap .. ":" .. (verso or 0)
    local c = self.conteos[clave]
    if c then return c end
    c = {}
    c.comentarios, c.total_comentarios = Comentarios.contarTodos(self.plugin_path, self.libro, self.cap, verso)
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
        self.conteos, self.n_conteos = {}, 0
    end
    self.conteos[clave] = c
    self.n_conteos = self.n_conteos + 1
    return c
end

--- Acciones del versículo --------------------------------------------------------------

function Lector:copiar()
    if not self.verso_sel then return avisar("Resalta un versículo con el D-Pad para copiarlo") end
    local ref = self:referencia()
    local texto = self.db:verso(self.libro, self.cap, self.verso_sel) or ""
    require("device").input.setClipboardText(string.format("%s %s (RVR1960)", texto, ref))
    avisar("Copiado: " .. ref)
end

--- Las notas cambiaron: vuelve a marcar los versículos con nota, en la misma página.
function Lector:actualizarNotas()
    if not self.db then return end
    local verso = self.verso_sel
    self:leerCapitulo(self.libro, self.cap)
    local pagina = self:pagina()
    self:rehacer()
    self:irAPagina(pagina)
    if verso then
        local uri = string.format("verso://%d-%d-%d", self.libro, self.cap, verso)
        local p, i = self:buscarEnlace(uri)
        if p == self:pagina() then self:enfocar(i) end
    end
end

--- Los ajustes de lectura de la Biblia cambiaron.
function Lector:aplicarAjustes()
    self.ajustes = require("bsh_ajustes_lectura").leer("biblia")
    self:rehacer(true)
end

--- Ciclo de vida -------------------------------------------------------------------------

function Lector:onCerrar()
    UIManager:show(ConfirmBox:new{
        text = "¿Deseas salir de Bible Study Hub for K3?",
        ok_text = "Salir",
        cancel_text = "Cancelar",
        ok_callback = function() UIManager:close(self) end,
    })
    return true
end

--- Guarda la posición y cierra las bases. También lo usa el cierre de emergencia.
function Lector:cerrarBases()
    if self.db then
        G_reader_settings:saveSetting("bsh_pos", { self.libro, self.cap })
        G_reader_settings:flush()
        self.db:cerrar()
        self.db = nil
    end
    if self.usuario then
        self.usuario:cerrar()
        self.usuario = nil
    end
    Registro.cerrar()
end

--- Al despertar el Kindle, el tiempo antes del reposo cuenta de nuevo desde cero.
function Lector:onResume()
    local ok, Dispositivo = pcall(require, "bsh_dispositivo")
    if ok and Dispositivo._oyendo then Dispositivo.alDespertar() end
end

function Lector:onShow()
    if not self.db then
        UIManager:show(InfoMessage:new{ text = "No se pudo abrir la Biblia. Pulsa Menu para elegir la carpeta de módulos." })
    end
    return Visor.onShow(self)
end

function Lector:onCloseWidget()
    self:cerrarBases()
    Visor.onCloseWidget(self)
    if self.app then self.app:alCerrarLector() end
end

return Lector
