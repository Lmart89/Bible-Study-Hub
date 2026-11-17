--[[--
Marcas sencillas de las notas → HTML (plan §2, «Estilos de las notas»).

KOReader no tiene un editor de texto con formato, pero sí muestra HTML: la nota se escribe
con marcas en el teclado y se ve ya formateada.

    **texto**   negrita              # Título    título
    *texto*     cursiva              - elemento  lista
    ==texto==   resaltado            > cita      cita con sangría
    Jn 3:16     enlace al versículo (también «1 Co 13:4», «Juan 3.16», «Salmos 23:1»)

Las líneas seguidas forman un párrafo (con salto de línea); una línea en blanco lo cierra.
--]]--

local Libros = require("bsh_libros")

local M = {}

local function escapar(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- «Jn 3:16», «1 Co 13:4», «Juan 3.16»: nombre (con número delante opcional) + capítulo + versículo.
-- [^%s%d%p<>] acepta letras con tilde (bytes UTF-8, que no son %p).
local REFERENCIA = "(%d?%s?[^%s%d%p<>][^%s%d%p<>]*)%s(%d+)[:%.](%d+)"

local function enlazar(texto)
    return (texto:gsub(REFERENCIA, function(nombre, cap, verso)
        local espacio, limpio = nombre:match("^(%s*)(.-)$")
        -- al menos 2 letras: «a 3:2» no es una referencia
        local libro = #limpio:gsub("^%d%s*", "") >= 2 and Libros.buscar(limpio)
        if not libro then return nil end -- deja el texto tal cual
        return string.format('%s<a href="verso://%d-%s-%s">%s %s:%s</a>', espacio, libro, cap, verso, limpio, cap, verso)
    end))
end

local function enLinea(texto)
    texto = escapar(texto)
    texto = texto:gsub("%*%*(.-)%*%*", "<b>%1</b>")
    texto = texto:gsub("%*([^%*]+)%*", "<i>%1</i>")
    texto = texto:gsub("==(.-)==", '<span class="res">%1</span>')
    return enlazar(texto)
end

--- Cuerpo de la nota (con marcas) → HTML.
function M.html(cuerpo)
    local out = {}
    local parrafo, lista, cita = {}, {}, {}
    local function cerrar()
        if #parrafo > 0 then out[#out + 1] = "<p>" .. table.concat(parrafo, "<br/>") .. "</p>" end
        if #lista > 0 then out[#out + 1] = "<ul><li>" .. table.concat(lista, "</li><li>") .. "</li></ul>" end
        if #cita > 0 then out[#out + 1] = "<blockquote>" .. table.concat(cita, "<br/>") .. "</blockquote>" end
        parrafo, lista, cita = {}, {}, {}
    end
    for linea in ((cuerpo or "") .. "\n"):gmatch("([^\n]*)\n") do
        linea = linea:gsub("%s+$", "")
        local titulo = linea:match("^#+%s+(.+)$")
        local elemento = linea:match("^%s*[-•]%s+(.+)$")
        local citado = linea:match("^>%s?(.*)$")
        if linea:match("^%s*$") then
            cerrar()
        elseif titulo then
            cerrar()
            out[#out + 1] = "<h3>" .. enLinea(titulo) .. "</h3>"
        elseif elemento then
            if #parrafo > 0 or #cita > 0 then cerrar() end
            lista[#lista + 1] = enLinea(elemento)
        elseif citado then
            if #parrafo > 0 or #lista > 0 then cerrar() end
            cita[#cita + 1] = enLinea(citado)
        else
            if #lista > 0 or #cita > 0 then cerrar() end
            parrafo[#parrafo + 1] = enLinea(linea)
        end
    end
    cerrar()
    return table.concat(out, "\n")
end

--- Texto sin marcas (para extractos y títulos).
function M.plano(cuerpo)
    local t = (cuerpo or ""):gsub("<!%-%-.-%-%->", ""):gsub("</?u>", ""):gsub("~~", "")
    t = t:gsub("%*%*", ""):gsub("==", ""):gsub("%*", "")
    t = t:gsub("\n[#>-]+%s*", "\n"):gsub("^[#>-]+%s*", "")
    return (t:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- Título de una nota: su primera línea con texto, sin marcas, hasta 60 caracteres.
function M.titulo(cuerpo)
    for linea in ((cuerpo or "") .. "\n"):gmatch("([^\n]*)\n") do
        local t = M.plano(linea)
        if t ~= "" then
            if #t > 60 then
                t = t:sub(1, 60):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "…"
            end
            return t
        end
    end
    return "Nota sin título"
end

M.AYUDA = [[Marcas para dar formato:

**negrita**     *cursiva*     ==resaltado==
# Título
- elemento de lista
> cita

Las referencias como Jn 3:16 o 1 Co 13:4 se convierten en enlaces al versículo.
Una línea en blanco separa párrafos.]]

return M
