--[[--
Servidor web para compartir archivos por Wi-Fi: desde el navegador de un PC o un celular en la
misma red se ven las carpetas del Kindle (/mnt/us), y se descargan y se suben archivos.

Usa el servidor TCP de KOReader (ui/message/simpletcpserver), que entrega las cabeceras de cada
petición; el cuerpo de una subida se lee aquí. Para entrar hay que escribir el código de 4 cifras
que muestra el Kindle; luego una cookie lo recuerda. En el Kindle abre el puerto en su cortafuegos
mientras está encendido, como el plugin HTTP Inspector.

    GET  /                       página con la carpeta ?d=/ruta
    GET  /entrar?pin=1234        comprueba el código
    GET  /archivo?r=/ruta        descarga un archivo
    PUT  /subir?d=/ruta&n=nombre sube un archivo (409 si ya existe, salvo con &reemplazar=1)

Como teclado remoto (o.teclado), en lugar de los archivos sirve una página para escribir:

    GET  /                       página del teclado
    POST /teclado                lo escrito: texto y, para las teclas, estos caracteres de control:
                                 \b borrar, \2 ←, \3 →, \4 ↑, \5 ↓ (Enter llega como \n)

Para recibir un paquete (o.paquete = function(ruta, nombre), con o.destino), sirve una página para
subir un solo archivo, que se guarda en o.destino:

    GET  /                       página para elegir el archivo
    PUT  /paquete                el archivo (hasta MAX_PAQUETE bytes); X-Nombre: su nombre

    GET  /estado                 avance de lo que hace el Kindle con el archivo (JSON, ver progresar)
                                 y si el servidor se va a cerrar (ver anunciarCierre); la página lo
                                 consulta todo el tiempo y, si se cierra o deja de responder, avisa
                                 que hay que volver a activar el servidor en el Kindle

La página se ajusta con o.pagina = { aceptar = ".tar", elegir, ayuda, recibido, varios } (ver
paginaPaquete): sirve para las actualizaciones, importar módulos y un documento de Word. Muestra una
barra mientras se envía y luego otra con el avance que la app informa con servidor:progresar().

o.marca = { nombre, logo (SVG) } cambia la cabecera de las páginas (Bible Study Hub - Wifi Server).
--]]--

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

M.PUERTOS = { 8080, 8081, 8082, 8090 } -- se usa el primero libre
local TROZO = 65536
local ESPERA = 10 -- segundos sin datos antes de dar por perdida una conexión
local MAX_PAQUETE = 64 * 1024 * 1024

local ESTADOS = { [200] = "OK", [302] = "Found", [400] = "Bad Request", [403] = "Forbidden",
    [404] = "Not Found", [409] = "Conflict", [411] = "Length Required", [500] = "Internal Server Error" }

--- Texto y direcciones ---------------------------------------------------------------

