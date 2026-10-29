"""Tests for the online buttons that replace KOReader's Translate and Wikipedia
(sendtophone_translate.lua, sendtophone_ai.lua), under LuaJIT.
Run: python3 -m pip install lupa==2.8 && python3 -X utf8 tests/test_online.py
"""
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import hashlib, json
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / "sendtophone.koplugin"
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root = str(ROOT)
lua.execute('package.path = plugin_root .. "/?.lua;" .. package.path')
T = lua.eval('require("sendtophone_translate")')
P = lua.eval('function(f, ...) local a, b = f(...) return a, b end')

def s(v):
    return v.decode("utf-8") if isinstance(v, bytes) else v

def to_lua(v):
    if isinstance(v, dict):
        return lua.table_from({k: to_lua(x) for k, x in v.items()})
    if isinstance(v, list):
        return lua.table_from([to_lua(x) for x in v])
    return v

md5 = lambda x: hashlib.md5((x.encode("utf-8") if isinstance(x, str) else x)).hexdigest()

# --- direction ---------------------------------------------------------------
assert T.isMostlyCJK("给岁月以文明") and not T.isMostlyCJK("serendipity")
assert not T.isMostlyCJK("The word 道 means way")
assert T.isMostlyCJK("他说 OK")
assert s(T.target("edge", "hello")) == "zh-Hans" and s(T.target("edge", "你好")) == "en"
assert s(T.target("baidu", "hello")) == "zh" and s(T.target("baidu", "你好")) == "en"

# --- edge request --------------------------------------------------------------
req, err = P(T.buildRequest, "edge", 'He said "hi"\n')
assert err is None
u = urlparse(s(req.url))
assert u.netloc == "edge.microsoft.com" and u.path == "/translate/translatetext"
assert parse_qs(u.query)["to"] == ["zh-Hans"]
assert json.loads(s(req.body)) == ['He said "hi"\n']
assert s(req.content_type) == "application/json"

# --- baidu request -------------------------------------------------------------
req, err = P(T.buildRequest, "baidu", "hello world", lua.table_from({}))
assert req is None and "APP ID" in s(err)
opts = lua.table_from({"appid": "2015063000000001", "secret": "12345678", "salt": 1435660288, "md5": md5})
req, err = P(T.buildRequest, "baidu", "apple 苹果", opts)
assert s(req.url) == "https://fanyi-api.baidu.com/api/trans/vip/translate"
form = parse_qs(s(req.body))
assert form["q"] == ["apple 苹果"] and form["from"] == ["auto"] and form["to"] == ["en"]
assert form["sign"] == [md5("2015063000000001" + "apple 苹果" + "1435660288" + "12345678")]
# Baidu's documented example: appid 2015063000000001, q=apple, salt 1435660288, key 12345678
req, _ = P(T.buildRequest, "baidu", "apple", opts)
assert parse_qs(s(req.body))["sign"] == ["f89f9594663708c1605f3d736d01d2d4"]

# --- parsing -------------------------------------------------------------------
parse = lambda e, d, c=200: tuple(s(x) for x in P(T.parseResponse, e, to_lua(d), c))
assert parse("edge", ["你好"]) == ("你好", None)
assert parse("edge", [{"detectedLanguage": {"language": "en"}, "translations": [{"text": "你好", "to": "zh-Hans"}]}]) == ("你好", None)
r, e = parse("edge", {"error": {"code": 401000, "message": "unauthorized"}}, 401)
assert r is None and "unauthorized" in e
r, e = parse("edge", [], 200)
assert r is None and "百度" in e
r, e = parse("edge", None, 502)
assert r is None and "502" in e
assert parse("baidu", {"from": "en", "to": "zh", "trans_result": [{"src": "a", "dst": "甲"}, {"src": "b", "dst": "乙"}]}) == ("甲\n乙", None)
r, e = parse("baidu", {"error_code": "54001", "error_msg": "Invalid Sign"})
assert r is None and "签名错误" in e and "54001" in e
r, e = parse("baidu", {"error_code": "99999", "error_msg": "weird"})
assert r is None and "weird" in e

