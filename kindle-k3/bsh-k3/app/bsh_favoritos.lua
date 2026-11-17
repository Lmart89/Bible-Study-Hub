--[[--
Favoritos en listas personalizadas.

  * Favoritos.dialogo{...}: el cuadro breve de la estrella. Muestra las listas (✓ si el versículo
    ya está en ella; tocarla lo quita) y «Nueva lista…».
  * Favoritos.Pantalla: todas las listas con sus versículos; tocar uno lo abre en el lector.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Libros = require("bsh_libros")
local Input = Device.input
local Screen = Device.screen

--- Aviso breve. Sin fuente, Notification lo trata como SOURCE_OTHER, que KOReader oculta
-- con los ajustes por defecto: se marca como «mostrar siempre».
local function avisar(texto)
    Notification:notify(texto, Notification.SOURCE_ALWAYS_SHOW)
end

local function escapar(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local Favoritos = {}

--- Pide el nombre de una lista nueva y añade el versículo a ella.
local function nuevaLista(usuario, libro, cap, verso, al_cambiar)
    local dialogo
    dialogo = InputDialog:new{
        title = "Nueva lista",
        input_hint = "Promesas",
        buttons = {
            {
                { text = "Cancelar", id = "close", callback = function() UIManager:close(dialogo) end },
                { text = "Crear y añadir", is_enter_default = true, callback = function()
                    local nombre = dialogo:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialogo)
                    if nombre == "" then return end
                    usuario:agregar(usuario:crearLista(nombre), libro, cap, verso)
                    avisar("Añadido a «" .. nombre .. "»")
                    if al_cambiar then al_cambiar() end
                end },
            },
        },
    }
    UIManager:show(dialogo)
    dialogo:onShowKeyboard()
end

--- Cuadro de la estrella para un versículo.
-- @param o { usuario, libro, cap, verso, al_cambiar = function() }
function Favoritos.dialogo(o)
    local ref = string.format("%s %d:%d", Libros.nombre(o.libro), o.cap, o.verso)
    local dialogo
    local botones = {}
    for _, l in ipairs(o.usuario:listas(o.libro, o.cap, o.verso)) do
        botones[#botones + 1] = { {
            text = (l.contiene and "✓ " or "") .. l.nombre .. " (" .. l.total .. ")",
            callback = function()
                UIManager:close(dialogo)
                if l.contiene then
                    o.usuario:quitar(l.id, o.libro, o.cap, o.verso)
                    avisar("Quitado de «" .. l.nombre .. "»")
                else
                    o.usuario:agregar(l.id, o.libro, o.cap, o.verso)
                    avisar("Añadido a «" .. l.nombre .. "»")
                end
                if o.al_cambiar then o.al_cambiar() end
            end,
        } }
    end
    botones[#botones + 1] = {
        { text = "Nueva lista…", callback = function()
            UIManager:close(dialogo)
            nuevaLista(o.usuario, o.libro, o.cap, o.verso, o.al_cambiar)
        end },
        { text = "Cerrar", callback = function() UIManager:close(dialogo) end },
    }
    dialogo = ButtonDialog:new{
        title = "Guardar " .. ref .. " en…",
        buttons = botones,
    }
    UIManager:show(dialogo)
end

--- Pantalla con todas las listas -------------------------------------------------------

local CSS = [[
@page { margin: 0; } /* MuPDF pone un margen de página por defecto que dejaba blanco alrededor */
body { margin: 0; line-height: 1.4; }
h2 { font-size: 1.1em; margin: 0.8em 0 0.3em 0; border-bottom: 1px solid black; }
p { margin: 0 0 0.35em 0; }
a { color: black; text-decoration: none; }
a b { text-decoration: underline; }
p.vacio { font-style: italic; color: #555555; }
]]

local Pantalla = InputContainer:extend{
    name = "bsh_favoritos",
    covers_fullscreen = true,
    usuario = nil, db = nil,
    al_abrir = nil, -- function(libro, cap, verso)
}

function Pantalla:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    local html = {}
    local listas = self.usuario:todo()
    for _, l in ipairs(listas) do
        html[#html + 1] = "<h2>" .. escapar(l.nombre) .. " (" .. #l.versos .. ")</h2>"
        for _, v in ipairs(l.versos) do
            local texto = self.db:verso(v[1], v[2], v[3]) or ""
            html[#html + 1] = string.format('<p><a href="verso://%d-%d-%d"><b>%s %d:%d</b> %s</a></p>',
                v[1], v[2], v[3], escapar(Libros.abreviatura(v[1])), v[2], v[3], escapar(texto))
        end
        if #l.versos == 0 then html[#html + 1] = '<p class="vacio">Lista vacía.</p>' end
    end
    if #listas == 0 then
        html[1] = '<p class="vacio">Todavía no hay listas. Resalta un versículo y toca la estrella para crear una.</p>'
    end

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margen = Size.padding.large
    local title_bar = TitleBar:new{
        width = screen_w,
        fullscreen = true,
        title = "Favoritos",
        subtitle = #listas .. " listas",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self[1] = FrameContainer:new{
        width = screen_w, height = screen_h,
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
        VerticalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = screen_w },
            title_bar,
            VerticalSpan:new{ width = margen },
            ScrollHtmlWidget:new{
                html_body = table.concat(html, "\n"),
                css = CSS,
                default_font_size = Screen:scaleBySize(19),
                width = screen_w - 2 * margen,
                height = screen_h - title_bar:getHeight() - 2 * margen,
                dialog = self,
                html_link_tapped_callback = function(link)
                    local libro, cap, verso = (link.uri or ""):match("^verso://(%d+)%-(%d+)%-(%d+)$")
                    if not libro then return end
                    UIManager:close(self)
                    if self.al_abrir then self.al_abrir(tonumber(libro), tonumber(cap), tonumber(verso)) end
                end,
            },
        },
    }
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

Favoritos.Pantalla = Pantalla
return Favoritos
