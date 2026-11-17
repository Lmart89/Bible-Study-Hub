--[[--
Ajustes avanzados del Kindle 3: la misma pantalla completa del PW3 (bsh_ajustes_avanzados), con sus
categorías e iconos (Administrar módulos, Opciones de red, Ajustes de pantalla, Actualizaciones y
Aplicación), manejada con las teclas:

  * D-Pad arriba/abajo: de una opción a otra (la enfocada se ve sombreada). Izquierda/derecha
    también, por comodidad.
  * Press: abre o cambia la opción enfocada.
  * Back: vuelve a la pantalla anterior (de una categoría a la principal; de la principal, al lector).
  * Menu: cierra los ajustes y vuelve al lector.

En los selectores de archivos, sin pantalla táctil, Press sobre un módulo lo elige, y para elegir
una carpeta se entra en ella y se elige su primera entrada («.»).
--]]--

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Conf = require("bsh_conf")
local Original = require("bsh_ajustes_avanzados")
local Input = Device.input

local SOMBRA = 0.3 -- como el foco de los visores

local Config = Original:extend{
    name = "bsh_k3_ajustes_avanzados",
    titulo_importar = "Elige el módulo (Press) para importarlo",
    foco = 1,
}

function Config:init()
    Original.init(self)
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        self.key_events.CerrarTodo = { { "Menu" } }
        self.key_events.FocoArriba = { { "Up" }, { "Left" } }
        self.key_events.FocoAbajo = { { "Down" }, { "Right" } }
        self.key_events.Activar = { { "Press" } }
    end
end

--- Arma la vista y prepara el foco: cada fila se sombrea al pintarse si es la enfocada.
function Config:construir()
    Original.construir(self)
    local filas = self.filas_menu or {}
    self.foco = math.max(1, math.min(self.foco or 1, #filas))
    for i, fila in ipairs(filas) do
        local pintar = fila.paintTo
        fila.paintTo = function(f, bb, x, y)
            pintar(f, bb, x, y)
            if i == self.foco and f.dimen then
                bb:darkenRect(f.dimen.x, f.dimen.y, f.dimen.w, f.dimen.h, SOMBRA)
            end
        end
    end
end

function Config:filaEnfocada()
    return self.filas_menu and self.filas_menu[self.foco]
end

--- Mueve el foco y refresca solo las dos filas que cambian.
function Config:moverFoco(delta)
    local filas = self.filas_menu or {}
    if #filas == 0 then return true end
    local antes = filas[self.foco]
    self.foco = (self.foco - 1 + delta) % #filas + 1
    local ahora = filas[self.foco]
    local zona
    for _, f in ipairs({ antes, ahora }) do
        if f and f.dimen then
            local d = Geom:new{ x = f.dimen.x, y = f.dimen.y, w = f.dimen.w, h = f.dimen.h }
            zona = zona and zona:combine(d) or d
        end
    end
    UIManager:setDirty(self, zona and function() return "ui", zona end or "ui")
    return true
end

function Config:onFocoArriba() return self:moverFoco(-1) end
function Config:onFocoAbajo() return self:moverFoco(1) end

function Config:onActivar()
    local fila = self:filaEnfocada()
    if fila and fila.callback and not fila.deshabilitada then fila.callback() end
    return true
end

--- Menu: de vuelta al lector desde cualquier vista.
function Config:onCerrarTodo()
    self:cerrarTodo()
    return true
end

--- Carpeta de módulos: el título original pide una pulsación larga, que el Kindle 3 no tiene.
function Config:elegirCarpeta(actual)
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        title = "Entra en la carpeta y elige «.»",
        select_file = false,
        path = actual or Conf.carpetaModulos(self.plugin_path),
        file_filter = function(archivo) return archivo:lower():match("%.eb[bcd]$") ~= nil end,
        onConfirm = function(ruta) self:confirmarCarpeta(ruta) end,
    })
end

--- «Acerca de» del Kindle 3: sus textos, la versión del último parche instalado y sin la ✕ (se
-- cierra con Back).
function Config:abrirAcerca()
    self.acerca = {
        nombre = "Bible Study Hub for K3",
        version = "Versión " .. require("bsh_actualizar").version(),
        descripcion = "Herramienta de Estudio Bíblico para Lectores Electrónicos basada en KOReader. "
            .. "Creada por Luis E. Martínez S.",
        sin_cerrar = true,
    }
    Original.abrirAcerca(self)
end

--- Abre los ajustes avanzados desde el panel del lector.
function Config.mostrar(app)
    local l = app.lector
    UIManager:show(Config:new{
        plugin_path = app.path,
        sqlite = l and l.sqlite,
        actualizar = require("bsh_actualizar"),
        dispositivo = require("bsh_dispositivo"),
        al_reiniciar = function() app:reiniciar() end,
        -- «Salir» ya preguntó: se cierra el lector y con él la app
        al_salir = function() if app.lector then UIManager:close(app.lector) end end,
        -- el contraste cambia cómo se dibuja el texto: la Biblia (y lo que esté encima) se rehace
        al_cambiar_pantalla = function() app:pantallaCambiada() end,
    })
end

return Config
