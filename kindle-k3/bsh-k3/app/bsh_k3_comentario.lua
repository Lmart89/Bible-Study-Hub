--[[--
Comentario para el Kindle 3, sobre bsh_k3_visor. Usa la búsqueda de bsh_comentario.

D-Pad: recorre las citas bíblicas del comentario; Press muestra la cita en una ventana, con
«Abrir en el lector». Teclas laterales: páginas. Menu: elegir comentario, capítulo completo,
introducción al libro y ajustes. Back cierra y vuelve a la Biblia.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local Comentarios = require("bsh_comentario")
local DB = require("bsh_db")
local UI = require("bsh_ui")
local Visor = require("bsh_k3_visor")

local CSS = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.4; text-align: justify; }
h2 { font-size: 1.1em; margin: 0 0 0.4em 0; text-align: left; }
h3 { font-size: 1em; margin: 0.6em 0 0.2em 0; text-align: left; }
p { margin: 0 0 0.5em 0; }
a { color: black; text-decoration: underline; }
]]

local Comentario = Visor:extend{
    name = "bsh_k3_comentario",
    css = CSS,
    plugin_path = nil,
    app = nil,
    biblia = nil, -- DB de la Biblia, para la vista previa de las citas
    libro = nil, cap = nil, verso = nil, -- verso nil = comentario del capítulo
    lista = nil, -- Comentarios.contarTodos, ya contado en el panel
}

function Comentario:iniciar()
    self.lista = self.lista or Comentarios.contarTodos(self.plugin_path, self.libro, self.cap, self.verso)
    -- el último comentario elegido si tiene entrada; si no, el primero que tenga
    local elegido = G_reader_settings:readSetting("bsh_comentario")
    self.indice = 1
    local primero_con_entrada
    for i, c in ipairs(self.lista) do
        if DB.sinExtension(c.archivo) == DB.sinExtension(elegido) then self.indice = i end
        if not primero_con_entrada and (c.n or 0) > 0 then primero_con_entrada = i end
    end
    local actual = self.lista[self.indice]
    if actual and (actual.n or 0) == 0 and primero_con_entrada then self.indice = primero_con_entrada end
    self.modo = nil -- nil = la referencia; "capitulo"; "libro"
    self:consultar()
end

function Comentario:consultar()
    local c = self.lista[self.indice]
    if not c then
        self.titulo = "Comentario"
        self.html = "<h2>No hay comentarios instalados</h2><p>Copia comentarios .ebc en la carpeta de módulos.</p>"
        return
    end
    self.titulo = c.nombre
    self.html = Comentarios.buscar(c, self.libro, self.cap, self.verso, self.modo)
end

function Comentario:verModo(modo)
    self.modo = modo
    self:consultar()
    self:rehacer()
end

function Comentario:activar(uri)
    if not uri then return end
    UI.previaVerso{
        uri = uri,
        biblia = self.biblia,
        al_abrir = function(libro, cap, verso) self.app:irAVerso(libro, cap, verso) end,
    }
end

function Comentario:elegirComentario()
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
                self:rehacer()
            end,
        } }
    end
    dialogo = ButtonDialog:new{ title = "Comentario", title_align = "center", buttons = filas }
    UIManager:show(dialogo)
end

function Comentario:menu()
    local dialogo
    local function opcion(texto, accion)
        return { { text = texto, callback = function()
            UIManager:close(dialogo)
            accion()
        end } }
    end
    dialogo = ButtonDialog:new{
        title = "Opciones del comentario",
        title_align = "center",
        buttons = {
            opcion("Elegir comentario…", function() self:elegirComentario() end),
            opcion(self.modo == "capitulo" and "Solo la referencia" or "Todo el capítulo", function()
                self:verModo(self.modo ~= "capitulo" and "capitulo" or nil)
            end),
            opcion(self.modo == "libro" and "Solo la referencia" or "Introducción al libro", function()
                self:verModo(self.modo ~= "libro" and "libro" or nil)
            end),
            opcion("Ajustes de lectura…", function() self.app:abrirAjustes("modulos") end),
            opcion("Volver a la Biblia", function() self:onCerrar() end),
        },
    }
    UIManager:show(dialogo)
end

function Comentario:aplicarAjustes()
    self.ajustes = require("bsh_ajustes_lectura").leer("modulos")
    self:rehacer(true)
end

return Comentario
