--[[--
Ajustes de lectura, en dos secciones independientes:
    biblia   el lector del texto bíblico
    modulos  «Otros módulos»: las pantallas de comentarios, diccionarios y notas

Cada sección guarda tipo y tamaño de letra (el tipo tiene su cuadro), márgenes (en unidades de Screen:scaleBySize, como Size.padding.*),
interlineado y alineación en G_reader_settings («bsh_ajustes_<sección>»).

El cuadro se abre desde el lector (sección Biblia) o desde un comentario o diccionario
(sección Comentarios y diccionarios). Cada cambio se aplica al momento sobre la pantalla de
detrás y el cuadro se reabre con los valores nuevos, como el menú de márgenes de la alfa 6.
El resultado de una sección solo se ve en su pantalla: los ajustes de los módulos se ven con
un comentario o diccionario abierto.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Screen = Device.screen

local Ajustes = {}

-- «Otros módulos» = comentarios, diccionarios y notas (y los que se añadan)
local TITULOS = { biblia = "Biblia", modulos = "Otros módulos" }
local ORDEN = { "biblia", "modulos" }

-- Valores iniciales: el aspecto de las alfas 3–6 en cada pantalla
local INICIALES = {
    biblia = { fuente = "", letra = 20, lateral = 10, superior = 10, inferior = 0, interlineado = 1.45, alineacion = "justify" },
    modulos = { fuente = "", letra = 20, lateral = 10, superior = 10, inferior = 0, interlineado = 1.45, alineacion = "justify" },
}

-- Fuentes que trae KOReader. MuPDF las carga desde el archivo con @font-face; con la negrita o la
-- cursiva que falten, las simula. La inicial ("") es la de MuPDF, sin archivos que cargar.
local FUENTES = {
    { clave = "", nombre = "Predeterminada" },
    { clave = "noto_serif", nombre = "Noto Serif", normal = "noto/NotoSerif-Regular.ttf", negrita = "noto/NotoSerif-Bold.ttf",
        cursiva = "noto/NotoSerif-Italic.ttf", negrita_cursiva = "noto/NotoSerif-BoldItalic.ttf" },
    { clave = "noto_sans", nombre = "Noto Sans", normal = "noto/NotoSans-Regular.ttf", negrita = "noto/NotoSans-Bold.ttf",
        cursiva = "noto/NotoSans-Italic.ttf", negrita_cursiva = "noto/NotoSans-BoldItalic.ttf" },
    { clave = "free_serif", nombre = "FreeSerif", normal = "freefont/FreeSerif.ttf" },
}

local MARGENES = {
    { nombre = "Sin márgenes", lateral = 0, superior = 0, inferior = 0 },
    { nombre = "Estrechos", lateral = 5, superior = 5, inferior = 0 },
    { nombre = "Normales", lateral = 10, superior = 10, inferior = 0 },
    { nombre = "Amplios", lateral = 30, superior = 20, inferior = 15 },
}
local MARGEN_MAX, MARGEN_PASO = 60, 5
local LETRA_MIN, LETRA_MAX, LETRA_PASO = 14, 32, 2
local INTERLINEADOS = { 1.2, 1.3, 1.45, 1.6, 1.8, 2.0 }
-- el cuadro es más pequeño que un ButtonDialog normal para dejar ver el texto de detrás
local LETRA_BOTONES = 16 -- la de KOReader es 20
local ANCHO_CUADRO = 0.8 -- de la medida menor de la pantalla (KOReader usa 0.9)

local function clave(seccion)
    return "bsh_ajustes_" .. seccion
end

--- Ajustes guardados de una sección, completados con los valores iniciales.
function Ajustes.leer(seccion)
    local guardado = G_reader_settings:readSetting(clave(seccion))
    if not guardado and seccion == "biblia" then
        -- alfas 5–6 guardaban la letra, los márgenes y el interlineado del lector por separado
        local m = G_reader_settings:readSetting("bsh_margenes") or {}
        guardado = {
            letra = G_reader_settings:readSetting("bsh_letra"),
            lateral = m.lateral, superior = m.superior, inferior = m.inferior,
            interlineado = G_reader_settings:readSetting("bsh_interlineado"),
        }
    end
    local a = {}
    for k, v in pairs(INICIALES[seccion]) do
        if guardado and guardado[k] ~= nil then
            a[k] = guardado[k]
        else
            a[k] = v
        end
    end
    return a
end

function Ajustes.guardar(seccion, a)
    G_reader_settings:saveSetting(clave(seccion), a)
end

local function fuenteDe(a)
    for _, f in ipairs(FUENTES) do
        if f.clave == a.fuente then return f end
    end
    return FUENTES[1]
end

--- Reglas @font-face de la fuente elegida. Si falta el archivo normal, queda la predeterminada.
local function cssFuente(a)
    local f = fuenteDe(a)
    local base = lfs.currentdir() .. "/fonts/"
    if not f.normal or lfs.attributes(base .. f.normal, "mode") ~= "file" then return "" end
    local css = {}
    local function cara(archivo, extra)
        if archivo then
            css[#css + 1] = string.format("@font-face { font-family: 'LetraApp'; src: url('%s%s')%s }\n", base, archivo, extra)
        end
    end
    cara(f.normal, "")
    cara(f.negrita, "; font-weight: bold")
    cara(f.cursiva, "; font-style: italic")
    cara(f.negrita_cursiva, "; font-weight: bold; font-style: italic")
    css[#css + 1] = "body { font-family: 'LetraApp'; }\n"
    return table.concat(css)
end

--- Reglas que se añaden al final de la hoja de estilo de cada pantalla (la última regla gana;
-- las más concretas, como p.palabras del diccionario o p.nav del lector, se mantienen).
function Ajustes.css(a)
    return string.format("\nbody { line-height: %s; text-align: %s; }\n", a.interlineado, a.alineacion) .. cssFuente(a)
end

--- Tamaño de letra en píxeles del dispositivo.
function Ajustes.letra(a)
    return Screen:scaleBySize(a.letra)
end

--- Márgenes lateral, superior e inferior en píxeles del dispositivo.
function Ajustes.medidas(a)
    return Screen:scaleBySize(a.lateral), Screen:scaleBySize(a.superior), Screen:scaleBySize(a.inferior)
end

--- Nombre del juego de márgenes («Normales»…) o «Personalizados».
function Ajustes.nombreMargenes(a)
    for _, p in ipairs(MARGENES) do
        if p.lateral == a.lateral and p.superior == a.superior and p.inferior == a.inferior then
            return p.nombre
        end
    end
    return "Personalizados"
end

--- Cuadro de ajustes de fuentes: el tipo de letra de cada sección. Se aplica al momento.
-- @param o { seccion, en, al_cambiar }, como en Ajustes.dialogo
function Ajustes.dialogoFuentes(o)
    local seccion = o.seccion
    local a = Ajustes.leer(seccion)
    local dialogo
    local function pestana(s)
        return { text = (s == seccion and "✓ " or "") .. TITULOS[s], callback = function()
            if s == seccion then return end
            UIManager:close(dialogo)
            Ajustes.dialogoFuentes{ seccion = s, en = o.en, al_cambiar = o.al_cambiar }
        end }
    end
    local filas = { { pestana(ORDEN[1]), pestana(ORDEN[2]) } }
    for _, f in ipairs(FUENTES) do
        filas[#filas + 1] = { { text = (f.clave == a.fuente and "✓ " or "") .. f.nombre, callback = function()
            UIManager:close(dialogo)
            a.fuente = f.clave
            Ajustes.guardar(seccion, a)
            if o.al_cambiar then o.al_cambiar(seccion) end
            Ajustes.dialogoFuentes(o)
        end } }
    end
    filas[#filas + 1] = { { text = "Cerrar", callback = function() UIManager:close(dialogo) end } }
    local titulo = "Ajustes de fuentes · " .. TITULOS[seccion]
    if o.en ~= seccion then
        titulo = titulo .. "\nEl resultado se verá al abrir un comentario, un diccionario o las notas."
    end
    dialogo = ButtonDialog:new{
        title = titulo,
        title_align = "center",
        info_face = Font:getFace("x_smallinfofont"),
        width_factor = ANCHO_CUADRO,
        buttons = filas,
    }
    UIManager:show(dialogo)
end

--- Cuadro de ajustes de lectura.
-- @param o { seccion = "biblia"|"modulos" (la que se muestra),
--            en = "biblia"|"modulos" (la pantalla desde la que se abre),
--            al_cambiar = function(seccion) (se llama tras guardar cada cambio) }
function Ajustes.dialogo(o)
    local seccion = o.seccion
    local a = Ajustes.leer(seccion)
    local dialogo

    local function aplicar(cambio)
        return function()
            UIManager:close(dialogo)
            cambio()
            Ajustes.guardar(seccion, a)
            if o.al_cambiar then o.al_cambiar(seccion) end
            Ajustes.dialogo(o)
        end
    end
    local function pestana(s)
        return { text = (s == seccion and "✓ " or "") .. TITULOS[s], callback = function()
            if s == seccion then return end
            UIManager:close(dialogo)
            Ajustes.dialogo{ seccion = s, en = o.en, al_cambiar = o.al_cambiar }
        end }
    end
    -- fila «− etiqueta valor +» para un número con límites
    local function fila(etiqueta, valor, minimo, maximo, al_poner)
        return {
            { text = "−", enabled = valor > minimo, callback = aplicar(function() al_poner(-1) end) },
            { text = etiqueta .. " " .. valor, enabled = false },
            { text = "+", enabled = valor < maximo, callback = aplicar(function() al_poner(1) end) },
        }
    end
    local function filaMargen(etiqueta, k)
        return fila(etiqueta, a[k], 0, MARGEN_MAX, function(signo)
            a[k] = math.max(0, math.min(MARGEN_MAX, a[k] + signo * MARGEN_PASO))
        end)
    end

    local predefinidos = {}
    local actual = Ajustes.nombreMargenes(a)
    for _, p in ipairs(MARGENES) do
        predefinidos[#predefinidos + 1] = { text = (p.nombre == actual and "✓ " or "") .. p.nombre,
            callback = aplicar(function()
                a.lateral, a.superior, a.inferior = p.lateral, p.superior, p.inferior
            end) }
    end
    -- posición del interlineado en la lista (el más cercano, por si se guardó otro valor)
    local i_lin = 1
    for i, v in ipairs(INTERLINEADOS) do
        if math.abs(v - a.interlineado) < math.abs(INTERLINEADOS[i_lin] - a.interlineado) then i_lin = i end
    end
    local function alineacion(valor, texto)
        return { text = (a.alineacion == valor and "✓ " or "") .. texto, callback = aplicar(function()
            a.alineacion = valor
        end) }
    end

    local titulo = "Ajustes de lectura · " .. TITULOS[seccion]
    if o.en ~= seccion then
        if seccion == "modulos" then
            titulo = titulo .. "\nPara ver el resultado, abre un comentario, un diccionario o las notas y usa allí «Ajustes de lectura…»."
        else
            titulo = titulo .. "\nEl resultado se verá al volver al texto bíblico."
        end
    end

    local filas = {
            { pestana(ORDEN[1]), pestana(ORDEN[2]) },
            fila("Letra", a.letra, LETRA_MIN, LETRA_MAX, function(signo)
                a.letra = math.max(LETRA_MIN, math.min(LETRA_MAX, a.letra + signo * LETRA_PASO))
            end),
            predefinidos,
            filaMargen("Laterales", "lateral"),
            filaMargen("Arriba", "superior"),
            filaMargen("Abajo", "inferior"),
            fila("Interlineado", INTERLINEADOS[i_lin], INTERLINEADOS[1], INTERLINEADOS[#INTERLINEADOS], function(signo)
                a.interlineado = INTERLINEADOS[math.max(1, math.min(#INTERLINEADOS, i_lin + signo))]
            end),
            { alineacion("justify", "Justificado"), alineacion("left", "A la izquierda") },
            {
                { text = "Valores iniciales", callback = aplicar(function()
                    for k, v in pairs(INICIALES[seccion]) do a[k] = v end
                end) },
                { text = "Cerrar", callback = function() UIManager:close(dialogo) end },
            },
    }
    -- letra más pequeña y sin negrita, salvo la pestaña elegida
    for i, f in ipairs(filas) do
        for _, b in ipairs(f) do
            b.font_size = LETRA_BOTONES
            b.font_bold = i == 1 and b.text:sub(1, 3) == "✓"
        end
    end
    dialogo = ButtonDialog:new{
        title = titulo,
        title_align = "center",
        info_face = Font:getFace("x_smallinfofont"),
        width_factor = ANCHO_CUADRO,
        buttons = filas,
    }
    UIManager:show(dialogo)
end

return Ajustes
