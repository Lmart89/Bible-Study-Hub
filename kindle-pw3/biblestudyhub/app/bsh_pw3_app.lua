--[[--
Arranque de Bible Study Hub sin el gestor de archivos de KOReader. reader.lua llama a App:abrir();
al cerrarse la última pantalla, UIManager termina y koreader.sh devuelve el Kindle a su inicio.

Actualizaciones por Wi-Fi (bsh_actualizar, común con el Kindle 3): paquetes bsh-pw3-<versión>.tar
que genera tools/armar_bsh_pw3.py --paquete. Tras instalar, la app sale con el código 85 y
biblestudyhub.sh la vuelve a abrir con los archivos nuevos.
--]]--

local UIManager = require("ui/uimanager")

local App = {
    path = "app",
}

--- Pantalla de reposo, como la de Bible Study Hub for K3: el logo arriba al centro con «Bible Study
-- Hub» debajo (app/suspension/suspension.svg, de tools/suspension_k3.py --pw3) y, bajo el texto, el
-- recuadro «Kindle en suspensión» de KOReader. Son ajustes de la configuración propia de la app
-- (biblestudyhub/settings.reader.lua), no los de KOReader.
local REPOSO = {
    screensaver_type = "random_image", -- una imagen de screensaver_dir: la única que hay
    screensaver_img_background = "white",
    screensaver_stretch_images = false,
    screensaver_cycle_images_alphabetically = false,
    screensaver_show_message = true,
    screensaver_message = "Kindle en suspensión",
    screensaver_message_container = "box",
    screensaver_message_vertical_position = 36, -- % desde abajo: justo bajo «Bible Study Hub»
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
    -- contraste, luz, modo nocturno, tiempo de reposo y Wi-Fi (Ajustes avanzados)
    local Dispositivo = require("bsh_dispositivo")
    Dispositivo.iniciar()
    local Actualizar = require("bsh_actualizar").configurar{
        nombre = "Bible Study Hub",
        prefijo = "bsh-pw3",
        reiniciar = function() self:reiniciarKOReader() end,
    }
    local Carga = require("bsh_carga")
    UIManager:show(Carga:new{
        plugin_path = self.path,
        al_terminar = function()
            local Pantalla = require("bsh_lector")
            self.pantalla = Pantalla:new{
                plugin_path = self.path,
                al_reiniciar = function() self:abrir() end,
                actualizar = Actualizar,
                dispositivo = Dispositivo,
            }
            UIManager:show(self.pantalla)
        end,
    })
end

--- Cierra el lector (y con él las bases) y sale con el código 85: el script vuelve a abrir la app.
function App:reiniciarKOReader()
    if self.pantalla then
        UIManager:close(self.pantalla)
        self.pantalla = nil
    end
    UIManager:restartKOReader()
end

return App
