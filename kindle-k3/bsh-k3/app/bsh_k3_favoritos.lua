--[[--
Listas de favoritos para el Kindle 3, sobre bsh_k3_visor. D-Pad: de un versículo al siguiente;
Press lo abre en la Biblia. Teclas laterales: páginas. Back vuelve a la Biblia.
(Para guardar un versículo: resáltalo en la Biblia y elige «Guardar en favoritos» en el panel.)
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local Libros = require("bsh_libros")
local Visor = require("bsh_k3_visor")

local CSS = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.4; }
h2 { font-size: 1.1em; margin: 0.8em 0 0.3em 0; border-bottom: 1px solid black; }
p { margin: 0 0 0.35em 0; }
a { color: black; text-decoration: none; }
p.vacio { font-style: italic; }
]]

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local Favoritos = Visor:extend{
    name = "bsh_k3_favoritos",
    css = CSS,
    titulo = "Favoritos",
    app = nil,
    usuario = nil,
    db = nil,
}

function Favoritos:iniciar()
    local html = {}
    local listas = self.usuario and self.usuario:todo() or {}
    for _, l in ipairs(listas) do
        html[#html + 1] = "<h2>" .. escapar(l.nombre) .. " (" .. #l.versos .. ")</h2>"
        for _, v in ipairs(l.versos) do
            local texto = self.db and self.db:verso(v[1], v[2], v[3]) or ""
            html[#html + 1] = string.format('<p><a href="verso://%d-%d-%d"><b>%s %d:%d</b> %s</a></p>',
                v[1], v[2], v[3], escapar(Libros.abreviatura(v[1])), v[2], v[3], escapar(texto))
        end
        if #l.versos == 0 then html[#html + 1] = '<p class="vacio">Lista vacía.</p>' end
    end
    if #listas == 0 then
        html[1] = '<p class="vacio">Todavía no hay listas. Resalta un versículo en la Biblia y elige «Guardar en favoritos» en el panel.</p>'
    end
    self.titulo = "Favoritos · " .. #listas .. (#listas == 1 and " lista" or " listas")
    self.html = table.concat(html, "\n")
end

function Favoritos:activar(uri)
    local b, c, v = (uri or ""):match("^verso://(%d+)%-(%d+)%-(%d+)$")
    if b then self.app:irAVerso(tonumber(b), tonumber(c), tonumber(v)) end
end

function Favoritos:menu()
    local dialogo
    dialogo = ButtonDialog:new{
        title = "Favoritos",
        title_align = "center",
        buttons = {
            { { text = "Ajustes de lectura…", callback = function()
                UIManager:close(dialogo)
                self.app:abrirAjustes("modulos")
            end } },
            { { text = "Volver a la Biblia", callback = function()
                UIManager:close(dialogo)
                self:onCerrar()
            end } },
        },
    }
    UIManager:show(dialogo)
end

function Favoritos:aplicarAjustes()
    self.ajustes = require("bsh_ajustes_lectura").leer("modulos")
    self:rehacer(true)
end

return Favoritos
