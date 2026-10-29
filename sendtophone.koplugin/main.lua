--[[--
发送到手机：划词后通过 Bark 把文字推送到 iPhone。

@module koplugin.SendToPhone
--]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local Core = require("sendtophone_core")

local SendToPhone = WidgetContainer:extend{
    name = "sendtophone",
    is_doc_only = false,
}

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/sendtophone.lua"

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
    return { server = server, key = key, group = Core.DEFAULT_GROUP }
end

function SendToPhone:templateEnabled()
    return self.settings:nilOrTrue("template_enabled")
end

function SendToPhone:getTemplate()
    return self.settings:readSetting("template") or Core.DEFAULT_TEMPLATE
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
                self:sendText(text)
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

--- POST json to url. Returns http code (or nil), response body, error.
function SendToPhone:post(url, json)
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
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, requester.request{
            url = url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json; charset=utf-8",
                ["Content-Length"] = tostring(#json),
                ["User-Agent"] = socketutil.USER_AGENT,
            },
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

function SendToPhone:sendText(text)
    local title, author = self:getBookInfo()
    self:push({
        text = text,
        title = title,
        author = author,
        template = self:templateEnabled() and self:getTemplate() or nil,
    })
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
                text = "套用提问模板",
                checked_func = function() return self:templateEnabled() end,
                callback = function()
                    self.settings:saveSetting("template_enabled", not self:templateEnabled())
                    self.settings:flush()
                end,
            },
            {
                text = "编辑提问模板",
                keep_menu_open = true,
                enabled_func = function() return self:templateEnabled() end,
                callback = function()
                    self:editTemplate()
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

function SendToPhone:editTemplate()
    local dialog
    dialog = InputDialog:new{
        title = "提问模板",
        input = self:getTemplate(),
        allow_newline = true,
        description = "{text} 是选中的文字，{title} 书名，{author} 作者，{source} 是“（出自《书名》，作者）”。取不到书名或作者时，对应部分会自动去掉。",
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "恢复默认",
                callback = function()
                    self.settings:delSetting("template")
                    self.settings:flush()
                    UIManager:close(dialog)
                    showMessage("已恢复默认模板", 1)
                end,
            },
            {
                text = "保存",
                callback = function()
                    local t = dialog:getInputText()
                    if not t:find("{text}", 1, true) then
                        showMessage("模板里要有 {text}，不然选中的文字发不出去。")
                        return
                    end
                    self.settings:saveSetting("template", t)
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

return SendToPhone
