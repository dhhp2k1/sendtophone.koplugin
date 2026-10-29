"""Runs main.lua against mocked KOReader modules, under LuaJIT.
Run: python3 -m pip install lupa==2.8 && python3 -X utf8 tests/test_plugin.py
"""
from pathlib import Path
import json
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / "sendtophone.koplugin"
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root = str(ROOT)
lua.execute(r'''
package.path = plugin_root .. "/?.lua;" .. package.path

shown, closed, requests, online_calls = {}, {}, {}, 0
saved = {}           -- what LuaSettings wrote, by key
next_response = nil  -- function(req) -> results of https.request
http_proxy = nil

local function W(name) return function(_, t) t = t or {}; t._w = name; return t end end
package.loaded["datastorage"] = { getSettingsDir = function() return "/koreader/settings" end }
package.loaded["logger"] = { warn = function() end, dbg = function() end, err = function() end }
package.loaded["util"] = { cleanupSelectedText = function(t) return (t:gsub("^%s+", ""):gsub("%s+$", "")) end }
package.loaded["ui/widget/container/widgetcontainer"] = {
  extend = function(_, cls) cls.new = function(c, o) o = o or {}; setmetatable(o, {__index = c}); if o.init then o:init() end; return o end; return cls end }
package.loaded["ui/widget/infomessage"] = { new = function(_, t) t._w = "InfoMessage"; return t end }
package.loaded["ui/widget/buttondialog"] = { new = function(_, t) t._w = "ButtonDialog"; return t end }
package.loaded["ui/widget/multiinputdialog"] = { new = function(_, t)
  t._w = "MultiInputDialog"
  t.getFields = function(self) local r = {} for i, f in ipairs(self.fields) do r[i] = f.text end return r end
  t.onShowKeyboard = function() end; return t end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, t)
  t._w = "InputDialog"; t.getInputText = function(self) return self.input end
  t.onShowKeyboard = function() end; return t end }
package.loaded["ui/uimanager"] = {
  show = function(_, w) table.insert(shown, w) end,
  close = function(_, w) table.insert(closed, w) end,
  forceRePaint = function() end,
}
package.loaded["ui/network/manager"] = { runWhenOnline = function(_, cb) online_calls = online_calls + 1; cb() end }
package.loaded["luasettings"] = { open = function(_, path)
  settings_path = path
  return {
    readSetting = function(_, k) return saved[k] end,
    saveSetting = function(_, k, v) saved[k] = v end,
    delSetting = function(_, k) saved[k] = nil end,
    nilOrTrue = function(_, k) return saved[k] ~= false end,
    isTrue = function(_, k) return saved[k] == true end,
    flush = function() flushed = true end,
  } end }
package.loaded["ltn12"] = {
  source = { string = function(s) return s end },
  sink = { table = function(t) return t end },
}
package.loaded["socket"] = { skip = function(n, ...) return select(n + 1, ...) end }
package.loaded["socketutil"] = {
  LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30, USER_AGENT = "KOReader/test",
  set_timeout = function(self, b, t) self.cur = {b, t} end,
  reset_timeout = function(self) self.cur = nil end,
}
local function fake_request(scheme) return { request = function(req)
  req.scheme = scheme
  table.insert(requests, req)
  if http_proxy and scheme == "https" then return nil, "proxy not supported" end
  local code, body = next_response(req)
  if code == nil then return nil, body end
  table.insert(req.sink, body)
  return 1, code, {}, "HTTP/1.1 " .. code
end } end
package.loaded["ssl.https"] = fake_request("https")
package.loaded["socket.http"] = fake_request("http")

-- Fake reader UI with a highlight module.
highlight = { _highlight_buttons = {}, cleared = false }
function highlight:addToHighlightDialog(idx, fn) self._highlight_buttons[idx] = fn end
function highlight:highlightFromHoldPos() self.held = true end
function highlight:onClose(keep) if not keep then self.cleared = true end end
menu = { registerToMainMenu = function(_, p) registered = p end }
ui = { highlight = highlight, menu = menu,
       doc_props = { title = "三体", display_title = "三体", authors = "刘慈欣" } }

SendToPhone = require("main")
plugin = SendToPhone:new{ ui = ui, document = {} }
''')
G = lua.globals()

def s(v):
    return v.decode("utf-8") if isinstance(v, bytes) else v

def last_text():
    return s(G.shown[len(G.shown)].text)

def menu_items():
    items = lua.table()
    G.plugin.addToMainMenu(G.plugin, items)
    return items.sendtophone

