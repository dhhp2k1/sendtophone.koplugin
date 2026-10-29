--[[--
Translation services that work from mainland China, for the "翻译" button.
Pure request building and response parsing; the plugin does the HTTP.

- "edge": Microsoft Edge's built-in translator endpoint. Free, no key, but
  unofficial: POST a JSON array of strings to
  https://edge.microsoft.com/translate/translatetext?to=zh-Hans
  (the older translate/auth token flow was retired in 2026).
- "baidu": Baidu Translate open platform (fanyi-api.baidu.com). Official and
  stable; needs an APP ID and key from the user (standard tier is free).
--]]

local Translate = {}

Translate.ENGINES = {
    { id = "edge", name = "微软翻译（免费，无需设置）" },
    { id = "baidu", name = "百度翻译（需要 APP ID 和密钥）" },
}

local function urlEncode(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

--- True when most letters in s are CJK, so we translate into English.
function Translate.isMostlyCJK(s)
    local cjk, latin = 0, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local b = ch:byte()
        if #ch == 3 and b >= 0xE3 and b <= 0xE9 then
            cjk = cjk + 1
        elseif ch:match("^%a$") then
            latin = latin + 1
        end
    end
    -- One Chinese character carries about as much as a short word.
    return cjk * 4 > latin
end

--- Language codes for each engine: Chinese text goes to English, the rest to Chinese.
function Translate.target(engine, text)
    local to_en = Translate.isMostlyCJK(text)
    if engine == "baidu" then
        return to_en and "en" or "zh"
    end
    return to_en and "en" or "zh-Hans"
end

local function jsonString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n"
        elseif c == "\r" then return "\\r"
        elseif c == "\t" then return "\\t"
        end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

--- Build the HTTP request for an engine.
-- @tparam string engine "edge" or "baidu"
-- @tparam string text
-- @tparam table opts {appid, secret, salt, md5} for baidu
-- @treturn table {url, method, body, content_type} or nil, error
function Translate.buildRequest(engine, text, opts)
    opts = opts or {}
    local to = Translate.target(engine, text)
    if engine == "baidu" then
        if not opts.appid or opts.appid == "" or not opts.secret or opts.secret == "" then
            return nil, "还没有填百度翻译的 APP ID 和密钥。\n\n请到 工具 → 发送到手机 → 翻译设置 里填写，或者换回微软翻译。"
        end
        local salt = tostring(opts.salt or os.time())
        local sign = opts.md5(opts.appid .. text .. salt .. opts.secret)
        local form = table.concat({
            "q=" .. urlEncode(text),
            "from=auto",
            "to=" .. to,
            "appid=" .. urlEncode(opts.appid),
            "salt=" .. salt,
            "sign=" .. sign,
        }, "&")
        return {
            url = "https://fanyi-api.baidu.com/api/trans/vip/translate",
            method = "POST",
            body = form,
            content_type = "application/x-www-form-urlencoded",
        }
    end
    return {
        url = "https://edge.microsoft.com/translate/translatetext?to=" .. to .. "&isEnterpriseClient=false",
        method = "POST",
        body = "[" .. jsonString(text) .. "]",
        content_type = "application/json",
    }
end

local BAIDU_ERRORS = {
    ["52001"] = "百度翻译请求超时，请重试。",
    ["52002"] = "百度翻译服务出错，请重试。",
    ["52003"] = "APP ID 不对，或者还没开通通用翻译服务。",
    ["54000"] = "请求缺少参数。",
    ["54001"] = "签名错误，请检查密钥有没有填错。",
    ["54003"] = "请求太频繁，免费版每秒只能翻译一次，稍后再试。",
    ["54004"] = "账户余额不足。",
    ["54005"] = "长文本请求太频繁，请稍后再试。",
    ["58000"] = "IP 不在白名单里，请在百度翻译控制台关掉 IP 限制。",
    ["58001"] = "不支持这个语言方向。",
    ["90107"] = "认证还没通过或者已失效。",
}

--- Pull the translated text out of a decoded JSON response.
-- @param data decoded JSON (table), or nil if the body wasn't JSON
-- @treturn string|nil translation
-- @treturn string|nil error message
function Translate.parseResponse(engine, data, http_code)
    if type(data) ~= "table" then
        return nil, string.format("翻译服务返回了看不懂的内容（HTTP %s）。", tostring(http_code))
    end
    if engine == "baidu" then
        if data.error_code and tostring(data.error_code) ~= "52000" then
            local code = tostring(data.error_code)
            return nil, (BAIDU_ERRORS[code] or ("百度翻译出错：" .. tostring(data.error_msg or ""))) .. "（错误码 " .. code .. "）"
        end
        local lines = {}
        for _, r in ipairs(data.trans_result or {}) do
            table.insert(lines, r.dst)
        end
        if #lines == 0 then
            return nil, "百度翻译没有返回结果。"
        end
        return table.concat(lines, "\n")
    end
    -- Edge: either ["译文"] or [{"translations":[{"text":"译文"}]}]
    local first = data[1]
    if type(first) == "string" then
        return first
    elseif type(first) == "table" and type(first.translations) == "table"
            and first.translations[1] and first.translations[1].text then
        return first.translations[1].text
    end
    if data.error and type(data.error) == "table" and data.error.message then
        return nil, "微软翻译出错：" .. tostring(data.error.message)
    end
    return nil, string.format("微软翻译没有返回结果（HTTP %s）。这个免费接口不是官方公开的，可能已经变了，可以在翻译设置里换成百度翻译。", tostring(http_code))
end

return Translate
