--[[--
Diccionario para el Kindle 3, sobre bsh_k3_visor. Usa las búsquedas de bsh_diccionario.

Empieza con las palabras del pasaje que tienen artículo, en una tabla de tres columnas: arriba y
abajo cambian de fila, izquierda y derecha recorren la fila. En el artículo, el D-Pad sigue las
citas en orden. Press abre el artículo de la palabra o la vista previa de la cita. Menu: término anterior, palabras del
pasaje, buscar un término, elegir diccionario y ajustes. Back cierra y vuelve a la Biblia.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local DB = require("bsh_db")
local Diccionarios = require("bsh_diccionario")
local UI = require("bsh_ui")
local Visor = require("bsh_k3_visor")

local CSS = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.4; text-align: justify; }
h2 { font-size: 1.1em; margin: 0 0 0.4em 0; text-align: left; }
p { margin: 0 0 0.5em 0; }
p.aviso { font-style: italic; }
table.palabras { width: 100%; border-collapse: collapse; }
table.palabras td { width: 33%; padding: 0.35em 0.3em; text-align: left; vertical-align: top; }
a { color: black; text-decoration: underline; }
]]

local COLUMNAS = 3 -- palabras por fila de la lista

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local Diccionario = Visor:extend{
    name = "bsh_k3_diccionario",
    css = CSS,
    plugin_path = nil,
    app = nil,
    biblia = nil,
    ref = nil, -- «Juan 3:16» o «Juan 3»
    palabras = nil, -- Diccionarios.encontradas, ya buscadas en el panel
    lista = nil, -- Diccionarios.listar
}

function Diccionario:iniciar()
    self.lista = self.lista or Diccionarios.listar(self.plugin_path)
    for _, d in ipairs(self.lista) do
        d.palabras = Diccionarios.encontradas({ d }, self.palabras or {})
    end
    -- el último diccionario elegido si tiene palabras; si no, el primero que tenga
    local elegido = G_reader_settings:readSetting("bsh_diccionario")
    self.indice = 1
    local primero_con_palabras
    for i, d in ipairs(self.lista) do
        if DB.sinExtension(d.archivo) == DB.sinExtension(elegido) then self.indice = i end
        if not primero_con_palabras and #d.palabras > 0 then primero_con_palabras = i end
    end
    local actual = self.lista[self.indice]
    if actual and #actual.palabras == 0 and primero_con_palabras then self.indice = primero_con_palabras end
    self.historia = {} -- términos vistos, para «Término anterior»
    self:htmlLista()
end

function Diccionario:htmlLista()
    local d = self.lista[self.indice]
    self.titulo = d and d.nombre or "Diccionario"
    local html = { "<h2>" .. escapar(self.ref or "") .. "</h2>" }
    if not d then
        html[#html + 1] = '<p class="aviso">No hay diccionarios .ebd en la carpeta de módulos.</p>'
    elseif #d.palabras == 0 then
        html[#html + 1] = '<p class="aviso">Ninguna palabra de este pasaje tiene artículo en «' .. escapar(d.nombre)
            .. "». Pulsa Menu para buscar un término o elegir otro diccionario.</p>"
    else
        -- en una tabla de COLUMNAS: arriba y abajo cambian de fila, los lados recorren la fila
        local filas, fila = {}, {}
        for _, p in ipairs(d.palabras) do
            fila[#fila + 1] = string.format('<td><a href="dic://%s">%s</a></td>', p.norm, escapar(p.original))
            if #fila == COLUMNAS then
                filas[#filas + 1] = "<tr>" .. table.concat(fila) .. "</tr>"
                fila = {}
            end
        end
        if #fila > 0 then
            while #fila < COLUMNAS do fila[#fila + 1] = "<td></td>" end
            filas[#filas + 1] = "<tr>" .. table.concat(fila) .. "</tr>"
        end
        html[#html + 1] = '<table class="palabras">' .. table.concat(filas) .. "</table>"
    end
    self.html = table.concat(html, "\n")
    self.termino = nil
    self.rejilla = true
end

function Diccionario:verLista()
    self:htmlLista()
    self:rehacer()
end

function Diccionario:verTermino(termino, sin_historia)
    if not sin_historia then
        self.historia[#self.historia + 1] = self.termino or false -- false = la lista de palabras
    end
    self.html = Diccionarios.articulo({ self.lista[self.indice] }, termino)
    self.termino = termino
    self.rejilla = false -- en el artículo, el D-Pad sigue las citas en orden
    self:rehacer()
end

--- El término anterior o la lista de palabras.
function Diccionario:atras()
    local anterior = table.remove(self.historia)
    if anterior then self:verTermino(anterior, true) else self:verLista() end
end

function Diccionario:activar(uri)
    if not uri then return end
    local termino = uri:match("^dic://(.+)$")
    if termino then return self:verTermino(termino) end
    UI.previaVerso{
        uri = uri,
        biblia = self.biblia,
        al_abrir = function(libro, cap, verso) self.app:irAVerso(libro, cap, verso) end,
    }
end

function Diccionario:elegirDiccionario()
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
                self.titulo = d.nombre
                if self.termino then self:verTermino(self.termino, true) else self:verLista() end
            end,
        } }
    end
    dialogo = ButtonDialog:new{ title = "Diccionario", title_align = "center", buttons = filas }
    UIManager:show(dialogo)
end

function Diccionario:buscarTermino()
    local d = self.lista[self.indice]
    if not d then return end
    local dialogo
    dialogo = InputDialog:new{
        title = "Buscar en «" .. d.nombre .. "»",
        input_hint = "templo",
        buttons = { {
            { text = "Cancelar", id = "close", callback = function() UIManager:close(dialogo) end },
            { text = "Buscar", is_enter_default = true, callback = function()
                local t = dialogo:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialogo)
                if t ~= "" then self:verTermino(t) end
            end },
        } },
    }
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

function Diccionario:menu()
    local dialogo
    local filas = {}
    local function opcion(texto, accion)
        filas[#filas + 1] = { { text = texto, callback = function()
            UIManager:close(dialogo)
            accion()
        end } }
    end
    if #self.historia > 0 then opcion("‹ Término anterior", function() self:atras() end) end
    if self.termino then
        opcion("Palabras de " .. (self.ref or "el pasaje"), function()
            self.historia[#self.historia + 1] = self.termino
            self:verLista()
        end)
    end
    opcion("Buscar un término…", function() self:buscarTermino() end)
    opcion("Elegir diccionario…", function() self:elegirDiccionario() end)
    opcion("Ajustes de lectura…", function() self.app:abrirAjustes("modulos") end)
    opcion("Volver a la Biblia", function() self:onCerrar() end)
    dialogo = ButtonDialog:new{ title = "Opciones del diccionario", title_align = "center", buttons = filas }
    UIManager:show(dialogo)
end

function Diccionario:aplicarAjustes()
    self.ajustes = require("bsh_ajustes_lectura").leer("modulos")
    self:rehacer(true)
end

return Diccionario