def press_highlight(text, choice="详细解释"):
    """Tap 发送到手机, then the way to ask named `choice` (None: no picker expected)."""
    G.highlight.selected_text = lua.table_from({"text": text})
    G.highlight.cleared = False
    fn = G.highlight._highlight_buttons["12_qr_sendtophone"]
    button = fn(G.highlight)
    assert s(button.text) == "发送到手机"
    n = len(G.shown)
    button.callback()
    if choice is None or len(G.shown) == n:
        return
    dlg = G.shown[len(G.shown)]
    if s(dlg._w) != "ButtonDialog":
        return
    names = [s(dlg.buttons[i][1].text) for i in range(1, len(dlg.buttons) + 1)]
    dlg.buttons[names.index(choice) + 1][1].callback()
    return names

assert s(G.settings_path) == "/koreader/settings/sendtophone.lua"
assert G.registered is not None
keys = sorted(s(k) for k in G.highlight._highlight_buttons.keys())
assert keys == ["12_qr_sendtophone", "12_qr_sendtophone_translate"]
assert "12_generate_qr_code" < "12_qr_sendtophone" < "12_search"

# --- not configured: a clear hint, no request ------------------------------
press_highlight("  一段文字 ")
assert G.highlight.held and G.highlight.cleared
assert len(G.requests) == 0
assert "还没有设置 Bark 地址" in last_text()

# --- configure through the menu dialog ------------------------------------
items = menu_items()
assert s(items.sorting_hint) == "tools"
addr = items.sub_item_table[1]
assert s(addr.text_func()) == "Bark 地址：未设置"
addr.callback(lua.table_from({}))
dlg = G.shown[len(G.shown)]
assert s(dlg._w) == "InputDialog"
dlg.input = "不对的地址"
dlg.buttons[1][2].callback()
assert "无法识别" in last_text() or "找不到 key" in last_text(), last_text()
assert G.saved.key is None
KEY = "ynJ5Ft4atkMkWeo2PAvFhF"
dlg.input = f"https://api.day.app/{KEY}/这里改成你自己的推送内容"
tm = lua.table_from({}); tm.updated = False
lua.execute("function _upd(t) t.updated = true end")
tm.updateItems = G._upd
addr.callback(tm)
dlg = G.shown[len(G.shown)]
dlg.input = f"https://api.day.app/{KEY}/这里改成你自己的推送内容"
dlg.buttons[1][2].callback()
assert s(G.saved.server) == "https://api.day.app" and s(G.saved.key) == KEY
assert tm.updated and G.flushed
assert s(addr.text_func()) == "Bark 地址：https://api.day.app/ynJ5…vFhF"

# --- successful send from the highlight menu -------------------------------
G.next_response = lambda req: (200, '{"code":200,"message":"success","timestamp":1}')
before = len(G.shown)
press_highlight("给岁月以文明")
req = G.requests[len(G.requests)]
assert s(req.url) == "https://api.day.app/push" and s(req.method) == "POST" and s(req.scheme) == "https"
assert s(req.headers["Content-Type"]) == "application/json; charset=utf-8"
body = s(req.source)
assert int(s(req.headers["Content-Length"])) == len(body.encode("utf-8"))
payload = json.loads(body)
assert payload == {"device_key": KEY, "title": "《三体》", "group": "Kindle", "autoCopy": "1",
                   "body": "请结合上下文解释下面这段文字（出自《三体》，刘慈欣）：\n给岁月以文明"}, payload
texts = [s(G.shown[i].text) for i in range(before + 1, len(G.shown) + 1) if G.shown[i]._w == "InfoMessage"]
assert texts == ["发送中…", "已发送"], texts
assert G.package.loaded["socketutil"].cur is None, "timeouts are reset"

# --- choosing a way to ask ---------------------------------------------------
names = press_highlight("raw text", "只发原文")
assert names == ["简短解释", "查词", "翻译", "详细解释", "只发原文", "取消"], names
assert json.loads(s(G.requests[len(G.requests)].source))["body"] == "raw text"
press_highlight("serendipity", "查词")
assert json.loads(s(G.requests[len(G.requests)].source))["body"] == "“serendipity”在这里是什么意思？一句话回答（出自《三体》，刘慈欣）。"
press_highlight("hello", "翻译")
assert json.loads(s(G.requests[len(G.requests)].source))["body"].endswith("只给译文：\nhello")
n = len(G.requests)
press_highlight("x", "取消")
assert len(G.requests) == n, "cancel sends nothing"

# picker off: the first way is used directly
toggle = items.sub_item_table[3]
assert s(toggle.text) == "划词后先选问法" and toggle.checked_func() is True
toggle.callback()
assert toggle.checked_func() is False
press_highlight("直接发", None)
assert json.loads(s(G.requests[len(G.requests)].source))["body"].startswith("用两三句话")
toggle.callback()

