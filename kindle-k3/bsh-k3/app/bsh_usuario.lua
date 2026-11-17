--[[--
Datos del usuario: listas de favoritos y notas.

Base aparte de la Biblia (que es de solo lectura), en settings/bsh_usuario.sqlite:
    listas(id, nombre UNIQUE, creada)
    favoritos(id, lista_id, libro, capitulo, verso, creado)  -- UNIQUE(lista_id, libro, capitulo, verso)
    notas(id, titulo, cuerpo, libro, capitulo, verso_desde, verso_hasta, creada, editada)
        libro NULL = nota libre; verso_desde NULL = nota del capítulo; cuerpo con marcas (bsh_marcas)
        Es la tabla anterior a BSH Notes: ya no se escribe y queda como copia original.
    notas_fts  FTS5(titulo, cuerpo) con contenido externo en notas, al día con triggers
    notas_idx  índice de los .md de BSH Notes (mismas columnas, más ruta, mtime y tam)
    notas_idx_fts  FTS5 con contenido externo en notas_idx
    respaldos  hasta RESPALDOS copias por nota, que solo cambian cuando el usuario lo pide

Las notas viven en los .md de BSH Notes (bsh_exportar). El índice se rehace a partir de
ellos, así que nunca es la única copia de nada.
--]]--

local DataStorage = require("datastorage")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local DB = require("bsh_db")
local Exportar = require("bsh_exportar")
local Marcas = require("bsh_marcas")

local RESPALDOS = 3 -- copias que se guardan de cada nota

local ESQUEMA = {
    [[CREATE TABLE IF NOT EXISTS listas (
        id INTEGER PRIMARY KEY,
        nombre TEXT NOT NULL UNIQUE,
        creada INTEGER NOT NULL DEFAULT (strftime('%s','now')))]],
    [[CREATE TABLE IF NOT EXISTS favoritos (
        id INTEGER PRIMARY KEY,
        lista_id INTEGER NOT NULL REFERENCES listas(id) ON DELETE CASCADE,
        libro INTEGER NOT NULL, capitulo INTEGER NOT NULL, verso INTEGER NOT NULL,
        creado INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        UNIQUE (lista_id, libro, capitulo, verso))]],
    [[CREATE INDEX IF NOT EXISTS idx_favoritos_ref ON favoritos(libro, capitulo, verso)]],
    [[CREATE TABLE IF NOT EXISTS notas (
        id INTEGER PRIMARY KEY,
        titulo TEXT NOT NULL, cuerpo TEXT NOT NULL,
        libro INTEGER, capitulo INTEGER, verso_desde INTEGER, verso_hasta INTEGER,
        creada INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        editada INTEGER NOT NULL DEFAULT (strftime('%s','now')))]],
    [[CREATE INDEX IF NOT EXISTS idx_notas_ref ON notas(libro, capitulo, verso_desde)]],
    [[CREATE VIRTUAL TABLE IF NOT EXISTS notas_fts USING fts5(titulo, cuerpo, content='notas', content_rowid='id')]],
    [[CREATE TRIGGER IF NOT EXISTS notas_ai AFTER INSERT ON notas BEGIN
        INSERT INTO notas_fts(rowid, titulo, cuerpo) VALUES (new.id, new.titulo, new.cuerpo);
    END]],
    [[CREATE TRIGGER IF NOT EXISTS notas_ad AFTER DELETE ON notas BEGIN
        INSERT INTO notas_fts(notas_fts, rowid, titulo, cuerpo) VALUES ('delete', old.id, old.titulo, old.cuerpo);
    END]],
    [[CREATE TRIGGER IF NOT EXISTS notas_au AFTER UPDATE ON notas BEGIN
        INSERT INTO notas_fts(notas_fts, rowid, titulo, cuerpo) VALUES ('delete', old.id, old.titulo, old.cuerpo);
        INSERT INTO notas_fts(rowid, titulo, cuerpo) VALUES (new.id, new.titulo, new.cuerpo);
    END]],
    [[CREATE TABLE IF NOT EXISTS notas_idx (
        id INTEGER PRIMARY KEY, ruta TEXT NOT NULL UNIQUE, mtime INTEGER, tam INTEGER,
        titulo TEXT NOT NULL, cuerpo TEXT NOT NULL,
        libro INTEGER, capitulo INTEGER, verso_desde INTEGER, verso_hasta INTEGER,
        creada INTEGER, editada INTEGER)]],
    [[CREATE INDEX IF NOT EXISTS idx_notas_idx_ref ON notas_idx(libro, capitulo, verso_desde)]],
    [[CREATE VIRTUAL TABLE IF NOT EXISTS notas_idx_fts USING fts5(titulo, cuerpo, content='notas_idx', content_rowid='id')]],
    [[CREATE TRIGGER IF NOT EXISTS notas_idx_ai AFTER INSERT ON notas_idx BEGIN
        INSERT INTO notas_idx_fts(rowid, titulo, cuerpo) VALUES (new.id, new.titulo, new.cuerpo);
    END]],
    [[CREATE TRIGGER IF NOT EXISTS notas_idx_ad AFTER DELETE ON notas_idx BEGIN
        INSERT INTO notas_idx_fts(notas_idx_fts, rowid, titulo, cuerpo) VALUES ('delete', old.id, old.titulo, old.cuerpo);
    END]],
    [[CREATE TABLE IF NOT EXISTS respaldos (
        id INTEGER PRIMARY KEY, nota_id INTEGER NOT NULL,
        titulo TEXT NOT NULL, cuerpo TEXT NOT NULL,
        libro INTEGER, capitulo INTEGER, verso_desde INTEGER, verso_hasta INTEGER,
        creada INTEGER, editada INTEGER,
        fecha INTEGER NOT NULL DEFAULT (strftime('%s','now')))]],
    [[CREATE INDEX IF NOT EXISTS idx_respaldos_nota ON respaldos(nota_id)]],
}

