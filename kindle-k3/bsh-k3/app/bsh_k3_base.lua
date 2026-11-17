--[[--
Sustituye a FileManager y ReaderUI donde el núcleo de KOReader espera uno de los dos: la pantalla
de reposo (Screensaver) y el selector de carpetas (PathChooser, que consulta los atajos de carpeta).
El script de armado añade «or require("bsh_k3_base")» en esos dos sitios.
--]]--

local Base = {
    bookinfo = {},
    folder_shortcuts = {},
}

function Base:handleEvent() end

function Base.bookinfo:expandString(texto) return texto end

function Base.bookinfo:getCoverImage() end

function Base.folder_shortcuts:hasFolderShortcut() return false end

function Base.folder_shortcuts:getShortcutFullName() return nil end

return Base
