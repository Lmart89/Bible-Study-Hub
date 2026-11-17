--[[--
Sustituye a FileManager y ReaderUI donde el núcleo de KOReader espera uno de los dos:
la pantalla de reposo (Screensaver) y el selector de carpetas (PathChooser).
--]]--

local Base = {
    bookinfo = {},
}

function Base:handleEvent() end

function Base.bookinfo:expandString(texto) return texto end

function Base.bookinfo:getCoverImage() end

return Base