local function html(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--- %XX y + → texto.
function M.decodificar(s)
    return ((s or ""):gsub("%+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Texto → parte de una dirección.
function M.codificar(s)
    return (s:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function consulta(q)
    local t = {}
    for par in (q or ""):gmatch("[^&]+") do
        local k, v = par:match("^([^=]*)=?(.*)$")
        t[M.decodificar(k)] = M.decodificar(v)
    end
    return t
end

--- Ruta relativa a la raíz, limpia: empieza por / y no sube con «..». nil si no es válida.
function M.limpiarRuta(r)
    r = r or "/"
    if r:find("\0", 1, true) or r:find("\\", 1, true) then return nil end
    local partes = {}
    for p in r:gmatch("[^/]+") do
        if p == ".." then return nil end
        if p ~= "." then partes[#partes + 1] = p end
    end
    return "/" .. table.concat(partes, "/")
end

--- Nombre de archivo que acepta FAT32, sin carpetas. nil si queda vacío.
function M.limpiarNombre(n)
    n = (n or ""):gsub("^.*[/\\]", ""):gsub("[%c]", ""):gsub('[:%*%?"<>|]', "_")
    n = n:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    return n ~= "" and n or nil
end

local function tamano(b)
    if b < 1024 then return string.format("%d B", b) end
    if b < 1024 * 1024 then return string.format("%.0f KB", b / 1024) end
    return string.format("%.1f MB", b / 1024 / 1024)
end

--- Peticiones ----------------------------------------------------------------------------

--- Texto de las cabeceras → { metodo, ruta, consulta, cabeceras }, o nil.
function M.leerPeticion(texto)
    local metodo, destino = texto:match("^(%u+) (%S+) HTTP/")
    if not metodo then return nil end
    local ruta, q = destino:match("^([^?]*)%??(.*)$")
    local cab = {}
    for linea in texto:gmatch("[^\r\n]+") do
        local k, v = linea:match("^([%w%-]+):%s*(.-)%s*$")
        if k then cab[k:lower()] = v end
    end
    return { metodo = metodo, ruta = ruta, consulta = consulta(q), cabeceras = cab }
end

local Servidor = {}
Servidor.__index = Servidor

--- o: { raiz = "/mnt/us", al_evento = function(texto) (opcional) }
-- o con teclado = function(texto) en lugar de raiz: es un teclado remoto, sin archivos.
-- o con paquete = function(ruta, nombre), destino y titulo: recibe un solo archivo (una
-- actualización, un documento); pagina: los textos de su página (ver paginaPaquete).
function M.nuevo(o)
    local s = setmetatable({ raiz = o.raiz, teclado = o.teclado, al_evento = o.al_evento,
        paquete = o.paquete, destino = o.destino, titulo = o.titulo, detalle = o.detalle,
        pagina = o.pagina, marca = o.marca, progreso = { id = 0 } }, Servidor)
    math.randomseed(os.time() + math.floor((os.clock() % 1) * 1e6))
    s.pin = string.format("%04d", math.random(0, 9999))
    local t = {}
    for i = 1, 16 do t[i] = string.format("%x", math.random(0, 15)) end
    s.clave = table.concat(t)
    return s
end

--- Envía todo, aunque el socket acepte solo una parte cada vez.
local function enviar(cliente, datos)
    local i = 1
    while i <= #datos do
        local ultimo, err, parcial = cliente:send(datos, i)
        ultimo = ultimo or parcial
        if not ultimo or ultimo < i then return nil, err end
        i = ultimo + 1
        if err and err ~= "timeout" then return nil, err end
    end
    return true
end

local function cabecera(codigo, extra)
    local t = { "HTTP/1.0 " .. codigo .. " " .. (ESTADOS[codigo] or "Error") }
    for _, l in ipairs(extra or {}) do t[#t + 1] = l end
    t[#t + 1] = "Connection: close"
    return table.concat(t, "\r\n") .. "\r\n\r\n"
end

function Servidor:responder(cliente, codigo, tipo, cuerpo, extra)
    cuerpo = cuerpo or ""
    local lineas = { "Content-Type: " .. tipo, string.format("Content-Length: %d", #cuerpo), "Cache-Control: no-store" }
    for _, l in ipairs(extra or {}) do lineas[#lineas + 1] = l end
    enviar(cliente, cabecera(codigo, lineas) .. cuerpo)
end

function Servidor:avisar(texto)
    if self.al_evento then self.al_evento(texto) end
end

--- Avance de lo que hace la app con el archivo recibido, para la página (GET /estado).
-- pct: 0..100 o nil; fin: terminó; ok: true (bien), false (error) o nil (sin decir).
function Servidor:progresar(texto, pct, fin, ok)
    local p = self.progreso
    p.texto, p.pct, p.fin, p.ok = texto, pct, fin and true or false, ok
end

--- Avisa a la página que el servidor se va a apagar: /estado dice "cerrado":true y la página
-- muestra que hay que volver a activar el servidor en el Kindle. Hay que dejarlo encendido un
-- momento (la página consulta cada segundo) antes de servidor:detener().
function Servidor:anunciarCierre()
    self.cerrado = true
end

--- Texto → cadena JSON.
local function json(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c)
        if c == "\n" then return "\\n" end
        if c == '"' or c == "\\" then return "\\" .. c end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

function Servidor:estado(cliente)
    local p = self.progreso
    local partes = { '"id":' .. p.id, '"fin":' .. tostring(p.fin == true) }
    if p.texto then partes[#partes + 1] = '"texto":' .. json(p.texto) end
    if p.pct then partes[#partes + 1] = '"pct":' .. math.floor(math.max(0, math.min(100, p.pct))) end
    if p.ok ~= nil then partes[#partes + 1] = '"ok":' .. tostring(p.ok) end
    if self.cerrado then partes[#partes + 1] = '"cerrado":true' end
    self:responder(cliente, 200, "application/json; charset=utf-8", "{" .. table.concat(partes, ",") .. "}")
end

--- Atiende una petición. Siempre cierra la conexión.
function Servidor:atender(texto, cliente)
    cliente:settimeout(ESPERA)
    local ok, err = pcall(function()
        local p = M.leerPeticion(texto)
        if not p then return self:responder(cliente, 400, "text/plain", "Petición no válida") end
        if p.ruta == "/entrar" then return self:entrar(cliente, p) end
        if not self:autorizado(p) then
            return self:responder(cliente, 403, "text/html; charset=utf-8", M.paginaEntrar(nil, self.marca))
        end
        if self.paquete then
            if p.ruta == "/" and p.metodo == "GET" then
                return self:responder(cliente, 200, "text/html; charset=utf-8",
                    M.paginaPaquete(self.titulo, self.detalle, self.pagina, self.marca))
            end
            if p.ruta == "/paquete" and p.metodo == "PUT" then return self:recibirPaquete(cliente, p) end
            if p.ruta == "/estado" and p.metodo == "GET" then return self:estado(cliente) end
            return self:responder(cliente, 404, "text/plain; charset=utf-8", "No existe")
        end
        if self.teclado then
            if p.ruta == "/" and p.metodo == "GET" then
                return self:responder(cliente, 200, "text/html; charset=utf-8", M.paginaTeclado(self.marca))
            end
            if p.ruta == "/teclado" and p.metodo == "POST" then return self:recibirTeclas(cliente, p) end
            return self:responder(cliente, 404, "text/plain; charset=utf-8", "No existe")
        end
        if p.ruta == "/" and p.metodo == "GET" then return self:carpeta(cliente, p) end
        if p.ruta == "/archivo" and p.metodo == "GET" then return self:descargar(cliente, p) end
        if p.ruta == "/subir" and p.metodo == "PUT" then return self:subir(cliente, p) end
        self:responder(cliente, 404, "text/plain; charset=utf-8", "No existe")
    end)
    if not ok then
        logger.warn("[BSH] servidor:", err)
        pcall(self.responder, self, cliente, 500, "text/plain; charset=utf-8", "Error en el Kindle")
    end
    cliente:close()
end

function Servidor:autorizado(p)
    local cookie = p.cabeceras.cookie or ""
    return cookie:find("bsh=" .. self.clave, 1, true) ~= nil
end

function Servidor:entrar(cliente, p)
    if p.consulta.pin == self.pin then
        self:avisar(self.teclado and "Teclado remoto conectado" or "Conectado un navegador")
        return self:responder(cliente, 302, "text/plain", "", {
            "Set-Cookie: bsh=" .. self.clave .. "; Path=/; SameSite=Strict", "Location: /" })
    end
    self:responder(cliente, 403, "text/html; charset=utf-8", M.paginaEntrar(p.consulta.pin ~= nil, self.marca))
end

--- Lee largo bytes del cuerpo y se los pasa a escribir(datos). Devuelve true si llegaron todos.
local function leerCuerpo(cliente, largo, escribir)
    local resto = largo
    while resto > 0 do
        local datos, err, parcial = cliente:receive(math.min(resto, TROZO))
        datos = datos or parcial
        if datos and #datos > 0 then
            escribir(datos)
            resto = resto - #datos
        end
        if err and (err ~= "timeout" or not datos or #datos == 0) then return false end
    end
    return true
end

--- Teclado remoto: pasa lo escrito al editor.
function Servidor:recibirTeclas(cliente, p)
    local largo = tonumber(p.cabeceras["content-length"] or "")
    if not largo or largo > TROZO then
        return self:responder(cliente, 411, "text/plain; charset=utf-8", "Falta el tamaño")
    end
    local partes = {}
    if not leerCuerpo(cliente, largo, function(datos) partes[#partes + 1] = datos end) then return end
    self.teclado(table.concat(partes))
    self:responder(cliente, 200, "text/plain; charset=utf-8", "OK")
end

--- Un paquete: se guarda entero en self.destino y luego se entrega a self.paquete(ruta).
function Servidor:recibirPaquete(cliente, p)
    local largo = tonumber(p.cabeceras["content-length"] or "")
    if not largo or largo == 0 or largo > MAX_PAQUETE then
        return self:responder(cliente, 411, "text/plain; charset=utf-8", "Falta el tamaño o es muy grande")
    end
    local tmp = self.destino .. ".subiendo"
    local f = io.open(tmp, "wb")
    if not f then return self:responder(cliente, 500, "text/plain; charset=utf-8", "No se pudo escribir") end
    local completo = leerCuerpo(cliente, largo, function(datos) f:write(datos) end)
    f:close()
    if not completo then
        os.remove(tmp)
        return
    end
    os.remove(self.destino)
    if not os.rename(tmp, self.destino) then
        os.remove(tmp)
        return self:responder(cliente, 500, "text/plain; charset=utf-8", "No se pudo guardar")
    end
    -- un trabajo nuevo: la página espera hasta ver este id con fin
    local nombre = M.limpiarNombre(M.decodificar(p.cabeceras["x-nombre"] or ""))
    self.progreso = { id = self.progreso.id + 1, texto = "Recibido. Procesando…", pct = 0, fin = false }
    self:responder(cliente, 200, "text/plain; charset=utf-8", tostring(self.progreso.id))
    self.paquete(self.destino, nombre)
end

function Servidor:carpeta(cliente, p)
    local rel = M.limpiarRuta(p.consulta.d)
    local ruta = rel and self.raiz .. (rel == "/" and "" or rel)
    if not ruta or lfs.attributes(ruta, "mode") ~= "directory" then
        return self:responder(cliente, 404, "text/plain; charset=utf-8", "No existe la carpeta")
    end
    local entradas = {}
    for n in lfs.dir(ruta) do
        if n:sub(1, 1) ~= "." then
            local a = lfs.attributes(ruta .. "/" .. n)
            if a and (a.mode == "directory" or a.mode == "file") then
                entradas[#entradas + 1] = { nombre = n, carpeta = a.mode == "directory", tam = a.size,
                    fecha = a.modification }
            end
        end
    end
    table.sort(entradas, function(a, b)
        if a.carpeta ~= b.carpeta then return a.carpeta end
        return a.nombre:lower() < b.nombre:lower()
    end)
    self:responder(cliente, 200, "text/html; charset=utf-8", M.paginaCarpeta(rel, entradas, self.marca))
end

function Servidor:descargar(cliente, p)
    local rel = M.limpiarRuta(p.consulta.r)
    local ruta = rel and self.raiz .. rel
    local a = ruta and lfs.attributes(ruta)
    if not a or a.mode ~= "file" then
        return self:responder(cliente, 404, "text/plain; charset=utf-8", "No existe el archivo")
    end
    local f = io.open(ruta, "rb")
    if not f then return self:responder(cliente, 403, "text/plain; charset=utf-8", "No se pudo leer") end
    local nombre = rel:match("([^/]+)$")
    local ascii = nombre:gsub("[^%w%-%._ ]", "_")
    local ok = enviar(cliente, cabecera(200, {
        "Content-Type: application/octet-stream",
        string.format("Content-Length: %d", a.size),
        'Content-Disposition: attachment; filename="' .. ascii .. "\"; filename*=UTF-8''" .. M.codificar(nombre),
    }))
    while ok do
        local datos = f:read(TROZO)
        if not datos then break end
        ok = enviar(cliente, datos)
    end
    f:close()
    if ok then self:avisar("Descargado: " .. nombre) end
end

function Servidor:subir(cliente, p)
    local rel = M.limpiarRuta(p.consulta.d)
    local nombre = M.limpiarNombre(p.consulta.n)
    local dir = rel and self.raiz .. (rel == "/" and "" or rel)
    if not dir or not nombre or lfs.attributes(dir, "mode") ~= "directory" then
        return self:responder(cliente, 400, "text/plain; charset=utf-8", "Carpeta o nombre no válidos")
    end
    local largo = tonumber(p.cabeceras["content-length"] or "")
    if not largo then return self:responder(cliente, 411, "text/plain; charset=utf-8", "Falta el tamaño") end
    local ruta = dir .. "/" .. nombre
    local existe = lfs.attributes(ruta, "mode")
    if existe == "directory" or (existe and p.consulta.reemplazar ~= "1") then
        return self:responder(cliente, 409, "text/plain; charset=utf-8", "Ya existe")
    end
    if (p.cabeceras.expect or ""):lower() == "100-continue" then
        enviar(cliente, "HTTP/1.1 100 Continue\r\n\r\n")
    end
    local tmp = ruta .. ".subiendo"
    local f = io.open(tmp, "wb")
    if not f then return self:responder(cliente, 500, "text/plain; charset=utf-8", "No se pudo escribir") end
    local completo = leerCuerpo(cliente, largo, function(datos) f:write(datos) end)
    f:close()
    if not completo then
        os.remove(tmp)
        logger.warn("[BSH] subida incompleta:", nombre)
        return
    end
    if existe then os.remove(ruta) end
    local ok = os.rename(tmp, ruta)
    if not ok then
        os.remove(tmp)
        return self:responder(cliente, 500, "text/plain; charset=utf-8", "No se pudo guardar")
    end
    self.cambios = true
    self:avisar("Recibido: " .. nombre)
    self:responder(cliente, 200, "text/plain; charset=utf-8", "OK")
end

--- Páginas --------------------------------------------------------------------------

local ESTILO = [[
*{box-sizing:border-box}
body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;margin:0;color:#1d1d1f;background:#f5f5f7}
header{background:linear-gradient(180deg,#fff 0%,#f5f5f7 100%);border-bottom:1px solid #e3e3e8;display:flex;flex-direction:column;align-items:center;gap:10px;padding:26px 20px 20px;text-align:center}
header svg{width:64px;height:64px;flex:none;filter:drop-shadow(0 3px 6px rgba(0,0,0,.18))}
header .marca{font-size:22px;font-weight:700;letter-spacing:.3px;color:#1d1d1f}
main{max-width:860px;margin:0 auto;padding:16px}
.ruta{font-size:15px;margin:4px 0 14px;word-break:break-word}
.ruta a{color:#0b57d0;text-decoration:none}
.atajos a{display:inline-block;margin:0 8px 8px 0;padding:6px 12px;border-radius:16px;background:#e3e3e8;color:#1d1d1f;text-decoration:none;font-size:14px}
.subir{border:2px dashed #b0b0b8;border-radius:10px;padding:16px;text-align:center;background:#fff;margin-bottom:16px}
.subir.encima{border-color:#0b57d0;background:#eef3fd}
.subir label{display:inline-block;padding:10px 18px;border-radius:8px;background:#0b57d0;color:#fff;cursor:pointer;font-weight:600}
.subir input{display:none}
#estado{margin-top:10px;font-size:14px;color:#555;min-height:1.2em}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:10px;overflow:hidden}
td{padding:11px 12px;border-top:1px solid #eee;font-size:15px}
tr:first-child td{border-top:0}
td.n{word-break:break-word}
td.n a{color:#1d1d1f;text-decoration:none}
td.t,td.f{color:#777;font-size:13px;white-space:nowrap;text-align:right}
td.d a{color:#0b57d0;text-decoration:none;font-size:14px;white-space:nowrap}
.vacia{padding:20px;text-align:center;color:#777;background:#fff;border-radius:10px}
@media(max-width:560px){td.f{display:none}}
form{max-width:320px;margin:60px auto;background:#fff;padding:24px;border-radius:12px;text-align:center}
form input{font-size:28px;letter-spacing:8px;width:160px;text-align:center;padding:8px;margin:12px 0;border:1px solid #bbb;border-radius:8px}
form button{font-size:16px;padding:10px 24px;border:0;border-radius:8px;background:#0b57d0;color:#fff;font-weight:600}
.error{color:#b3261e}
]]

M.MARCA = { nombre = "BSH Text Editor · Kindle" } -- cabecera si el servidor no trae o.marca

local function documento(titulo, cuerpo, estilo, marca)
    marca = marca or M.MARCA
    return '<!DOCTYPE html><html lang="es"><head><meta charset="utf-8">'
        .. '<meta name="viewport" content="width=device-width,initial-scale=1">'
        .. "<title>" .. html(titulo) .. " · " .. html(marca.nombre) .. "</title><style>" .. ESTILO .. (estilo or "")
        .. "</style></head><body><header>" .. (marca.logo or "")
        .. '<span class="marca">' .. html(marca.nombre) .. "</span></header><main>" .. cuerpo .. "</main></body></html>"
end

function M.paginaEntrar(error, marca)
    return documento("Entrar", '<form action="/entrar" method="get">'
        .. "<div>Escribe el código que muestra el Kindle</div>"
        .. '<input name="pin" inputmode="numeric" maxlength="4" autofocus autocomplete="off">'
        .. (error and '<div class="error">Código incorrecto</div>' or "")
        .. "<div><button>Entrar</button></div></form>", nil, marca)
end

local SCRIPT = [[
<script>
const D=document.body.dataset.d,zona=document.querySelector('.subir'),estado=document.getElementById('estado');
function put(url,f){return new Promise((ok,mal)=>{const x=new XMLHttpRequest();x.open('PUT',url);
x.upload.onprogress=e=>{if(e.lengthComputable)estado.textContent='Subiendo '+f.name+': '+Math.round(e.loaded*100/e.total)+' %'};
x.onload=()=>ok(x.status);x.onerror=()=>mal();x.send(f)})}
async function subir(lista){let hechos=0;for(const f of lista){
let url='/subir?d='+encodeURIComponent(D)+'&n='+encodeURIComponent(f.name);
try{let s=await put(url,f);
if(s==409){if(!confirm('Ya existe «'+f.name+'» en esta carpeta. ¿Reemplazarlo?'))continue;s=await put(url+'&reemplazar=1',f)}
if(s==200)hechos++;else alert('No se pudo subir '+f.name+' ('+s+')')}catch(e){alert('Se perdió la conexión al subir '+f.name)}}
estado.textContent=hechos+' archivo(s) subido(s)';if(hechos)setTimeout(()=>location.reload(),600)}
document.getElementById('archivos').onchange=e=>subir(e.target.files);
['dragenter','dragover'].forEach(t=>zona.addEventListener(t,e=>{e.preventDefault();zona.classList.add('encima')}));
['dragleave','drop'].forEach(t=>zona.addEventListener(t,e=>{e.preventDefault();zona.classList.remove('encima')}));
zona.addEventListener('drop',e=>subir(e.dataTransfer.files));
</script>]]

--- Página de una carpeta. entradas: { nombre, carpeta, tam, fecha }.
function M.paginaCarpeta(rel, entradas, marca)
    local t = {}
    -- migas: Kindle / BSH Notes / …
    local migas, acumulada = { '<a href="/">Kindle</a>' }, ""
    for parte in rel:gmatch("[^/]+") do
        acumulada = acumulada .. "/" .. parte
        migas[#migas + 1] = '<a href="/?d=' .. M.codificar(acumulada) .. '">' .. html(parte) .. "</a>"
    end
    t[#t + 1] = '<div class="ruta">' .. table.concat(migas, " / ") .. "</div>"
    if rel == "/" then
        t[#t + 1] = '<div class="atajos"><a href="/?d=/BSH%20Notes">BSH Notes</a><a href="/?d=/documents">documents</a></div>'
    end
    t[#t + 1] = '<div class="subir"><label>Subir archivos<input type="file" id="archivos" multiple></label>'
        .. '<div id="estado">o arrástralos aquí, a «' .. html(rel == "/" and "Kindle" or rel:match("([^/]+)$")) .. "»</div></div>"
    if #entradas == 0 then
        t[#t + 1] = '<div class="vacia">Carpeta vacía</div>'
    else
        t[#t + 1] = "<table>"
        local base = rel == "/" and "" or rel
        for _, e in ipairs(entradas) do
            local ruta = M.codificar(base .. "/" .. e.nombre)
            if e.carpeta then
                t[#t + 1] = '<tr><td class="n"><a href="/?d=' .. ruta .. '">📁 ' .. html(e.nombre)
                    .. '</a></td><td class="t"></td><td class="f"></td><td class="d"></td></tr>'
            else
                t[#t + 1] = '<tr><td class="n"><a href="/archivo?r=' .. ruta .. '">' .. html(e.nombre)
                    .. '</a></td><td class="t">' .. tamano(e.tam or 0) .. '</td><td class="f">'
                    .. (e.fecha and os.date("%Y-%m-%d %H:%M", e.fecha) or "")
                    .. '</td><td class="d"><a href="/archivo?r=' .. ruta .. '">Descargar</a></td></tr>'
            end
        end
        t[#t + 1] = "</table>"
    end
    local pagina = documento("Kindle" .. (rel == "/" and "" or " · " .. rel), table.concat(t) .. SCRIPT, nil, marca)
    local body = '<body data-d="' .. html(rel) .. '">'
    return (pagina:gsub("<body>", function() return body end, 1))
end

local ESTILO_TECLADO = [[
textarea{width:100%;min-height:40vh;font-size:18px;line-height:1.45;padding:12px;border:1px solid #bbb;border-radius:10px;resize:vertical;font-family:inherit}
textarea:focus{outline:2px solid #0b57d0;border-color:#0b57d0}
.teclas{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0}
.teclas button{flex:1 1 auto;min-width:56px;font-size:20px;padding:12px 10px;border:1px solid #c4c4cc;border-radius:10px;background:#fff;color:#1d1d1f}
.teclas button:active{background:#e3e3e8}
.teclas .vaciar{font-size:15px;flex:2 1 auto}
#estado{font-size:14px;color:#555;min-height:1.2em}
#estado.mal{color:#b3261e}
.ayuda{font-size:14px;color:#666;margin-top:14px;line-height:1.4}
]]

local SCRIPT_TECLADO = [[
<script>
const caja=document.getElementById('caja'),estado=document.getElementById('estado');
let base='',pendiente='',enviando=false,reloj=null;
const letras=s=>Array.from(s);
function mostrar(t,mal){estado.textContent=t;estado.className=mal?'mal':''}
async function enviar(){if(enviando||!pendiente)return;enviando=true;const t=pendiente;pendiente='';
try{const r=await fetch('/teclado',{method:'POST',body:t,headers:{'Content-Type':'text/plain; charset=utf-8'}});
if(r.status==403){location.reload();return}
if(!r.ok){mostrar('El Kindle no aceptó el texto ('+r.status+')',true);enviando=false;if(pendiente)enviar();return}
mostrar('Enviado al Kindle')}
catch(e){pendiente=t+pendiente;mostrar('Sin conexión con el Kindle: se reintenta…',true);setTimeout(()=>{enviando=false;enviar()},1500);return}
enviando=false;if(pendiente)enviar()}
function mandar(t){pendiente+=t;clearTimeout(reloj);reloj=setTimeout(enviar,250)}
// lo que cambió en el cuadro (también si el celular corrige una palabra): borra lo distinto y escribe lo nuevo
caja.addEventListener('input',()=>{const a=letras(base),b=letras(caja.value);let p=0;
while(p<a.length&&p<b.length&&a[p]===b[p])p++;
const t='\b'.repeat(a.length-p)+b.slice(p).join('').replace(/[\x00-\x08\x0b-\x1f]/g,'');base=caja.value;if(t)mandar(t)});
// en el PC, borrar con el cuadro vacío borra en el Kindle
caja.addEventListener('keydown',e=>{if(e.key=='Backspace'&&caja.selectionStart==0&&caja.selectionEnd==0){e.preventDefault();mandar('\b')}});
document.querySelectorAll('[data-t]').forEach(b=>b.addEventListener('click',()=>{mandar(b.dataset.t.replace('B','\b').replace('L','\x02').replace('R','\x03').replace('U','\x04').replace('D','\x05'));caja.focus()}));
document.querySelector('.vaciar').addEventListener('click',()=>{caja.value='';base='';caja.focus();mostrar('Cuadro vacío: el texto sigue en el Kindle')});
caja.focus();
</script>]]

--- Página del teclado remoto.
function M.paginaTeclado(marca)
    return documento("Teclado remoto", '<textarea id="caja" autocapitalize="sentences" spellcheck="true" '
        .. 'placeholder="Escribe aquí: el texto aparece en el Kindle, donde está el cursor."></textarea>'
        .. '<div class="teclas"><button data-t="L" title="Izquierda">←</button><button data-t="R" title="Derecha">→</button>'
        .. '<button data-t="U" title="Arriba">↑</button><button data-t="D" title="Abajo">↓</button>'
        .. '<button data-t="B" title="Borrar en el Kindle">⌫</button><button class="vaciar">Vaciar cuadro</button></div>'
        .. '<div id="estado"></div>'
        .. '<div class="ayuda">Lo que borras o corriges en el cuadro también se borra en el Kindle. '
        .. '«Vaciar cuadro» limpia solo este cuadro. ⌫ borra en el Kindle aunque el cuadro esté vacío.</div>'
        .. SCRIPT_TECLADO, ESTILO_TECLADO, marca)
end

-- Cada archivo: una tarjeta con su barra. Primero el envío (azul, con el % que lleva), luego lo que
-- hace el Kindle (morado, según /estado, hasta que dice fin) y al final verde o rojo.
-- vigilar() consulta /estado todo el tiempo (cada segundo; más seguido mientras se procesa): si el
-- Kindle anuncia el cierre ("cerrado") o deja de responder, avisa que hay que activar de nuevo
-- el servidor y apaga el botón.
local SCRIPT_PAQUETE = [[
<script>
const zona=document.getElementById('zona'),archivo=document.getElementById('archivo'),lista=document.getElementById('lista');
const varios=archivo.multiple,recibido=archivo.dataset.recibido;
let ocupado=false,cola=[],ultimo=null,cerrado=false;
function cerrar(){if(cerrado)return;cerrado=true;cola=[];archivo.disabled=true;zona.classList.add('apagada');
document.getElementById('cerrado').hidden=false}
async function vigilar(){let fallas=0;
for(;;){await espera(ocupado?500:1000);
try{const r=await fetch('/estado',{cache:'no-store'});if(r.status==403){location.reload();return}
ultimo=await r.json();fallas=0;if(ultimo.cerrado){cerrar();return}}
catch(_){if(++fallas>=3){cerrar();return}}}}
function item(nombre){const d=document.createElement('div');d.className='item';
d.innerHTML='<div class="fila"><span class="nombre"></span><span class="pct"></span></div><div class="barra"><div></div></div><div class="texto"></div>';
d.querySelector('.nombre').textContent=nombre;lista.prepend(d);
return {pon(t,p,c){d.querySelector('.texto').textContent=t;d.querySelector('.pct').textContent=p==null?'':p+' %';
d.querySelector('.barra div').style.width=(p==null?100:p)+'%';
d.className='item '+(c||'')+(p==null&&c=='proceso'?' indef':'')}}}
const espera=ms=>new Promise(r=>setTimeout(r,ms));
function put(f,it){return new Promise(ok=>{const x=new XMLHttpRequest();x.open('PUT','/paquete');
x.setRequestHeader('X-Nombre',encodeURIComponent(f.name));
x.upload.onprogress=e=>{if(e.lengthComputable)it.pon('Enviando al Kindle…',Math.round(e.loaded*100/e.total),'envio')};
x.onload=()=>ok(x);x.onerror=()=>ok(null);x.send(f)})}
async function seguir(id,it){
for(;;){await espera(250);const e=ultimo;
if(e&&e.id==id&&e.fin){it.pon(e.texto||recibido,100,e.ok===false?'mal':'ok');return}
if(cerrado){it.pon('Se cerró la conexión antes de terminar. Mira la pantalla del Kindle.',null,'mal');return}
if(e&&e.id==id)it.pon(e.texto||'Procesando en el Kindle…',e.pct==null?null:e.pct,'proceso')}}
async function enviar(f){const it=item(f.name);
if(cerrado){it.pon('No se envió: el servidor del Kindle está cerrado.',null,'mal');return}
it.pon('Preparando…',0,'envio');
const x=await put(f,it);
if(!x){it.pon('Se perdió la conexión con el Kindle',null,'mal');return}
if(x.status==403){location.reload();return}
if(x.status!=200){it.pon('El Kindle no aceptó el archivo ('+x.status+')',null,'mal');return}
it.pon('Recibido. Procesando en el Kindle…',0,'proceso');
await seguir(parseInt(x.responseText)||0,it)}
async function enviarTodos(lista){cola.push(...Array.from(lista).slice(0,varios?99:1));if(ocupado)return;ocupado=true;
while(cola.length)await enviar(cola.shift());ocupado=false;archivo.value=''}
archivo.onchange=()=>enviarTodos(archivo.files);
['dragenter','dragover'].forEach(t=>zona.addEventListener(t,e=>{e.preventDefault();zona.classList.add('encima')}));
['dragleave','drop'].forEach(t=>zona.addEventListener(t,e=>{e.preventDefault();zona.classList.remove('encima')}));
zona.addEventListener('drop',e=>{if(!cerrado)enviarTodos(e.dataTransfer.files)});
vigilar();
</script>]]

local ESTILO_PAQUETE = [[
.tarjeta{background:#fff;border-radius:14px;padding:22px 20px;box-shadow:0 2px 14px rgba(0,0,0,.06);margin-top:8px}
h1{font-size:22px;margin:0 0 4px}
.detalle{color:#6e6e73;font-size:15px;margin-bottom:18px}
.subir{padding:28px 16px;margin:0}
.subir .icono{font-size:34px;line-height:1;margin-bottom:10px;color:#8e8e93}
.ayuda{font-size:14px;color:#6e6e73;margin-top:12px}
.item{background:#fff;border-radius:12px;padding:14px 16px;margin-top:12px;box-shadow:0 1px 8px rgba(0,0,0,.05)}
.fila{display:flex;justify-content:space-between;gap:10px;font-weight:600;font-size:15px}
.nombre{word-break:break-all}
.pct{color:#6e6e73;white-space:nowrap}
.barra{height:10px;background:#e8e8ed;border-radius:6px;overflow:hidden;margin:10px 0 8px}
.barra div{height:100%;width:0;background:#0b57d0;border-radius:6px;transition:width .3s}
.item.proceso .barra div{background:#7a5af8}
.item.indef .barra div{background:repeating-linear-gradient(45deg,#7a5af8 0 10px,#a48ffb 10px 20px);background-size:28px 28px;animation:mover 1s linear infinite}
@keyframes mover{to{background-position:28px 0}}
.item.ok .barra div{background:#1b8a3a}
.item.mal .barra div{background:#b3261e}
.texto{font-size:14px;color:#3a3a3c}
.item.ok .texto{color:#1b6e2d;font-weight:600}
.item.mal .texto{color:#b3261e;font-weight:600}
.pie{text-align:center;color:#8e8e93;font-size:12px;margin:24px 0 8px}
.subir.apagada{opacity:.45;pointer-events:none}
.aviso{background:#fff4e5;border:1px solid #f0c27b;border-radius:12px;padding:16px 18px;margin-top:14px;color:#5c3b00;font-size:15px;line-height:1.45}
.aviso b{display:block;font-size:16px;margin-bottom:4px}
.aviso .donde{margin:8px 0 12px;font-weight:600}
.aviso button{font-size:15px;padding:9px 20px;border:0;border-radius:8px;background:#1d1d1f;color:#fff;font-weight:600;cursor:pointer}
]]

--- Página para enviar un paquete. titulo y detalle: lo que se muestra arriba.
-- o (opcional): aceptar (".tar"), elegir (texto del botón), ayuda (bajo el botón), recibido
-- (lo que dice al terminar si la app no lo dice), varios (se pueden enviar varios, uno tras otro)
-- y reactivar (dónde se vuelve a activar el servidor en el Kindle, para el aviso de cierre).
-- Sin o, los de una actualización. marca: la cabecera (ver M.nuevo).
function M.paginaPaquete(titulo, detalle, o, marca)
    o = o or {}
    return documento(titulo or "Enviar archivo", '<div class="tarjeta"><h1>' .. html(titulo or "") .. "</h1>"
        .. '<div class="detalle">' .. html(detalle or "") .. "</div>"
        .. '<div class="subir" id="zona"><div class="icono">⇪</div><label>' .. html(o.elegir or "Elegir el paquete")
        .. '<input type="file" id="archivo"' .. (o.varios and " multiple" or "") .. ' accept="' .. html(o.aceptar or ".tar")
        .. '" data-recibido="' .. html(o.recibido or "Recibido. Mira el Kindle: allí se instala y se reinicia.") .. '"></label>'
        .. '<div class="ayuda">' .. html(o.ayuda or "El archivo .tar que genera el armado en la PC")
        .. " · o arrástralo aquí</div></div></div>"
        .. '<div id="cerrado" class="aviso" hidden><b>Se cerró la conexión con el Kindle.</b>'
        .. "Para enviar más archivos, vuelve a activar el servidor en el Kindle"
        .. (o.reactivar and (':<div class="donde">' .. html(o.reactivar) .. "</div>") or '.<div class="donde"></div>')
        .. "Luego recarga esta página y escribe el código nuevo que muestra el Kindle.<div style=\"margin-top:12px\">"
        .. '<button onclick="location.reload()">Recargar</button></div></div>'
        .. '<div id="lista"></div><div class="pie">Mantén esta página abierta hasta que termine.</div>'
        .. SCRIPT_PAQUETE, ESTILO_PAQUETE, marca)
end

--- Encendido ------------------------------------------------------------------------

--- Dirección IP del Kindle en la red Wi-Fi, o nil.
function M.ip()
    local ok, socket = pcall(require, "socket")
    if ok then
        local u = socket.udp()
        -- un socket UDP «conectado» no envía nada, pero muestra la dirección que usaría
        if u and u:setpeername("192.168.0.1", 80) then
            local ip = u:getsockname()
            u:close()
            if ip and ip ~= "0.0.0.0" and ip ~= "127.0.0.1" then return ip end
        end
    end
    local p = io.popen("ifconfig wlan0 2>/dev/null")
    if p then
        local s = p:read("*a") or ""
        p:close()
        return s:match("inet addr:(%d+%.%d+%.%d+%.%d+)") or s:match("inet (%d+%.%d+%.%d+%.%d+)")
    end
end

local function cortafuegos(puerto, accion)
    os.execute(string.format("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", accion, puerto))
    os.execute(string.format("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", accion, puerto))
end

--- Enciende el servidor en el primer puerto libre. Devuelve true, o nil y el error.
function Servidor:iniciar()
    local Device = require("device")
    local UIManager = require("ui/uimanager")
    local SimpleTCPServer = require("ui/message/simpletcpserver")
    local ultimo_error
    for _, puerto in ipairs(M.PUERTOS) do
        local tcp = SimpleTCPServer:new{ host = "*", port = puerto,
            receiveCallback = function(datos, cliente) self:atender(datos, cliente) end }
        local ok, err = tcp:start()
        if ok then
            self.tcp, self.puerto = tcp, puerto
            self.kindle = Device:isKindle()
            if self.kindle then cortafuegos(puerto, "A") end
            UIManager:insertZMQ(tcp)
            return true
        end
        ultimo_error = err
    end
    return nil, ultimo_error
end

function Servidor:detener()
    if not self.tcp then return end
    local UIManager = require("ui/uimanager")
    UIManager:removeZMQ(self.tcp)
    pcall(self.tcp.stop, self.tcp)
    if self.kindle then cortafuegos(self.puerto, "D") end
    self.tcp = nil
end

M.Servidor = Servidor

return M