# --- the button in the plugin, with mocked KOReader ------------------------------
lua.globals().py_json_decode = lambda body: to_lua(json.loads(s(body)))
lua.globals().py_md5 = md5
lua.execute(r'''
shown, requests = {}, {}
saved = {}
next_response = nil
package.loaded["datastorage"] = { getSettingsDir = function() return "/s" end }
package.loaded["logger"] = { warn = function() end }
package.loaded["util"] = { cleanupSelectedText = function(t) return t end }
package.loaded["ui/widget/container/widgetcontainer"] = {
  extend = function(_, cls) cls.new = function(c, o) o = o or {}; setmetatable(o, {__index = c}); if o.init then o:init() end; return o end; return cls end }
package.loaded["ui/widget/infomessage"] = { new = function(_, t) t._w = "InfoMessage"; return t end }
package.loaded["ui/widget/textviewer"] = { new = function(_, t) t._w = "TextViewer"; return t end }
package.loaded["ui/widget/buttondialog"] = { new = function(_, t) t._w = "ButtonDialog"; return t end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, t) t._w = "InputDialog"; return t end }
package.loaded["ui/widget/multiinputdialog"] = { new = function(_, t)
  t._w = "MultiInputDialog"
  t.getFields = function(self) local r = {} for i, f in ipairs(self.fields) do r[i] = f.text end return r end
  t.onShowKeyboard = function() end; return t end }
package.loaded["ui/uimanager"] = { show = function(_, w) table.insert(shown, w) end, close = function() end, forceRePaint = function() end }
package.loaded["ui/network/manager"] = { runWhenOnline = function(_, cb) cb() end }
package.loaded["luasettings"] = { open = function() return {
  readSetting = function(_, k) return saved[k] end,
  saveSetting = function(_, k, v) saved[k] = v end,
  delSetting = function(_, k) saved[k] = nil end,
  nilOrTrue = function(_, k) return saved[k] ~= false end,
  isTrue = function(_, k) return saved[k] == true end,
  flush = function() end } end }
package.loaded["ltn12"] = { source = { string = function(x) return x end }, sink = { table = function(t) return t end } }
package.loaded["socket"] = { skip = function(n, ...) return select(n + 1, ...) end }
package.loaded["socketutil"] = { LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30, USER_AGENT = "t",
  set_timeout = function() end, reset_timeout = function() end }
package.loaded["ssl.https"] = { request = function(req)
  table.insert(requests, req)
  local code, body = next_response(req)
  if code == nil then return nil, body end
  table.insert(req.sink, body)
  return 1, code, {}, "x"
end }
package.loaded["json"] = { decode = function(b) return py_json_decode(b) end }
package.loaded["ffi/sha2"] = { md5 = function(x) return py_md5(x) end }
highlight = { _highlight_buttons = { ["05_wikipedia"] = function() return { text = "Wikipedia" } end, ["07_translate"] = function() return { text = "Translate" } end } }  -- KOReader's own, to be replaced
function highlight:addToHighlightDialog(idx, fn) self._highlight_buttons[idx] = fn end
function highlight:highlightFromHoldPos() end
function highlight:onClose() end
ui = { highlight = highlight, menu = { registerToMainMenu = function() end }, doc_props = {} }
plugin = require("main"):new{ ui = ui, document = {} }
''')
G = lua.globals()
keys = sorted(s(k) for k in G.highlight._highlight_buttons.keys())
assert keys == ["05_wikipedia", "07_translate", "12_qr_sendtophone"], keys

def tap_translate(text):
    G.highlight.selected_text = lua.table_from({"text": text})
    b = G.highlight._highlight_buttons["07_translate"](G.highlight)
    assert s(b.text) == "翻译"
    b.callback()
    return G.shown[len(G.shown)]

G.next_response = lambda req: (200, json.dumps([{"translations": [{"text": "意外发现珍奇事物的本领"}]}], ensure_ascii=False))
w = tap_translate("serendipity")
assert s(w._w) == "TextViewer" and s(w.text).startswith("意外发现珍奇事物的本领") and s(w.text).endswith("serendipity")
req = G.requests[len(G.requests)]
assert "edge.microsoft.com" in s(req.url) and s(req.headers["Content-Type"]) == "application/json"

G.next_response = lambda req: (None, "timeout")
w = tap_translate("x")
assert s(w._w) == "InfoMessage" and "翻译失败" in s(w.text) and "超时" in s(w.text)

G.next_response = lambda req: (404, "<html>Not Found</html>")
w = tap_translate("x")
assert "翻译失败" in s(w.text) and "404" in s(w.text)

# switch to Baidu through the settings menu
items = lua.table()
G.plugin.addToMainMenu(G.plugin, items)
sub = items.sendtophone.sub_item_table
tr = [sub[i] for i in range(1, len(sub) + 1) if s(sub[i].text) == "翻译设置"][0]
tmenu = tr.sub_item_table_func()
assert tmenu[1].checked_func() is True and tmenu[2].checked_func() is False
w = (tmenu[2].callback(), tap_translate("hello"))[1]
assert "APP ID" in s(w.text), s(w.text)
lua.execute("tm = { updateItems = function() end }")
tmenu[3].callback(G.tm)
dlg = G.shown[len(G.shown)]
dlg.fields[1].text = " 2015063000000001 "
dlg.fields[2].text = "12345678"
dlg.buttons[1][2].callback()
assert s(G.saved.baidu_appid) == "2015063000000001" and s(G.saved.translate_engine) == "baidu"
G.next_response = lambda req: (200, json.dumps({"from": "en", "to": "zh", "trans_result": [{"src": "hello", "dst": "你好"}]}, ensure_ascii=False))
w = tap_translate("hello")
assert s(w._w) == "TextViewer" and s(w.text).startswith("你好")
req = G.requests[len(G.requests)]
assert "fanyi-api.baidu.com" in s(req.url) and s(req.headers["Content-Type"]) == "application/x-www-form-urlencoded"
form = parse_qs(s(req.source))
assert form["sign"] == [md5("2015063000000001" + "hello" + form["salt"][0] + "12345678")]