local Usuario = {}
Usuario.__index = Usuario

--- Abre la base. Sin ruta usa la de la app; BSH Text Editor le pasa la suya.
function Usuario.abrir(ruta)
    ruta = ruta or (DataStorage:getSettingsDir() .. "/bsh_usuario.sqlite")
    local db, err = DB.abrir(ruta, "rwc")
    if not db then return nil, err end
    for _, sql in ipairs(ESQUEMA) do
        db:ejecutar(sql)
    end
    local self = setmetatable({ db = db, carpeta = Exportar.carpeta() }, Usuario)
    -- si los archivos fallan, los favoritos siguen funcionando
    local ok, fallo = pcall(function()
        self:migrar()
        self:sincronizar()
    end)
    if not ok then logger.warn("[BSH] no se pudieron preparar las notas:", fallo) end
    return self
end

function Usuario:cerrar()
    if self.db then
        self.db:cerrar()
        self.db = nil
    end
end

--- Listas con su número de versículos y si contienen la referencia dada:
-- { { id, nombre, total, contiene }, ... } por nombre.
function Usuario:listas(libro, cap, verso)
    local filas = self.db:filas([[
        SELECT l.id, l.nombre, count(f.id),
               sum(CASE WHEN f.libro = ? AND f.capitulo = ? AND f.verso = ? THEN 1 ELSE 0 END)
        FROM listas l LEFT JOIN favoritos f ON f.lista_id = l.id
        GROUP BY l.id ORDER BY l.nombre]], libro or 0, cap or 0, verso or 0)
    local out = {}
    for _, f in ipairs(filas) do
        out[#out + 1] = { id = f[1], nombre = f[2], total = f[3], contiene = (f[4] or 0) > 0 }
    end
    return out
end

--- Crea una lista (o devuelve la existente con ese nombre). Devuelve su id.
function Usuario:crearLista(nombre)
    self.db:ejecutar("INSERT OR IGNORE INTO listas(nombre) VALUES (?)", nombre)
    return self.db:filas("SELECT id FROM listas WHERE nombre = ?", nombre)[1][1]
end

function Usuario:agregar(lista_id, libro, cap, verso)
    self.db:ejecutar("INSERT OR IGNORE INTO favoritos(lista_id, libro, capitulo, verso) VALUES (?, ?, ?, ?)",
        lista_id, libro, cap, verso)
    logger.info("[BSH] favorito añadido", lista_id, libro, cap, verso)
end

function Usuario:quitar(lista_id, libro, cap, verso)
    self.db:ejecutar("DELETE FROM favoritos WHERE lista_id = ? AND libro = ? AND capitulo = ? AND verso = ?",
        lista_id, libro, cap, verso)
    logger.info("[BSH] favorito quitado", lista_id, libro, cap, verso)
end

--- En cuántas listas está un versículo; con verso nil, cuántos favoritos hay en el capítulo.
function Usuario:contar(libro, cap, verso)
    if verso then
        return self.db:filas("SELECT count(*) FROM favoritos WHERE libro = ? AND capitulo = ? AND verso = ?",
            libro, cap, verso)[1][1]
    end
    return self.db:filas("SELECT count(*) FROM favoritos WHERE libro = ? AND capitulo = ?", libro, cap)[1][1]
end

--- Todos los favoritos agrupados por lista: { { nombre, versos = { {libro, cap, verso}, ... } }, ... }
function Usuario:todo()
    local filas = self.db:filas([[
        SELECT l.nombre, f.libro, f.capitulo, f.verso
        FROM listas l LEFT JOIN favoritos f ON f.lista_id = l.id
        ORDER BY l.nombre, f.libro, f.capitulo, f.verso]])
    local out, actual = {}, nil
    for _, f in ipairs(filas) do
        if not actual or actual.nombre ~= f[1] then
            actual = { nombre = f[1], versos = {} }
            out[#out + 1] = actual
        end
        if f[2] then
            actual.versos[#actual.versos + 1] = { f[2], f[3], f[4] }
        end
    end
    return out
end

--- Notas -----------------------------------------------------------------------------

local COLUMNAS_NOTA = "id, titulo, cuerpo, libro, capitulo, verso_desde, verso_hasta, creada, editada"

local function nota(f)
    return { id = f[1], titulo = f[2], cuerpo = f[3], libro = f[4], capitulo = f[5],
             verso = f[6], verso_hasta = f[7], creada = f[8], editada = f[9] }
end

local function notas(filas)
    local out = {}
    for _, f in ipairs(filas) do out[#out + 1] = nota(f) end
    return out
end

--- Ejecuta f en una transacción. Devuelve lo que devuelva f; si falla, deshace y repite el error.
function Usuario:_transaccion(f)
    self.db:ejecutar("BEGIN")
    local ok, res = pcall(f)
    self.db:ejecutar(ok and "COMMIT" or "ROLLBACK")
    if not ok then error(res) end
    return res
end

--- Un id que no haya usado ninguna nota, ni siquiera una borrada que conserve respaldo.
function Usuario:_nuevoId()
    return self.db:filas([[SELECT max(coalesce((SELECT max(id) FROM notas), 0),
        coalesce((SELECT max(id) FROM notas_idx), 0),
        coalesce((SELECT max(nota_id) FROM respaldos), 0)) + 1]])[1][1]
end

function Usuario:_rutaDe(id)
    local f = self.db:filas("SELECT ruta FROM notas_idx WHERE id = ?", id)[1]
    return f and f[1]
end

--- Pone un .md en el índice. Devuelve su id, o nil si no se pudo leer.
function Usuario:_indexar(ruta, usados)
    local cab, cuerpo = Exportar.leer(ruta)
    if not cuerpo then return nil end
    local atributos = lfs.attributes(ruta)
    local id = cab and tonumber(cab.id)
    local n = {
        id = id, cuerpo = cuerpo,
        libro = cab and tonumber(cab.libro), capitulo = cab and tonumber(cab.capitulo),
        verso = cab and tonumber(cab.verso), verso_hasta = cab and tonumber(cab.verso_hasta),
        creada = cab and Exportar.aSegundos(cab.creada) or atributos.modification,
        editada = cab and Exportar.aSegundos(cab.editada) or atributos.modification,
    }
    -- un .md sin cabecera, o la copia de otra nota hecha en el PC, recibe un id propio
    if not id or (usados and usados[id]) then
        n.id = self:_nuevoId()
        if not n.libro then n.capitulo, n.verso, n.verso_hasta = nil, nil, nil end
        local ok, err = Exportar.escribir(ruta, Exportar.contenido(n))
        if not ok then
            logger.warn("[BSH] no se pudo preparar", ruta, err)
            return nil
        end
        atributos = lfs.attributes(ruta)
    end
    if usados then usados[n.id] = true end
    self.db:ejecutar("DELETE FROM notas_idx WHERE id = ? OR ruta = ?", n.id, ruta)
    self.db:ejecutar([[INSERT INTO notas_idx(id, ruta, mtime, tam, titulo, cuerpo, libro, capitulo,
        verso_desde, verso_hasta, creada, editada) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        n.id, ruta, atributos.modification, atributos.size, Marcas.titulo(cuerpo), cuerpo,
        n.libro, n.capitulo, n.verso, n.verso_hasta, n.creada, n.editada)
    return n.id
end

--- Pone al día el índice con la carpeta. Devuelve true si algo cambió.
function Usuario:sincronizar()
    if lfs.attributes(self.carpeta, "mode") ~= "directory" and not lfs.mkdir(self.carpeta) then
        return false
    end
    local conocidas = {}
    for _, f in ipairs(self.db:filas("SELECT ruta, id, mtime, tam FROM notas_idx")) do
        conocidas[f[1]] = { id = f[2], mtime = f[3], tam = f[4] }
    end
    local usados, cambiadas = {}, {}
    for archivo in lfs.dir(self.carpeta) do
        if archivo:match("%.md$") and archivo:sub(1, 1) ~= "." then
            local ruta = self.carpeta .. "/" .. archivo
            local a = lfs.attributes(ruta)
            local c = conocidas[ruta]
            if a and a.mode == "file" then
                if c and c.mtime == a.modification and c.tam == a.size then
                    usados[c.id] = true
                else
                    cambiadas[#cambiadas + 1] = ruta
                end
                if c then c.visto = true end
            end
        end
    end
    local faltan = {}
    for ruta, c in pairs(conocidas) do
        if not c.visto then faltan[#faltan + 1] = ruta end
    end
    if #cambiadas == 0 and #faltan == 0 then return false end
    self:_transaccion(function()
        for _, ruta in ipairs(faltan) do
            self.db:ejecutar("DELETE FROM notas_idx WHERE ruta = ?", ruta)
        end
        table.sort(cambiadas)
        for _, ruta in ipairs(cambiadas) do self:_indexar(ruta, usados) end
    end)
    logger.info("[BSH] notas:", #cambiadas, "archivos leídos,", #faltan, "quitados del índice")
    return true
end

--- Primera vez: pasa la tabla antigua a .md y guarda el primer respaldo de cada nota.
-- Si algún archivo falla no se marca como hecho y se reintenta en la siguiente apertura.
function Usuario:migrar()
    if self.db:filas("SELECT count(*) FROM respaldos")[1][1] > 0 then return end
    local lista = notas(self.db:filas("SELECT " .. COLUMNAS_NOTA .. " FROM notas"))
    if #lista == 0 then return end
    local r = Exportar.exportar(lista, self.carpeta)
    if not r or r.errores > 0 then return end
    self.db:ejecutar([[INSERT INTO respaldos(nota_id, titulo, cuerpo, libro, capitulo, verso_desde,
        verso_hasta, creada, editada) SELECT ]] .. COLUMNAS_NOTA .. " FROM notas")
end

--- Guarda una nota en su .md: con n.id la actualiza; si no, la crea.
-- n = { titulo, cuerpo, libro, capitulo, verso }  (libro nil = nota libre; verso nil = del capítulo)
-- n.subtitulo y n.interlineado son opcionales: van en la cabecera; sin ellos, conserva los que tenga.
-- @return el id, o nil y el error (la nota no se guardó).
function Usuario:guardarNota(n)
    local ahora = os.time()
    local ruta = n.id and self:_rutaDe(n.id)
    if ruta then
        local ok, err = Exportar.reemplazarCuerpo(ruta, n.cuerpo, ahora, n.subtitulo, { interlineado = n.interlineado })
        if not ok then return nil, err end
    else
        if lfs.attributes(self.carpeta, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(self.carpeta)
            if not ok then return nil, err end
        end
        n.id = n.id or self:_nuevoId()
        n.creada, n.editada = n.creada or ahora, ahora
        ruta = Exportar.rutaNueva(self.carpeta, n)
        local ok, err = Exportar.escribir(ruta, Exportar.contenido(n))
        if not ok then return nil, err end
    end
    local id = self:_indexar(ruta)
    if not id then return nil, "no se pudo leer " .. ruta end
    logger.info("[BSH] nota guardada", id)
    return id
end

--- Borra el .md de una nota. Sus respaldos se conservan; si cambió desde el último, deja una copia.
function Usuario:borrarNota(id)
    local n = self:nota(id)
    local ruta = self:_rutaDe(id)
    if not n or not ruta then return end
    if self:cambiada(n) then Exportar.copia(ruta, self.carpeta) end
    os.remove(ruta)
    self.db:ejecutar("DELETE FROM notas_idx WHERE id = ?", id)
    logger.info("[BSH] nota borrada", id)
end

--- Ruta libre en dir para el archivo: con un número detrás si el nombre ya está ocupado.
local function rutaLibre(dir, archivo)
    local base = archivo:gsub("%.md$", "")
    local ruta, i = dir .. "/" .. archivo, 1
    while lfs.attributes(ruta, "mode") do
        i = i + 1
        ruta = dir .. "/" .. base .. " (" .. i .. ").md"
    end
    return ruta
end

--- Mueve el .md de una nota a la papelera. Devuelve true, o nil y el error.
function Usuario:aPapelera(id)
    local ruta = self:_rutaDe(id)
    if not ruta then return nil, "la nota no tiene archivo" end
    local dir = self.carpeta .. "/" .. Exportar.PAPELERA
    if lfs.attributes(dir, "mode") ~= "directory" then
        local ok, err = lfs.mkdir(dir)
        if not ok then return nil, err end
    end
    local ok, err = os.rename(ruta, rutaLibre(dir, ruta:match("[^/]+$")))
    if not ok then return nil, err end
    self.db:ejecutar("DELETE FROM notas_idx WHERE id = ?", id)
    logger.info("[BSH] nota en la papelera", id)
    return true
end

--- Notas de la papelera, con los campos de una nota más su ruta.
function Usuario:papelera()
    local dir = self.carpeta .. "/" .. Exportar.PAPELERA
    local out = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return out end
    for archivo in lfs.dir(dir) do
        if archivo:match("%.md$") and archivo:sub(1, 1) ~= "." then
            local ruta = dir .. "/" .. archivo
            local cab, cuerpo = Exportar.leer(ruta)
            if cuerpo then
                cab = cab or {}
                out[#out + 1] = {
                    ruta = ruta, id = tonumber(cab.id) or 0, titulo = Marcas.titulo(cuerpo), cuerpo = cuerpo,
                    libro = tonumber(cab.libro), capitulo = tonumber(cab.capitulo), verso = tonumber(cab.verso),
                    editada = cab.editada and Exportar.aSegundos(cab.editada) or lfs.attributes(ruta, "modification"),
                }
            end
        end
    end
    return out
end

--- Devuelve a la carpeta una nota de la papelera. Si otra nota tomó su id, sincronizar le da uno nuevo.
function Usuario:sacarDePapelera(ruta)
    local ok, err = os.rename(ruta, rutaLibre(self.carpeta, ruta:match("[^/]+$")))
    if not ok then return nil, err end
    self:sincronizar()
    return true
end

--- Borra para siempre una nota de la papelera, con todas las copias que la base guarde de ella.
function Usuario:eliminarDefinitivo(ruta)
    local cab = Exportar.leer(ruta)
    local ok, err = os.remove(ruta)
    if not ok then return nil, err end
    local id = cab and tonumber(cab.id)
    if id and not self:nota(id) then
        self.db:ejecutar("DELETE FROM respaldos WHERE nota_id = ?", id)
        local function borrarCopia() self.db:ejecutar("DELETE FROM notas WHERE id = ?", id) end
        if not pcall(borrarCopia) then -- notas_fts desfasado: el borrado falla hasta rehacerlo
            local rehecho, fallo = pcall(function()
                self.db:ejecutar("INSERT INTO notas_fts(notas_fts) VALUES ('rebuild')")
                borrarCopia()
            end)
            if not rehecho then logger.warn("[BSH] queda la copia antigua de la nota", id, fallo) end
        end
    end
    logger.info("[BSH] nota eliminada definitivamente", id)
    return true
end

function Usuario:nota(id)
    local f = self.db:filas("SELECT " .. COLUMNAS_NOTA .. " FROM notas_idx WHERE id = ?", id)[1]
    return f and nota(f)
end

--- Notas de un versículo (incluye las de un pasaje que lo abarque) o, con verso nil,
-- todas las del capítulo (de versículo y de capítulo). Las más recientes primero.
function Usuario:notasDe(libro, cap, verso)
    if verso then
        return notas(self.db:filas("SELECT " .. COLUMNAS_NOTA .. [[ FROM notas_idx
            WHERE libro = ? AND capitulo = ? AND ? BETWEEN verso_desde AND coalesce(verso_hasta, verso_desde)
            ORDER BY editada DESC]], libro, cap, verso))
    end
    return notas(self.db:filas("SELECT " .. COLUMNAS_NOTA .. [[ FROM notas_idx
        WHERE libro = ? AND capitulo = ? ORDER BY coalesce(verso_desde, 0), editada DESC]], libro, cap))
end

function Usuario:todasLasNotas()
    return notas(self.db:filas("SELECT " .. COLUMNAS_NOTA .. " FROM notas_idx ORDER BY editada DESC"))
end

--- Búsqueda de texto en título y cuerpo (FTS5). consulta ya en sintaxis FTS5.
function Usuario:buscarNotas(consulta)
    local ok, filas = pcall(self.db.filas, self.db, "SELECT " .. COLUMNAS_NOTA:gsub("([%a_]+)", "n.%1") .. [[
        FROM notas_idx_fts JOIN notas_idx n ON n.id = notas_idx_fts.rowid
        WHERE notas_idx_fts MATCH ? ORDER BY rank]], consulta)
    if not ok then
        logger.warn("[BSH] error buscando notas:", consulta, filas)
        return {}
    end
    return notas(filas)
end

function Usuario:contarNotas(libro, cap, verso)
    if verso then
        return self.db:filas([[SELECT count(*) FROM notas_idx WHERE libro = ? AND capitulo = ?
            AND ? BETWEEN verso_desde AND coalesce(verso_hasta, verso_desde)]], libro, cap, verso)[1][1]
    end
    return self.db:filas("SELECT count(*) FROM notas_idx WHERE libro = ? AND capitulo = ?", libro, cap)[1][1]
end

--- Versículos del capítulo que tienen nota: { [verso] = true } (para marcarlos en el texto).
function Usuario:versosConNota(libro, cap)
    local out = {}
    for _, f in ipairs(self.db:filas([[SELECT verso_desde, coalesce(verso_hasta, verso_desde) FROM notas_idx
        WHERE libro = ? AND capitulo = ? AND verso_desde IS NOT NULL]], libro, cap)) do
        for v = f[1], f[2] do out[v] = true end
    end
    return out
end

--- Respaldos --------------------------------------------------------------------------

local COLUMNAS_RESPALDO = "id, nota_id, titulo, cuerpo, libro, capitulo, verso_desde, verso_hasta, creada, editada, fecha"

local function respaldo(f)
    return { id = f[1], nota_id = f[2], titulo = f[3], cuerpo = f[4], libro = f[5], capitulo = f[6],
             verso = f[7], verso_hasta = f[8], creada = f[9], editada = f[10], fecha = f[11] }
end

--- Sin los espacios de los extremos: el .md añade un salto final que no es un cambio de la nota.
local function limpio(cuerpo)
    return ((cuerpo or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Respaldos de una nota, del más reciente al más antiguo.
function Usuario:respaldos(id)
    local out = {}
    for _, f in ipairs(self.db:filas("SELECT " .. COLUMNAS_RESPALDO
        .. " FROM respaldos WHERE nota_id = ? ORDER BY id DESC", id)) do
        out[#out + 1] = respaldo(f)
    end
    return out
end

--- ¿La nota difiere de su último respaldo (o no tiene)?
function Usuario:cambiada(n)
    local r = self:respaldos(n.id)[1]
    return not r or limpio(r.cuerpo) ~= limpio(n.cuerpo)
end

function Usuario:notasCambiadas()
    local out = {}
    for _, n in ipairs(self:todasLasNotas()) do
        if self:cambiada(n) then out[#out + 1] = n end
    end
    return out
end

--- Añade un respaldo y deja solo los RESPALDOS más recientes de la nota.
function Usuario:respaldar(n)
    self.db:ejecutar([[INSERT INTO respaldos(nota_id, titulo, cuerpo, libro, capitulo, verso_desde,
        verso_hasta, creada, editada) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        n.id, n.titulo, n.cuerpo, n.libro, n.capitulo, n.verso, n.verso_hasta, n.creada, n.editada)
    self.db:ejecutar(string.format([[DELETE FROM respaldos WHERE nota_id = ? AND id NOT IN
        (SELECT id FROM respaldos WHERE nota_id = ? ORDER BY id DESC LIMIT %d)]], RESPALDOS), n.id, n.id)
end

--- Copia del .md actual en Copias, sin tocar el respaldo. Devuelve su ruta, o nil y el error.
function Usuario:copiaTemporal(n)
    local ruta = self:_rutaDe(n.id)
    if not ruta then return nil, "la nota no tiene archivo" end
    return Exportar.copia(ruta, self.carpeta)
end

--- Vuelve al contenido de un respaldo. Antes copia la versión actual, para poder deshacerlo.
function Usuario:restaurar(n, r)
    if self:cambiada(n) then
        local ok, err = self:copiaTemporal(n)
        if not ok then return nil, err end
    end
    return self:guardarNota{ id = n.id, cuerpo = r.cuerpo }
end

--- Campos de la cabecera del .md de una nota (subtitulo, autor…).
function Usuario:cabecera(id)
    local ruta = self:_rutaDe(id)
    return ruta and Exportar.leer(ruta) or {}
end

--- Notas borradas que conservan respaldo: el último de cada una, los más recientes primero.
function Usuario:notasSinArchivo()
    local out = {}
    for _, f in ipairs(self.db:filas("SELECT " .. COLUMNAS_RESPALDO .. [[ FROM respaldos r
        WHERE id = (SELECT max(id) FROM respaldos WHERE nota_id = r.nota_id)
          AND nota_id NOT IN (SELECT id FROM notas_idx)
        ORDER BY id DESC LIMIT 12]])) do
        out[#out + 1] = respaldo(f)
    end
    return out
end

--- Crea de nuevo el .md de una nota borrada a partir de su respaldo.
function Usuario:recuperar(r)
    return self:guardarNota{ id = r.nota_id, titulo = r.titulo, cuerpo = r.cuerpo, libro = r.libro,
        capitulo = r.capitulo, verso = r.verso, verso_hasta = r.verso_hasta, creada = r.creada }
end

return Usuario