# --- editing a way to ask ----------------------------------------------------
edit = items.sub_item_table[4]
sub = edit.sub_item_table_func()
assert [s(sub[i].text_func()) for i in range(1, 6)] == ["1. 简短解释", "2. 查词", "3. 翻译", "4. 详细解释", "5. 只发原文"]
sub[3].callback(tm)
dlg = G.shown[len(G.shown)]
assert s(dlg._w) == "MultiInputDialog"
dlg.fields[2].text = "没有占位符"
dlg.buttons[1][2].callback()
assert "{text}" in last_text() and G.saved.presets is None
dlg.fields[1].text = " 英译中 "
dlg.fields[2].text = "翻译成中文：{text}"
dlg.buttons[1][2].callback()
assert s(G.saved.presets[3].name) == "英译中"
assert s(sub[3].text_func()) == "3. 英译中"
press_highlight("hello", "英译中")
assert json.loads(s(G.requests[len(G.requests)].source))["body"] == "翻译成中文：hello"
# an empty template means raw text
sub[1].callback(tm)
dlg = G.shown[len(G.shown)]
dlg.fields[2].text = "  "
dlg.buttons[1][2].callback()
press_highlight("原样", "简短解释")
assert json.loads(s(G.requests[len(G.requests)].source))["body"] == "原样"
sub[len(sub)].callback(tm)  # 全部恢复默认
assert G.saved.presets is None

# --- long text is truncated and the user is told ---------------------------
press_highlight("长" * 3000)
assert "内容过长，已截断" in last_text()
assert len(s(G.requests[len(G.requests)].source).encode("utf-8")) < 4096

# --- failures --------------------------------------------------------------
G.next_response = lambda req: (400, '{"code":400,"message":"failed to get device token: failed to get [x] device token from database","timestamp":1}')
press_highlight("x")
assert last_text().startswith("发送失败") and "不认识这个 key" in last_text()
G.next_response = lambda req: (None, "timeout")
press_highlight("x")
assert "超时" in last_text()
G.http_proxy = True
press_highlight("x")
assert "HTTP 代理" in last_text()
G.http_proxy = None

# --- no book title (e.g. a txt without metadata) ---------------------------
G.ui.doc_props = lua.table_from({"display_title": "", "authors": ""})
G.next_response = lambda req: (200, '{"code":200,"message":"success"}')
press_highlight("文字")
p = json.loads(s(G.requests[len(G.requests)].source))
assert p["title"] == "KOReader" and p["body"] == "请结合上下文解释下面这段文字：\n文字", p

# --- test push from the menu ----------------------------------------------
items.sub_item_table[2].callback()
assert "测试推送已发送" in last_text()

# --- self-hosted http server uses socket.http ------------------------------
G.saved.server = "http://192.168.1.5:8080"
press_highlight("lan")
assert s(G.requests[len(G.requests)].scheme) == "http"
assert s(G.requests[len(G.requests)].url) == "http://192.168.1.5:8080/push"

# --- tap-to-run-shortcut option ---------------------------------------------
G.saved.server = "https://api.day.app"
items = menu_items()
sc_toggle, sc_name = items.sub_item_table[5], items.sub_item_table[6]
assert s(sc_toggle.text) == "点通知后运行快捷指令"
assert sc_toggle.checked_func() is False and sc_name.enabled_func() is False
press_highlight("无快捷指令")
assert "url" not in json.loads(s(G.requests[len(G.requests)].source))
sc_toggle.callback()
assert sc_toggle.checked_func() is True and sc_name.enabled_func() is True
assert s(sc_name.text_func()) == "快捷指令名称：问AI"
press_highlight("跑快捷指令")
p = json.loads(s(G.requests[len(G.requests)].source))
assert p["url"].startswith("shortcuts://run-shortcut?name=%E9%97%AEAI&input=text&text="), p["url"]
sc_name.callback(tm)
dlg = G.shown[len(G.shown)]
dlg.input = "  "
dlg.buttons[1][2].callback()
assert "不能为空" in last_text()
dlg.input = " Ask Claude "
dlg.buttons[1][2].callback()
assert s(G.saved.shortcut_name) == "Ask Claude"
press_highlight("x")
assert "name=Ask%20Claude&" in json.loads(s(G.requests[len(G.requests)].source))["url"]
sc_toggle.callback()

# --- empty selection sends nothing ----------------------------------------
n = len(G.requests)
press_highlight("   ")
assert len(G.requests) == n

# --- file manager (no document): no highlight hook, menu still there -------
G.registered = None
lua.execute('fm_plugin = SendToPhone:new{ ui = { menu = menu } }')
assert G.registered is not None

print("test_plugin: all passed")