# --- AI: request building and parsing ------------------------------------------
A = lua.eval('require("sendtophone_ai")')
assert s(A.endpoint(None)) == "https://api.deepseek.com/chat/completions"
assert s(A.endpoint(" https://api.deepseek.com/ ")) == "https://api.deepseek.com/chat/completions"
assert s(A.endpoint("https://x.com/v1/chat/completions")) == "https://x.com/v1/chat/completions"
req, err = P(A.buildRequest, lua.table_from({}), "q")
assert req is None and "API Key" in s(err)
req, err = P(A.buildRequest, lua.table_from({"key": "k1"}), '他说"你好"\n')
body = json.loads(s(req.body))
assert body["model"] == "deepseek-v4-pro" and body["stream"] is False and body["max_tokens"] == 800
assert body["thinking"] == {"type": "disabled"}
assert body["messages"][0]["role"] == "system" and body["messages"][1] == {"role": "user", "content": '他说"你好"\n'}
assert s(req.headers["Authorization"]) == "Bearer k1"
req, _ = P(A.buildRequest, lua.table_from({"key": "k", "model": "deepseek-chat", "base": "https://api.deepseek.com"}), "q")
assert json.loads(s(req.body))["model"] == "deepseek-chat" and s(req.url) == "https://api.deepseek.com/chat/completions"
req, _ = P(A.buildRequest, lua.table_from({"key": "k", "model": "glm-4-plus", "base": "https://open.bigmodel.cn/api/paas/v4"}), "q")
assert "thinking" not in json.loads(s(req.body)) and s(req.url) == "https://open.bigmodel.cn/api/paas/v4/chat/completions"

aparse = lambda d, c=200: tuple(s(x) for x in P(A.parseResponse, to_lua(d), c))
ok = {"choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "## 意思\n这里**孤独**指：\n- 一\n- 二"}}]}
assert aparse(ok) == ("意思\n这里孤独指：\n• 一\n• 二", None), aparse(ok)
cut = {"choices": [{"finish_reason": "length", "message": {"content": "很长"}}]}
assert aparse(cut)[0].endswith("被截断了）")
r, e = aparse({"error": {"code": "1000", "message": "身份验证失败"}}, 401)
assert r is None and "API Key 不对" in e
r, e = aparse({"error": {"code": "1302", "message": "并发数过高"}}, 429)
assert r is None and "太频繁" in e
r, e = aparse({"error": {"code": "1211", "message": "模型不存在"}}, 400)
assert r is None and "模型不存在" in e and "400" in e
r, e = aparse({"error": {"message": "Insufficient Balance"}}, 402)
assert r is None and "余额不足" in e
r, e = aparse(None, 404)
assert r is None and "接口地址" in e

# --- AI: the 问AI button ---------------------------------------------------------
def tap_ai(text, choice):
    G.highlight.selected_text = lua.table_from({"text": text})
    b = G.highlight._highlight_buttons["05_wikipedia"](G.highlight)
    assert s(b.text) == "问AI"
    n = len(G.shown)
    b.callback()
    dlg = G.shown[len(G.shown)]
    if len(G.shown) > n and s(dlg._w) == "ButtonDialog":
        assert s(dlg.title) == "问 AI"
        names = [s(dlg.buttons[i][1].text) for i in range(1, len(dlg.buttons) + 1)]
        dlg.buttons[names.index(choice) + 1][1].callback()
    return G.shown[len(G.shown)]

w = tap_ai("孤独", "查词")
assert s(w._w) == "InfoMessage" and "API Key" in s(w.text)
ai_menu = [sub[i] for i in range(1, len(sub) + 1) if s(sub[i].text) == "AI 设置"][0]
ai_menu.callback()
dlg = G.shown[len(G.shown)]
dlg.fields[1].text = " sk-abc "
dlg.buttons[1][2].callback()
assert s(G.saved.ai_key) == "sk-abc" and G.saved.ai_base is None and G.saved.ai_model is None
G.ui.doc_props = lua.table_from({"title": "百年孤独", "authors": "马尔克斯"})
G.next_response = lambda req: (200, json.dumps(ok, ensure_ascii=False))
w = tap_ai("孤独", "查词")
assert s(w._w) == "TextViewer" and s(w.title) == "查词"
assert s(w.text).startswith("意思") and s(w.text).endswith("孤独")
req = G.requests[len(G.requests)]
assert s(req.url) == "https://api.deepseek.com/chat/completions"
assert s(req.headers["Authorization"]) == "Bearer sk-abc"
assert json.loads(s(req.source))["messages"][1]["content"] == "“孤独”在这里是什么意思？一句话回答（出自《百年孤独》，马尔克斯）。"
w = tap_ai("原样", "只发原文")
assert json.loads(s(G.requests[len(G.requests)].source))["messages"][1]["content"] == "原样"
G.next_response = lambda req: (None, "wantread")
w = tap_ai("x", "查词")
assert "问 AI 失败" in s(w.text) and "超时" in s(w.text)

print("test_online: all passed")
