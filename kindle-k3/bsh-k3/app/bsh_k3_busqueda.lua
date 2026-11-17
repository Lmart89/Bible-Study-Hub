--[[--
Resultados de una búsqueda en la Biblia para el Kindle 3, sobre bsh_k3_visor. Busca donde y como
dice la app (App:busqueda(): grupos de libros y modos, los mismos del PW3).

Arriba, «Dónde: …» y «Cómo: …» (Press cambia la opción y vuelve a buscar) y, en la primera tanda,
«Por libro»: cuántos hay en cada libro (Press busca solo en ese libro).

D-Pad: de un enlace al siguiente; Press sobre un versículo lo muestra con las palabras buscadas en
negrita y «Ir al pasaje». Teclas laterales: páginas; pasada la última, los resultados siguientes
(y antes de la primera, los anteriores). Menu: nueva búsqueda, dónde, cómo y ajustes. Back vuelve
a la Biblia.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local DB = require("bsh_db")
local Libros = require("bsh_libros")
local UI = require("bsh_ui")
local Visor = require("bsh_k3_visor")

local POR_PAGINA = 15 -- resultados por consulta

local CSS = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.4; text-align: left; }
p { margin: 0 0 0.55em 0; }
p.cab { margin-bottom: 0.3em; }
p.cab a { text-decoration: underline; }
p.libros { font-size: 0.85em; padding-bottom: 0.4em; border-bottom: 1px solid black; }
p.libros a { text-decoration: underline; }
p.aviso { font-style: italic; }
a { color: black; text-decoration: none; }
]]

