--[[--
Ask an OpenAI-compatible chat API from the Kindle and show the answer there.
Default is DeepSeek's deepseek-flash (paid, well under 1 fen per question,
reachable from mainland China); Zhipu, Kimi and others work by changing the
address, model and key. With a DeepSeek key the plugin can also search the web
first and hand the results to the model.
Pure request building and response parsing; the plugin does the HTTP.
--]]

local AI = {}

AI.DEFAULT_BASE = "https://api.deepseek.com"
AI.DEFAULT_MODEL = "deepseek-flash"
-- Bilibili's free, keyless translation model (announced 2026-10-04 as a
-- preview; no published limits). Used for 翻译 only, as a free fallback.
AI.BILIBILI_URL = "https://index-translate.bilibili.com/v1/chat/completions"
AI.BILIBILI_MODEL = "Index-Translate-35B-A3B"
AI.SEARCH_URL = "https://api.deepseek.com/v1/tools/search"
AI.SEARCH_COUNT = 5
AI.SEARCH_MAX_CHARS = 128 -- query and ori_question limit, in characters
AI.SOURCE_MAX_CHARS = 400 -- per result, to keep the prompt cheap
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

--- First n UTF-8 characters of s.
local function utf8Head(s, n)
    local count, i = 0, 1
    while i <= #s do
        if count == n then
            return s:sub(1, i - 1)
        end
        local b = s:byte(i)
        i = i + (b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1)
        count = count + 1
    end
    return s
end
AI.utf8Head = utf8Head

local function oneLine(s)
    return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
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
        return nil, "还没有填 AI 的 API Key。\n\n请到 工具 → 发送到手机 → AI 设置 里填写。默认用 DeepSeek：在 platform.deepseek.com 注册、充值后创建 Key。"
    end
    local model = (conf.model and conf.model ~= "") and conf.model or AI.DEFAULT_MODEL
    local url = AI.endpoint(conf.base)
    -- DeepSeek thinks by default: slower, pricier, and pointless for a lookup.
    local extra = url:match("^https?://api%.deepseek%.com/") and '"thinking":{"type":"disabled"},' or ""
    local body = "{"
        .. '"model":' .. jsonString(model) .. ","
        .. '"messages":['
        .. '{"role":"system","content":' .. jsonString(AI.SYSTEM_PROMPT) .. "},"
        .. '{"role":"user","content":' .. jsonString(prompt) .. "}"
        .. "],"
        .. '"max_tokens":' .. AI.MAX_TOKENS .. ","
        .. extra
        .. '"stream":false'
        .. "}"
    return {
        url = url,
        body = body,
        headers = { Authorization = "Bearer " .. conf.key },
    }
end

--- True when the chat address is DeepSeek's, so its search API can be used.
function AI.isDeepSeek(base)
    return AI.endpoint(base):match("^https?://api%.deepseek%.com/") ~= nil
end

--- Web search request: the highlighted text is the query, the full question
-- helps DeepSeek rank results.
function AI.buildSearchRequest(key, query, question)
    query = utf8Head(oneLine(query), AI.SEARCH_MAX_CHARS)
    local body = "{"
        .. '"query":' .. jsonString(query) .. ","
        .. '"count":' .. AI.SEARCH_COUNT
    if question and question ~= "" then
        body = body .. ',"ori_question":' .. jsonString(utf8Head(oneLine(question), AI.SEARCH_MAX_CHARS))
    end
    body = body .. "}"
    return {
        url = AI.SEARCH_URL,
        body = body,
        headers = { Authorization = "Bearer " .. key },
    }
end

--- @treturn table|nil list of {title, url, site, text}; empty when nothing matched
-- @treturn string|nil error message
function AI.parseSearch(data, http_code)
    if http_code == 200 and type(data) == "table" and type(data.results) == "table" then
        local out = {}
        for _, r in ipairs(data.results) do
            if type(r) == "table" then
                local text = type(r.summary) == "string" and r.summary ~= "" and r.summary
                    or type(r.snippet) == "string" and r.snippet or ""
                table.insert(out, {
                    title = type(r.title) == "string" and oneLine(r.title) or "",
                    url = type(r.url) == "string" and r.url or "",
                    site = type(r.site_name) == "string" and r.site_name or nil,
                    text = utf8Head(oneLine(text), AI.SOURCE_MAX_CHARS),
                })
            end
        end
        return out
    end
    local err = type(data) == "table" and data.error
    local msg = type(err) == "table" and (err.message or err.code) or err
    if http_code == 401 then
        return nil, "联网搜索：API Key 不对或已失效。"
    elseif http_code == 402 then
        return nil, "联网搜索：账户余额不足。"
    elseif http_code == 429 then
        return nil, "联网搜索：请求太频繁。"
    end
    return nil, string.format("联网搜索出错（HTTP %s）%s", tostring(http_code), msg and ("：" .. tostring(msg)) or "")
end

--- The question with numbered search results in front of it.
function AI.withSources(prompt, results)
    if not results or #results == 0 then
        return prompt
    end
    local lines = { "下面是联网搜索到的资料，回答时可以参考，有用到的在句末标上编号，如[1]；资料没用就忽略：" }
    for i, r in ipairs(results) do
        table.insert(lines, string.format("[%d] %s：%s", i, r.title, r.text))
    end
    table.insert(lines, "")
    table.insert(lines, "问题：" .. prompt)
    return table.concat(lines, "\n")
end

--- Numbered source list to show under the answer.
function AI.sourceList(results)
    if not results or #results == 0 then
        return nil
    end
    local lines = { "来源：" }
    for i, r in ipairs(results) do
        local host = r.url:match("^https?://([^/]+)") or r.url
        table.insert(lines, string.format("[%d] %s（%s）", i, r.title, r.site or host))
    end
    return table.concat(lines, "\n")
end

--- Translation request to Bilibili's free model: no key, no system prompt.
function AI.buildBilibiliRequest(prompt)
    local body = "{"
        .. '"model":' .. jsonString(AI.BILIBILI_MODEL) .. ","
        .. '"messages":[{"role":"user","content":' .. jsonString(prompt) .. "}],"
        .. '"temperature":0,'
        .. '"max_tokens":' .. AI.MAX_TOKENS .. ","
        .. '"chat_template_kwargs":{"enable_thinking":false},'
        .. '"stream":false'
        .. "}"
    return { url = AI.BILIBILI_URL, body = body, headers = {} }
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
    if type(content) == "string" then
        -- Some models still emit a closed thinking block; drop it.
        content = content:gsub("<think>.-</think>", "")
    end
    if type(content) == "string" and content:match("%S") and not content:find("<think>", 1, true) then
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
    elseif http_code == 402 then
        return nil, "AI 账户余额不足，请到服务商网站充值。" .. (msg and ("\n\n" .. tostring(msg)) or "")
    elseif http_code == 429 then
        return nil, "请求太频繁或额度用完了，稍后再试。" .. (msg and ("\n\n" .. tostring(msg)) or "")
    end
    if msg then
        return nil, string.format("AI 服务出错（HTTP %s）：%s", tostring(http_code), tostring(msg))
    end
    return nil, string.format("AI 没有返回回答（HTTP %s）。", tostring(http_code))
end

return AI
