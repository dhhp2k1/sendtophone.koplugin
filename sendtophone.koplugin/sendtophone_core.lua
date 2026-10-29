--[[--
Pure logic for the "send to phone" plugin: no KOReader UI here, so it can be
tested on a desktop.

Bark facts this relies on (checked against Finb/bark-server and Finb/Bark):
- POST <server>/push with a JSON body; device_key, title, body, group, autoCopy.
- With autoCopy = "1" and no "copy" field, the app copies the notification body.
- The server forwards everything to APNs, whose payload limit is 4096 bytes,
  measured after Go's json.Marshal (which escapes < > & as < etc.).
- Replies are {"code":200,"message":"success",...}; an unknown key gives
  400 "failed to get device token: ...".
--]]

local Core = {}

Core.DEFAULT_SERVER = "https://api.day.app"
Core.DEFAULT_GROUP = "Kindle"
Core.DEFAULT_TEMPLATE = "请结合上下文解释下面这段文字{source}：\n{text}"
-- Ways to ask, offered after tapping "发送到手机". A preset without a
-- template sends the selection as is.
Core.DEFAULT_PRESETS = {
    { name = "简短解释", template = "用两三句话、不超过100字，解释下面这段文字在书中的意思{source}：\n{text}" },
    { name = "查词", template = "“{text}”在这里是什么意思？一句话回答{source}。" },
    { name = "翻译", template = "把下面这段文字翻译成中文（原文是中文就翻译成英文），只给译文：\n{text}" },
    { name = "详细解释", template = Core.DEFAULT_TEMPLATE },
    { name = "只发原文" },
}
Core.FALLBACK_TITLE = "KOReader"
Core.ELLIPSIS = "…"
-- APNs allows 4096 bytes. The aps wrapper, sound, category, group, autocopy
-- and level fields take about 250 bytes; keep a generous margin on top.
Core.PAYLOAD_BUDGET = 3500

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---------------------------------------------------------------------------
-- Bark address
---------------------------------------------------------------------------

local function looksLikeKey(seg)
    return #seg >= 16 and seg:match("^[%w]+$") ~= nil
end

--- Parse whatever the user pasted into a server base URL and a device key.
-- Accepts the full address the Bark app shows (with or without a trailing
-- slash or the sample text after it), a self-hosted server with port or
-- sub-path, an address without scheme, or a bare key.
-- @treturn table|nil {server=..., key=...}
-- @treturn string|nil error message
function Core.parseBarkUrl(input)
    if type(input) ~= "string" then
        return nil, "地址为空"
    end
    local s = trim(input)
    if s == "" then
        return nil, "地址为空"
    end
    s = s:gsub("[?#].*$", "")
    if not s:find("/", 1, true) and not s:find(".", 1, true) and not s:find(":", 1, true) then
        if s:match("^[%w]+$") then
            return { server = Core.DEFAULT_SERVER, key = s }
        end
        return nil, "无法识别的地址"
    end
    local scheme, rest = s:match("^(%a[%w+.-]*)://(.*)$")
    if not scheme then
        scheme, rest = "https", s
    end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "地址必须以 http:// 或 https:// 开头"
    end
    local host, path = rest:match("^([^/]+)(.*)$")
    if not host or host == "" then
        return nil, "地址里缺少服务器"
    end
    local segs = {}
    for seg in path:gmatch("[^/]+") do
        table.insert(segs, seg)
    end
    local key_idx
    for i, seg in ipairs(segs) do
        if looksLikeKey(seg) then
            key_idx = i
            break
        end
    end
    if not key_idx then
        -- Self-hosted keys may be short; accept a lone path segment.
        if #segs == 1 and segs[1]:match("^[%w]+$") then
            key_idx = 1
        else
            return nil, "地址里找不到 key，请从 Bark App 里重新复制"
        end
    end
    local prefix = ""
    for i = 1, key_idx - 1 do
        prefix = prefix .. "/" .. segs[i]
    end
    return { server = scheme .. "://" .. host .. prefix, key = segs[key_idx] }
end

--- Show a key without giving it away, e.g. "abcd…wxyz".
function Core.maskKey(key)
    if not key or #key <= 8 then
        return key or ""
    end
    return key:sub(1, 4) .. "…" .. key:sub(-4)
end

---------------------------------------------------------------------------
-- Question template
---------------------------------------------------------------------------

local function oneLine(s)
    if type(s) ~= "string" then
        return nil
    end
    s = trim(s):gsub("%s*\n%s*", "、")
    if s == "" then
        return nil
    end
    return s
end

--- "（出自《书名》，作者）", or the parts that are known, or "".
function Core.sourceText(title, author)
    title, author = oneLine(title), oneLine(author)
    if title and author then
        return "（出自《" .. title .. "》，" .. author .. "）"
    elseif title then
        return "（出自《" .. title .. "》）"
    elseif author then
        return "（作者：" .. author .. "）"
    end
    return ""
end