local function escapar(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local Busqueda = Visor:extend{
    name = "bsh_k3_busqueda",
    css = CSS,
    app = nil,
    db = nil,
    libro = nil, -- el libro que se lee, para «Libro actual»
    consulta = "",
}

function Busqueda:iniciar()
    self.tanda = 1
    self:consultar()
end

--- Lee la tanda de resultados actual y arma el HTML.
function Busqueda:consultar()
    local nombre, desde, hasta = self.app:rangoBusqueda()
    local modo = DB.modo(self.app:busqueda().modo)
    self.modo = modo.id
    local filas, total, _, err, por_libro = self.db:buscar(self.consulta, desde, hasta, self.tanda, POR_PAGINA, modo.id)
    filas, self.total = filas or {}, total or 0
    self.tandas = math.max(1, math.ceil(self.total / POR_PAGINA))
    self.titulo = string.format("«%s» · %d", self.consulta, self.total)
    local sep = " &#160;·&#160; "
    local html = {
        '<p class="cab"><a href="opcion://rango">Dónde: ' .. escapar(nombre) .. "</a>" .. sep
            .. '<a href="opcion://modo">Cómo: ' .. escapar(modo.nombre) .. "</a></p>",
    }
    if self.tanda == 1 and por_libro and #por_libro > 1 then
        local libros = {}
        for _, f in ipairs(por_libro) do
            libros[#libros + 1] = string.format('<a href="libro://%d">%s</a>&#160;%d', f[1], escapar(Libros.abreviatura(f[1])), f[2])
        end
        html[#html + 1] = '<p class="libros">Por libro: ' .. table.concat(libros, " · ") .. "</p>"
    end
    if self.total > 0 then
        html[#html + 1] = string.format('<p class="aviso">Resultados %d a %d de %d</p>',
            (self.tanda - 1) * POR_PAGINA + 1, math.min(self.total, self.tanda * POR_PAGINA), self.total)
    end
    for _, f in ipairs(filas) do
        local extracto = escapar(f[4]):gsub("\1", "<b>"):gsub("\2", "</b>")
        html[#html + 1] = string.format('<p><a href="resultado://%d-%d-%d"><b>%s %d:%d</b> %s</a></p>',
            f[1], f[2], f[3], escapar(Libros.abreviatura(f[1])), f[2], f[3], extracto)
    end
    if err then
        html[#html + 1] = '<p class="aviso">Error en la búsqueda: ' .. escapar(err)
            .. (modo.id == "avanzada" and ". Revisa la sintaxis o elige otro modo en «Cómo»." or "") .. "</p>"
    elseif self.total == 0 then
        html[#html + 1] = '<p class="aviso">Sin resultados. Prueba otro «Dónde» o «Cómo», o pulsa Menu para buscar otra cosa.</p>'
    end
    self.html = table.concat(html, "\n")
end

--- Vuelve a buscar desde la primera tanda (otro dónde o cómo).
function Busqueda:rebuscar()
    self.tanda = 1
    self:consultar()
    self:rehacer()
    if #self:enlacesPagina() > 0 then self:enfocar(1) end
end

--- Pasa a otra tanda de resultados; la anterior abre en su última página.
function Busqueda:cambiarTanda(delta)
    local tanda = self.tanda + delta
    if tanda < 1 or tanda > self.tandas then return end
    self.tanda = tanda
    self:consultar()
    self:rehacer()
    if delta < 0 then self:irAPagina(self:paginas()) end
end

function Busqueda:alFinal(delta)
    self:cambiarTanda(delta)
end

function Busqueda:elegirRango()
    self.app:elegirRango(function() self:rebuscar() end)
end

function Busqueda:elegirModo()
    self.app:elegirModo(function() self:rebuscar() end)
end

function Busqueda:activar(uri)
    uri = uri or ""
    if uri == "opcion://rango" then return self:elegirRango() end
    if uri == "opcion://modo" then return self:elegirModo() end
    local n = tonumber(uri:match("^libro://(%d+)$"))
    if n then
        local b = self.app:busqueda()
        b.rango, b.desde, b.hasta = "libros", n, n
        self.app:guardarBusqueda()
        return self:rebuscar()
    end
    local l, c, v = uri:match("^resultado://(%d+)%-(%d+)%-(%d+)$")
    if not l then return end
    l, c, v = tonumber(l), tonumber(c), tonumber(v)
    -- el versículo entero con las palabras buscadas en negrita (si no, sin ellas)
    local ok, resaltado = pcall(self.db.versoResaltado, self.db, self.consulta, self.modo, l, c, v)
    if not (ok and resaltado) then
        local pasaje = self.db:pasaje(l, c, v, v)
        resaltado = pasaje[1] and pasaje[1][2] or ""
    end
    UI.vistaPrevia{
        titulo = Libros.nombre(l) .. " " .. c .. ":" .. v,
        html = "<p><b>" .. v .. "</b> " .. resaltado .. "</p>",
        ajustes = self.ajustes,
        alto = 0.5,
        botones = {
            { texto = "Cerrar" },
            { texto = "Ir al pasaje", callback = function() self.app:irAVerso(l, c, v) end },
        },
    }
end

function Busqueda:menu()
    local dialogo
    local function opcion(texto, accion)
        return { { text = texto, callback = function()
            UIManager:close(dialogo)
            accion()
        end } }
    end
    dialogo = ButtonDialog:new{
        title = "Opciones de búsqueda",
        title_align = "center",
        buttons = {
            opcion("Nueva búsqueda…", function()
                UIManager:close(self)
                self.app:pedirBusqueda(self.consulta)
            end),
            opcion("Dónde: " .. (self.app:rangoBusqueda()), function() self:elegirRango() end),
            opcion("Cómo: " .. DB.modo(self.modo).nombre, function() self:elegirModo() end),
            opcion("Ajustes de lectura…", function() self.app:abrirAjustes("modulos") end),
            opcion("Volver a la Biblia", function() self:onCerrar() end),
        },
    }
    UIManager:show(dialogo)
end

function Busqueda:aplicarAjustes()
    self.ajustes = require("bsh_ajustes_lectura").leer("modulos")
    self:rehacer(true)
end

return Busqueda
