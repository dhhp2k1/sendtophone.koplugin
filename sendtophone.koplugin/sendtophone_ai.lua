--[[--
Ask an OpenAI-compatible chat API from the Kindle and show the answer there.
Default is Zhipu's free GLM-4-Flash, which is reachable from mainland China;
DeepSeek, Kimi and others work by changing the address, model and key.
Pure request building and response parsing; the plugin does the HTTP.
--]]

local AI = {}

AI.DEFAULT_BASE = "https://open.bigmodel.cn/api/paas/v4"
AI.DEFAULT_MODEL = "glm-4-flash-250414"
AI.SYSTEM_PROMPT = "你是电子书阅读助手。回答要简洁、准确，用纯文本，不要用 Markdown 符号（如 #、*、表格）。"
AI.MAX_TOKENS = 800

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

--- Chat completions URL from a base address, tolerating a pasted full URL.
function AI.endpoint(base)
    base = (base or AI.DEFAULT_BASE):gsub("%s", ""):gsub("/+$", "")
    if base:match("/chat/completions$") then
        return base
    end
    return base .. "/chat/completions"
end

--- @tparam table conf {base, model, key}
-- @treturn table {url, body, headers} or nil, error
function AI.buildRequest(conf, prompt)
    if not conf.key or conf.key == "" then
        return nil, "还没有填 AI 的 API Key。\n\n请到 工具 → 发送到手机 → AI 设置 里填写。智谱的 GLM-4-Flash 是免费的，在 bigmodel.cn 注册后就能创建 Key。"
    end
    local model = (conf.model and conf.model ~= "") and conf.model or AI.DEFAULT_MODEL
    local body = "{"
        .. '"model":' .. jsonString(model) .. ","
        .. '"messages":['
        .. '{"role":"system","content":' .. jsonString(AI.SYSTEM_PROMPT) .. "},"
        .. '{"role":"user","content":' .. jsonString(prompt) .. "}"
        .. "],"
        .. '"max_tokens":' .. AI.MAX_TOKENS .. ","
        .. '"stream":false'
        .. "}"
    return {
        url = AI.endpoint(conf.base),
        body = body,
        headers = { Authorization = "Bearer " .. conf.key },
    }
end

--- Strip the Markdown that models add anyway, for a plain text viewer.
function AI.plain(s)
    s = s:gsub("\r", "")
    s = s:gsub("%*%*(.-)%*%*", "%1")
    s = s:gsub("\n#+%s*", "\n"):gsub("^#+%s*", "")
    s = s:gsub("\n%s*[%*%-]%s+", "\n• "):gsub("^%s*[%*%-]%s+", "• ")
    s = s:gsub("`", "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- @param data decoded JSON or nil
-- @treturn string|nil answer
-- @treturn string|nil error message
function AI.parseResponse(data, http_code)
    if type(data) ~= "table" then
        return nil, string.format("AI 服务返回了看不懂的内容（HTTP %s），可能是接口地址不对。", tostring(http_code))
    end
    local choice = type(data.choices) == "table" and data.choices[1]
    local content = choice and choice.message and choice.message.content
    if type(content) == "string" and content ~= "" then
        local text = AI.plain(content)
        if choice.finish_reason == "length" then
            text = text .. "\n\n（回答太长，被截断了）"
        end
        return text
    end
    local err = data.error
    local msg = type(err) == "table" and (err.message or err.code) or err
    if http_code == 401 or (type(err) == "table" and tostring(err.code) == "1000") then
        return nil, "API Key 不对或已失效，请到 AI 设置里重新填写。" .. (msg and ("\n\n" .. tostring(msg)) or "")
    elseif http_code == 429 then
        return nil, "请求太频繁或额度用完了，稍后再试。" .. (msg and ("\n\n" .. tostring(msg)) or "")
    end
    if msg then
        return nil, string.format("AI 服务出错（HTTP %s）：%s", tostring(http_code), tostring(msg))
    end
    return nil, string.format("AI 没有返回回答（HTTP %s）。", tostring(http_code))
end

return AI
