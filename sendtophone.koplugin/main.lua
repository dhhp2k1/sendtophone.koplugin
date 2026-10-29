--[[--
发送到手机：划词后通过 Bark 把文字推送到 iPhone。

@module koplugin.SendToPhone
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local Core = require("sendtophone_core")
local Translate = require("sendtophone_translate")
local AI = require("sendtophone_ai")

local SendToPhone = WidgetContainer:extend{
    name = "sendtophone",
    is_doc_only = false,
}

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/sendtophone.lua"
local DEFAULT_SHORTCUT = "问AI"

function SendToPhone:init()
    self.settings = LuaSettings:open(SETTINGS_FILE)
    if self.document and self.ui.highlight then
        self:addToHighlightDialog()
    end
    self.ui.menu:registerToMainMenu(self)
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

function SendToPhone:getConf()
    local server = self.settings:readSetting("server")
    local key = self.settings:readSetting("key")
    if not server or not key then
        return nil
    end
    return {
        server = server,
        key = key,
        group = Core.DEFAULT_GROUP,
        shortcut = self:shortcutEnabled() and self:getShortcutName() or nil,
    }
end

function SendToPhone:shortcutEnabled()
    return self.settings:isTrue("shortcut_enabled")
end

function SendToPhone:getShortcutName()
    return self.settings:readSetting("shortcut_name") or DEFAULT_SHORTCUT
end

--- The ways to ask, as {name=..., template=...}; template nil = raw text.
function SendToPhone:getPresets()
    local saved = self.settings:readSetting("presets")
    if type(saved) == "table" and #saved > 0 then
        return saved
    end
    return Core.DEFAULT_PRESETS
end

function SendToPhone:savePreset(idx, preset)
    local presets = {}
    for i, p in ipairs(self:getPresets()) do
        presets[i] = { name = p.name, template = p.template }
    end
    presets[idx] = preset
    self.settings:saveSetting("presets", presets)
    self.settings:flush()
end

function SendToPhone:askEachTime()
    return self.settings:nilOrTrue("ask_preset")
end

---------------------------------------------------------------------------
-- Highlight menu
---------------------------------------------------------------------------

function SendToPhone:addToHighlightDialog()
    -- Sort right after "12_generate_qr_code" and before "12_search".
    self.ui.highlight:addToHighlightDialog("12_qr_sendtophone", function(this)
        return {
            text = "发送到手机",
            callback = function()
                this:highlightFromHoldPos()
                local selected = this.selected_text
                local text = selected and selected.text and util.cleanupSelectedText(selected.text)
                this:onClose()
                if not text or text == "" then
                    return
                end
                self:chooseAndSend(text)
            end,
        }
    end)
    -- Same for "Wikipedia": blocked in mainland China, so ask an AI instead.
    self.ui.highlight:addToHighlightDialog("05_wikipedia", function(this)
        return {
            text = "问AI",
            callback = function()
                this:highlightFromHoldPos()
                local selected = this.selected_text
                local text = selected and selected.text and util.cleanupSelectedText(selected.text)
                this:onClose()
                if not text or text == "" then
                    return
                end
                self:choosePreset(text, "问 AI", function(preset)
                    self:askAI(text, preset)
                end, true)
            end,
        }
    end)
    -- Take over KOReader's own "Translate" slot: it uses Google, which is
    -- unreachable from mainland China.
    self.ui.highlight:addToHighlightDialog("07_translate", function(this)
        return {
            text = "翻译",
            callback = function()
                this:highlightFromHoldPos()
                local selected = this.selected_text
                local text = selected and selected.text and util.cleanupSelectedText(selected.text)
                this:onClose()
                if not text or text == "" then
                    return
                end
                self:translate(text)
            end,
        }
    end)
end

function SendToPhone:getBookInfo()
    local props = self.ui and self.ui.doc_props
    if not props then
        return nil, nil
    end
    local title = props.title
    if not title or title == "" then
        title = props.display_title
    end
    return title, props.authors
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function showMessage(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- POST body to url. Returns http code (or nil), response body, error.
function SendToPhone:post(url, json, content_type, extra_headers, block_timeout, total_timeout)
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local requester
    if url:match("^https://") then
        requester = require("ssl.https")
    else
        requester = require("socket.http")
    end
    local sink = {}
    socketutil:set_timeout(block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
                           total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    local headers_out = {
        ["Content-Type"] = content_type or "application/json; charset=utf-8",
        ["Content-Length"] = tostring(#json),
        ["User-Agent"] = socketutil.USER_AGENT,
    }
    for k, v in pairs(extra_headers or {}) do
        headers_out[k] = v
    end
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, requester.request{
            url = url,
            method = "POST",
            headers = headers_out,
            source = ltn12.source.string(json),
            sink = socketutil.table_sink and socketutil.table_sink(sink) or ltn12.sink.table(sink),
        })
    end)
    socketutil:reset_timeout()
    if not ok then
        return nil, nil, tostring(code)
    end
    if headers == nil then
        return nil, nil, tostring(status or code)
    end
    return code, table.concat(sink), nil
end

--- Send one push, showing progress and the result.
function SendToPhone:push(msg, on_success_text)
    local conf = self:getConf()
    if not conf then
        UIManager:show(InfoMessage:new{
            text = "还没有设置 Bark 地址。\n\n请到 工具 → 发送到手机 → Bark 地址 里粘贴 Bark App 给你的地址。",
        })
        return
    end
    local req = Core.buildRequest(conf, msg)
    NetworkMgr:runWhenOnline(function()
        local busy = InfoMessage:new{ text = "发送中…" }
        UIManager:show(busy)
        UIManager:forceRePaint()
        local code, body, err = self:post(req.url, req.json)
        UIManager:close(busy)
        local ok, reason = Core.interpretResponse(code, body, err)
        if ok then
            local text = on_success_text or "已发送"
            if req.truncated then
                text = text .. "\n内容过长，已截断"
            end
            showMessage(text, req.truncated and 3 or 1)
        else
            logger.warn("SendToPhone: push failed", code, err, body)
            showMessage("发送失败\n\n" .. reason)
        end
    end)
end

function SendToPhone:sendText(text, preset)
    local title, author = self:getBookInfo()
    self:push({
        text = text,
        title = title,
        author = author,
        template = preset and preset.template or nil,
    })
end

function SendToPhone:chooseAndSend(text)
    self:choosePreset(text, "发送到手机", function(preset)
        self:sendText(text, preset)
    end)
end

--- Let the user pick a way to ask, or use the first one directly.
-- skip_raw leaves out "只发原文" and other presets without a template.
function SendToPhone:choosePreset(text, title, on_choose, skip_raw)
    local presets = self:getPresets()
    if skip_raw then
        local with_template = {}
        for _, p in ipairs(presets) do
            if p.template and p.template ~= "" then
                table.insert(with_template, p)
            end
        end
        if #with_template > 0 then
            presets = with_template
        end
    end
    if not self:askEachTime() then
        on_choose(presets[1])
        return
    end
    local dialog
    local buttons = {}
    for _, preset in ipairs(presets) do
        table.insert(buttons, {{
            text = preset.name,
            callback = function()
                UIManager:close(dialog)
                on_choose(preset)
            end,
        }})
    end
    table.insert(buttons, {{
        text = "取消",
        callback = function() UIManager:close(dialog) end,
    }})
    dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

---------------------------------------------------------------------------
-- Translation shown on the Kindle
---------------------------------------------------------------------------

function SendToPhone:getEngine()
    return self.settings:readSetting("translate_engine") or "ai"
end

function SendToPhone:translate(text)
    local engine = self:getEngine()
    if engine == "ai" then
        return self:askAI(text, nil, {
            prompt = Translate.aiPrompt(text),
            title = "翻译",
            busy = "翻译中…",
            failed = "翻译失败",
        })
    end
    local req, err = Translate.buildRequest(engine, text, {
        appid = self.settings:readSetting("baidu_appid"),
        secret = self.settings:readSetting("baidu_secret"),
        salt = math.random(10000, 99999),
        md5 = function(s) return require("ffi/sha2").md5(s) end,
    })
    if not req then
        showMessage(err)
        return
    end
    NetworkMgr:runWhenOnline(function()
        local busy = InfoMessage:new{ text = "翻译中…" }
        UIManager:show(busy)
        UIManager:forceRePaint()
        local code, body, net_err = self:post(req.url, req.body, req.content_type)
        UIManager:close(busy)
        local result, reason
        if type(code) ~= "number" then
            local _, msg = Core.interpretResponse(nil, nil, net_err)
            reason = msg
        else
            local ok, data = pcall(function() return require("json").decode(body or "") end)
            result, reason = Translate.parseResponse(engine, ok and data or nil, code)
        end
        if not result then
            logger.warn("SendToPhone: translate failed", engine, code, net_err, body)
            showMessage("翻译失败\n\n" .. reason)
            return
        end
        local TextViewer = require("ui/widget/textviewer")
        UIManager:show(TextViewer:new{
            title = "翻译",
            text = result .. "\n\n――――――\n" .. text,
        })
    end)
end

---------------------------------------------------------------------------
-- Asking an AI on the Kindle
---------------------------------------------------------------------------

-- how: optional {prompt, title, busy, failed} for other uses such as
-- translation; those never search the web.
function SendToPhone:askAI(text, preset, how)
    local title, author = self:getBookInfo()
    local prompt = text
    if how then
        prompt = how.prompt
    elseif preset and preset.template then
        local template = preset.template
        if not template:find("{text}", 1, true) then
            template = template .. "\n{text}"
        end
        prompt = Core.fillTemplate(template, text, title, author)
    end
    local req, err = AI.buildRequest({
        base = self.settings:readSetting("ai_base"),
        model = self.settings:readSetting("ai_model"),
        key = self.settings:readSetting("ai_key"),
    }, prompt)
    if not req then
        showMessage(err)
        return
    end
    local search = not how and self:searchEnabled()
    if search and not AI.isDeepSeek(self.settings:readSetting("ai_base")) then
        showMessage("联网搜索只支持 DeepSeek，请在 AI 设置里换回 DeepSeek，或者关掉“问AI 时先联网搜索”。")
        return
    end
    NetworkMgr:runWhenOnline(function()
        local results, search_note
        if search then
            local busy = InfoMessage:new{ text = "联网搜索中…" }
            UIManager:show(busy)
            UIManager:forceRePaint()
            local sreq = AI.buildSearchRequest(self.settings:readSetting("ai_key"), text, prompt)
            local code, body, net_err = self:post(sreq.url, sreq.body, nil, sreq.headers, 15, 30)
            UIManager:close(busy)
            if type(code) ~= "number" then
                local _, msg = Core.interpretResponse(nil, nil, net_err)
                search_note = "联网搜索失败：" .. msg
            else
                local ok, data = pcall(function() return require("json").decode(body or "") end)
                results, search_note = AI.parseSearch(ok and data or nil, code)
            end
            if not results then
                logger.warn("SendToPhone: search failed", code, net_err, body)
            elseif #results == 0 then
                search_note = "联网没搜到相关资料，下面是 AI 自己的回答。"
            else
                req = AI.buildRequest({
                    base = self.settings:readSetting("ai_base"),
                    model = self.settings:readSetting("ai_model"),
                    key = self.settings:readSetting("ai_key"),
                }, AI.withSources(prompt, results))
            end
        end
        local busy = InfoMessage:new{ text = how and how.busy or "AI 思考中…" }
        UIManager:show(busy)
        UIManager:forceRePaint()
        local code, body, net_err = self:post(req.url, req.body, nil, req.headers, 60, 90)
        UIManager:close(busy)
        local answer, reason
        if type(code) ~= "number" then
            local _, msg = Core.interpretResponse(nil, nil, net_err)
            reason = msg
        else
            local ok, data = pcall(function() return require("json").decode(body or "") end)
            answer, reason = AI.parseResponse(ok and data or nil, code)
        end
        if not answer then
            logger.warn("SendToPhone: AI failed", code, net_err, body)
            showMessage((how and how.failed or "问 AI 失败") .. "\n\n" .. reason)
            return
        end
        local parts = { answer }
        if search_note then
            table.insert(parts, 1, "（" .. search_note .. "）")
        end
        local sources = AI.sourceList(results)
        if sources then
            table.insert(parts, sources)
        end
        table.insert(parts, "――――――\n" .. text)
        local TextViewer = require("ui/widget/textviewer")
        UIManager:show(TextViewer:new{
            title = how and how.title or preset and preset.name or "问 AI",
            text = table.concat(parts, "\n\n"),
        })
    end)
end

function SendToPhone:searchEnabled()
    return self.settings:isTrue("ai_search")
end

---------------------------------------------------------------------------
-- Main menu (工具 → 发送到手机)
---------------------------------------------------------------------------

function SendToPhone:addToMainMenu(menu_items)
    menu_items.sendtophone = {
        text = "发送到手机",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    local conf = self:getConf()
                    if conf then
                        return "Bark 地址：" .. conf.server .. "/" .. Core.maskKey(conf.key)
                    end
                    return "Bark 地址：未设置"
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editAddress(touchmenu_instance)
                end,
            },
            {
                text = "发送测试推送",
                keep_menu_open = true,
                callback = function()
                    self:push({
                        text = "来自 KOReader 的测试推送。下拉这条通知后，剪贴板里应该就是这段文字。",
                    }, "测试推送已发送，请看 iPhone")
                end,
            },
            {
                text = "划词后先选问法",
                help_text = "打开时，点“发送到手机”会先让你选一种问法。关掉后直接用第一种问法发送。",
                checked_func = function() return self:askEachTime() end,
                callback = function()
                    self.settings:saveSetting("ask_preset", not self:askEachTime())
                    self.settings:flush()
                end,
            },
            {
                text = "编辑问法",
                sub_item_table_func = function()
                    return self:presetMenuItems()
                end,
                separator = true,
            },
            {
                text = "点通知后运行快捷指令",
                help_text = "打开后，在 iPhone 上点 Bark 通知会运行同名的快捷指令，选中的文字作为输入，可以在快捷指令里直接问 ChatGPT 或 Claude。\n\n链接里也要放一份文字，所以能发送的长度大约减少到原来的四分之一。",
                checked_func = function() return self:shortcutEnabled() end,
                callback = function()
                    self.settings:saveSetting("shortcut_enabled", not self:shortcutEnabled())
                    self.settings:flush()
                end,
            },
            {
                text_func = function()
                    return "快捷指令名称：" .. self:getShortcutName()
                end,
                keep_menu_open = true,
                enabled_func = function() return self:shortcutEnabled() end,
                callback = function(touchmenu_instance)
                    self:editShortcutName(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text = "翻译设置",
                sub_item_table_func = function()
                    return self:translateMenuItems()
                end,
            },
            {
                text = "AI 设置",
                keep_menu_open = true,
                callback = function()
                    self:editAI()
                end,
            },
            {
                text = "问AI 时先联网搜索",
                help_text = "打开后，问 AI 前先用 DeepSeek 的搜索接口查一下选中的文字，把搜到的资料交给 AI 参考，回答下面列出来源。适合人名、事件、新词。\n\n每次搜索另收约 0.5 分钱（DeepSeek 按每千次 5 元收费，没搜到不收），只支持 DeepSeek 的 Key。",
                checked_func = function() return self:searchEnabled() end,
                callback = function()
                    self.settings:saveSetting("ai_search", not self:searchEnabled())
                    self.settings:flush()
                end,
            },
        },
    }
end

function SendToPhone:editAddress(touchmenu_instance)
    local conf = self:getConf()
    local dialog
    dialog = InputDialog:new{
        title = "Bark 地址",
        input = conf and (conf.server .. "/" .. conf.key .. "/") or "",
        input_hint = "https://api.day.app/你的key/",
        description = "在 iPhone 的 Bark App 首页复制地址，粘贴到这里。\n也可以只填 key，或者填自建服务器的地址。",
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "保存",
                is_enter_default = true,
                callback = function()
                    local parsed, err = Core.parseBarkUrl(dialog:getInputText())
                    if not parsed then
                        showMessage(err)
                        return
                    end
                    self.settings:saveSetting("server", parsed.server)
                    self.settings:saveSetting("key", parsed.key)
                    self.settings:flush()
                    UIManager:close(dialog)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                    showMessage("已保存。可以点“发送测试推送”试一下。", 2)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SendToPhone:editShortcutName(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = "快捷指令名称",
        input = self:getShortcutName(),
        description = "要和 iPhone 快捷指令 App 里的名字完全一样。",
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "保存",
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    if name == "" then
                        showMessage("名称不能为空")
                        return
                    end
                    self.settings:saveSetting("shortcut_name", name)
                    self.settings:flush()
                    UIManager:close(dialog)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SendToPhone:translateMenuItems()
    local items = {}
    for _, e in ipairs(Translate.ENGINES) do
        table.insert(items, {
            text = e.name,
            radio = true,
            checked_func = function() return self:getEngine() == e.id end,
            callback = function()
                self.settings:saveSetting("translate_engine", e.id)
                self.settings:flush()
            end,
        })
    end
    items[#items].separator = true
    table.insert(items, {
        text_func = function()
            local appid = self.settings:readSetting("baidu_appid")
            return "百度翻译 APP ID 和密钥：" .. (appid and Core.maskKey(appid) or "未设置")
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:editBaiduKeys(touchmenu_instance)
        end,
    })
    return items
end

function SendToPhone:editBaiduKeys(touchmenu_instance)
    local dialog
    dialog = MultiInputDialog:new{
        title = "百度翻译",
        fields = {
            { text = self.settings:readSetting("baidu_appid") or "", hint = "APP ID" },
            {
                text = self.settings:readSetting("baidu_secret") or "",
                hint = "密钥",
                description = "在 fanyi-api.baidu.com 注册，开通“通用文本翻译”（标准版免费），在“管理控制台 → 开发者信息”里能看到 APP ID 和密钥。",
            },
        },
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "保存",
                callback = function()
                    local fields = dialog:getFields()
                    local appid = (fields[1] or ""):gsub("%s", "")
                    local secret = (fields[2] or ""):gsub("%s", "")
                    if appid == "" or secret == "" then
                        showMessage("APP ID 和密钥都要填")
                        return
                    end
                    self.settings:saveSetting("baidu_appid", appid)
                    self.settings:saveSetting("baidu_secret", secret)
                    self.settings:saveSetting("translate_engine", "baidu")
                    self.settings:flush()
                    UIManager:close(dialog)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                    showMessage("已保存，翻译会改用百度", 2)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SendToPhone:editAI()
    local dialog
    dialog = MultiInputDialog:new{
        title = "AI 设置",
        fields = {
            {
                text = self.settings:readSetting("ai_key") or "",
                hint = "API Key",
                description = "默认用 DeepSeek 的 deepseek-flash（每问不到 1 分钱）：在 platform.deepseek.com 注册并充值，到“API Keys”页面创建一个 Key 填在这里。",
            },
            {
                text = self.settings:readSetting("ai_base") or "",
                hint = "接口地址（留空 = " .. AI.DEFAULT_BASE .. "）",
            },
            {
                text = self.settings:readSetting("ai_model") or "",
                hint = "模型（留空 = " .. AI.DEFAULT_MODEL .. "）",
                description = "换成智谱、Kimi 等兼容 OpenAI 格式的服务时，改接口地址、模型和 Key 就行。",
            },
        },
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "保存",
                callback = function()
                    local fields = dialog:getFields()
                    local function clean(v)
                        v = (v or ""):gsub("%s", "")
                        if v == "" then return nil end
                        return v
                    end
                    self.settings:saveSetting("ai_key", clean(fields[1]))
                    self.settings:saveSetting("ai_base", clean(fields[2]))
                    self.settings:saveSetting("ai_model", clean(fields[3]))
                    self.settings:flush()
                    UIManager:close(dialog)
                    showMessage("已保存", 1)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SendToPhone:presetMenuItems()
    local items = {}
    for i, preset in ipairs(self:getPresets()) do
        table.insert(items, {
            text_func = function()
                local p = self:getPresets()[i]
                return string.format("%d. %s", i, p and p.name or "")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:editPreset(i, touchmenu_instance)
            end,
        })
    end
    items[#items].separator = true
    table.insert(items, {
        text = "全部恢复默认",
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self.settings:delSetting("presets")
            self.settings:flush()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            showMessage("已恢复默认问法", 1)
        end,
    })
    return items
end

function SendToPhone:editPreset(idx, touchmenu_instance)
    local preset = self:getPresets()[idx]
    local dialog
    dialog = MultiInputDialog:new{
        title = "编辑问法 " .. idx,
        fields = {
            { text = preset.name, hint = "名称" },
            {
                text = preset.template or "",
                hint = "模板（留空 = 只发原文）",
                allow_newline = true,
                description = "{text} 是选中的文字，{title} 书名，{author} 作者，{source} 是“（出自《书名》，作者）”。取不到书名或作者时，对应部分会自动去掉。想让回答短一点，可以在模板里写上字数要求。",
            },
        },
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "保存",
                callback = function()
                    local fields = dialog:getFields()
                    local name = (fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    local template = fields[2] or ""
                    if name == "" then
                        showMessage("名称不能为空")
                        return
                    end
                    if template:match("^%s*$") then
                        template = nil
                    elseif not template:find("{text}", 1, true) then
                        showMessage("模板里要有 {text}，不然选中的文字发不出去。")
                        return
                    end
                    self:savePreset(idx, { name = name, template = template })
                    UIManager:close(dialog)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                    showMessage("已保存", 1)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return SendToPhone