local function plainReplace(s, from, to)
    local out, i = {}, 1
    while true do
        local a, b = s:find(from, i, true)
        if not a then break end
        table.insert(out, s:sub(i, a - 1))
        table.insert(out, to)
        i = b + 1
    end
    table.insert(out, s:sub(i))
    return table.concat(out)
end

-- Leftovers of an empty {title} or {author}, as literal strings.
local CLEANUPS = {
    { "《》", "" },
    { "（，", "（" }, { "（、", "（" }, { "(,", "(" }, { "( ", "(" },
    { "，）", "）" }, { "、）", "）" }, { ",)", ")" }, { " )", ")" },
    { "（出自，", "（" }, { "（出自）", "" }, { "（作者：）", "" },
    { "（）", "" }, { "()", "" },
    { "，：", "：" }, { "、：", "：" }, { ",:", ":" }, { ", :", ":" },
    { "：：", "：" },
}

--- Fill {text}, {title}, {author} and {source}. Brackets left empty by a
-- missing title or author are removed, so no "《》" or "（）" remains.
function Core.fillTemplate(template, text, title, author)
    title, author = oneLine(title), oneLine(author)
    local values = {
        text = text or "",
        title = title or "",
        author = author or "",
        source = Core.sourceText(title, author),
    }
    local out = template:gsub("{(%a+)}", function(name)
        local v = values[name]
        if v == nil then
            return nil -- unknown placeholder: keep as typed
        end
        return v
    end)
    -- Only clean up around missing values, never inside the selected text.
    if not title or not author then
        local text_pos = values.text ~= "" and out:find(values.text, 1, true)
        local head, body, tail = out, "", ""
        if text_pos then
            head = out:sub(1, text_pos - 1)
            body = values.text
            tail = out:sub(text_pos + #values.text)
        end
        local function clean(s)
            local prev
            repeat
                prev = s
                for _, r in ipairs(CLEANUPS) do
                    s = plainReplace(s, r[1], r[2])
                end
            until s == prev
            return s
        end
        out = clean(head) .. body .. clean(tail)
    end
    return out
end

---------------------------------------------------------------------------
-- UTF-8 safe truncation
---------------------------------------------------------------------------

local function charLen(b)
    if b < 0x80 then return 1
    elseif b >= 0xF0 then return 4
    elseif b >= 0xE0 then return 3
    elseif b >= 0xC0 then return 2
    end
    return 1 -- stray continuation byte
end

--- Bytes this string takes once Go's json.Marshal has escaped it.
function Core.jsonCost(s)
    local n = 0
    local i, len = 1, #s
    while i <= len do
        local b = s:byte(i)
        local cl = charLen(b)
        if b == 0x22 or b == 0x5C or b == 0x0A or b == 0x0D or b == 0x09 then
            n = n + 2
        elseif b < 0x20 or b == 0x3C or b == 0x3E or b == 0x26 then
            n = n + 6
        elseif cl == 3 and b == 0xE2 and s:byte(i + 1) == 0x80
                and (s:byte(i + 2) == 0xA8 or s:byte(i + 2) == 0xA9) then
            n = n + 6 -- U+2028 / U+2029
        else
            n = n + cl
        end
        i = i + cl
    end
    return n
end

--- Bytes s takes once percent-encoded into a URL query value.
function Core.urlCost(s)
    local n = 0
    for i = 1, #s do
        n = n + (s:sub(i, i):match("[%w%-%._~]") and 1 or 3)
    end
    return n
end

function Core.urlEncode(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

--- Cut s so that cost(result) <= budget, on a character boundary.
-- cost defaults to jsonCost. Adds an ellipsis when something was cut.
-- @treturn string
-- @treturn bool truncated
function Core.truncate(s, budget, cost_fn)
    cost_fn = cost_fn or Core.jsonCost
    if cost_fn(s) <= budget then
        return s, false
    end
    local limit = budget - cost_fn(Core.ELLIPSIS)
    local n, i, len = 0, 1, #s
    local cut = 0
    while i <= len do
        local cl = charLen(s:byte(i))
        local cost = cost_fn(s:sub(i, i + cl - 1))
        if n + cost > limit then
            break
        end
        n = n + cost
        cut = i + cl - 1
        i = i + cl
    end
    return s:sub(1, cut) .. Core.ELLIPSIS, true
end

---------------------------------------------------------------------------
-- Building the push
---------------------------------------------------------------------------

--- Notification title: "《书名》", or a fallback.
function Core.notificationTitle(title)
    title = oneLine(title)
    if title then
        return "《" .. title .. "》"
    end
    return Core.FALLBACK_TITLE
end

--- Build the notification body from the selection.
-- Truncates the selected text (not the question around it) to fit APNs.
-- @tparam table opts {text, title, author, template (nil = send raw text)}
-- @treturn string body
-- @treturn bool truncated
function Core.buildBody(opts, budget, cost_fn)
    budget = budget or Core.PAYLOAD_BUDGET
    cost_fn = cost_fn or Core.jsonCost
    local text = opts.text or ""
    local template = opts.template
    if not template or not template:find("{text}", 1, true) then
        if template then
            -- A template without {text} would drop the selection; append it.
            template = template .. "\n{text}"
        end
    end
    if not template then
        return Core.truncate(text, budget, cost_fn)
    end
    local frame = Core.fillTemplate(template, "", opts.title, opts.author)
    local text_budget = budget - cost_fn(frame)
    if text_budget < 50 then
        -- The template alone is huge; fall back to cutting the whole thing.
        return Core.truncate(Core.fillTemplate(template, text, opts.title, opts.author), budget, cost_fn)
    end
    local cut, truncated = Core.truncate(text, text_budget, cost_fn)
    return Core.fillTemplate(template, cut, opts.title, opts.author), truncated
end

local function jsonString(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n"
        elseif c == "\r" then return "\\r"
        elseif c == "\t" then return "\\t"
        end
        return string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

--- Encode a flat table of strings as JSON, keys sorted for stable output.
function Core.encodeJSON(t)
    local keys = {}
    for k in pairs(t) do
        table.insert(keys, k)
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, jsonString(k) .. ":" .. jsonString(tostring(t[k])))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--- Link that runs an iOS shortcut with text as its input.
function Core.shortcutPrefix(name)
    return "shortcuts://run-shortcut?name=" .. Core.urlEncode(name) .. "&input=text&text="
end

--- Everything needed for one push.
-- When conf.shortcut names an iOS shortcut, tapping the notification runs it
-- with the body as input. The body then appears twice in the APNs payload
-- (once as text, once percent-encoded in the link), so both count to the budget.
-- @tparam table conf {server, key, group, shortcut}
-- @tparam table msg {text, title, author, template}
-- @treturn table {url, json, truncated, body}
function Core.buildRequest(conf, msg)
    local title = Core.notificationTitle(msg.title)
    local budget = Core.PAYLOAD_BUDGET - Core.jsonCost(title)
    local prefix, cost_fn
    if conf.shortcut and conf.shortcut ~= "" then
        prefix = Core.shortcutPrefix(conf.shortcut)
        budget = budget - Core.jsonCost(prefix)
        cost_fn = function(str) return Core.jsonCost(str) + Core.urlCost(str) end
    end
    local body, truncated = Core.buildBody(msg, budget, cost_fn)
    local payload = {
        device_key = conf.key,
        title = title,
        body = body,
        group = conf.group or Core.DEFAULT_GROUP,
        autoCopy = "1",
    }
    if prefix then
        payload.url = prefix .. Core.urlEncode(body)
    end
    return {
        url = conf.server .. "/push",
        json = Core.encodeJSON(payload),
        body = body,
        truncated = truncated,
    }
end

---------------------------------------------------------------------------
-- Interpreting the result
---------------------------------------------------------------------------

local function describeNetworkError(err)
    err = tostring(err or "")
    local low = err:lower()
    if low:find("proxy not supported", 1, true) then
        return "KOReader 开着 HTTP 代理，HTTPS 请求无法走代理。请到 设置 → 网络 → HTTP 代理 里关掉它。"
    elseif low:find("timeout", 1, true) or low:find("wantread", 1, true) or low:find("wantwrite", 1, true) then
        return "连接超时。请检查 Wi-Fi 是否正常，或稍后再试。"
    elseif low:find("host not found", 1, true) or low:find("name or service", 1, true)
            or low:find("no address", 1, true) or low:find("temporary failure in name", 1, true) then
        return "找不到服务器，可能没联网，或者地址填错了。"
    elseif low:find("refused", 1, true) then
        return "服务器拒绝连接，请检查地址和端口。"
    elseif low:find("certificate", 1, true) or low:find("handshake", 1, true) then
        return "安全连接失败（证书或 TLS 握手出错）：" .. err
    end
    return "网络错误：" .. (err ~= "" and err or "未知原因")
end

--- Turn an HTTP result into success or a message for the user.
-- @param code HTTP status code, or nil/an error string on network failure
-- @param body response body (may be empty)
-- @param net_err error string when the request never got a reply
-- @treturn bool ok
-- @treturn string|nil message when not ok
function Core.interpretResponse(code, body, net_err)
    if type(code) ~= "number" then
        return false, describeNetworkError(net_err or code)
    end
    body = body or ""
    local api_code = tonumber(body:match('"code"%s*:%s*(%d+)'))
    local message = body:match('"message"%s*:%s*"(.-)"%s*[,}]')
    if code == 200 and (api_code == nil or api_code == 200) then
        return true
    end
    if message and message:find("device token", 1, true) then
        return false, "Bark 不认识这个 key。请在 Bark App 里重新复制地址，再到 工具 → 发送到手机 → Bark 地址 里粘贴。"
    end
    if code == 404 then
        return false, "服务器返回 404，地址可能填错了（比如多了一段路径）。"
    end
    if message then
        return false, string.format("服务器返回错误 %d：%s", api_code or code, message)
    end
    return false, string.format("服务器返回错误 %d", code)
end

return Core
