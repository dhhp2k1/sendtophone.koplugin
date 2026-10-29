"""Tests for sendtophone_core.lua, run under LuaJIT like KOReader.
Run: python3 -m pip install lupa==2.8 && python3 -X utf8 tests/test_core.py
"""
from pathlib import Path
import json
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / "sendtophone.koplugin"
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root = str(ROOT)
lua.execute('package.path = plugin_root .. "/?.lua;" .. package.path')
Core = lua.eval('require("sendtophone_core")')
# Always get two results back, even when the second one is nil.
P = lua.eval('function(f, ...) local a, b = f(...) return a, b end')

def lua_str(s):
    return s.decode("utf-8") if isinstance(s, bytes) else s

# --- Bark address parsing -------------------------------------------------
KEY = "ynJ5Ft4atkMkWeo2PAvFhF"
cases = {
    f"https://api.day.app/{KEY}/": ("https://api.day.app", KEY),
    f"https://api.day.app/{KEY}": ("https://api.day.app", KEY),
    f"  https://api.day.app/{KEY}/这里改成你自己的推送内容 \n": ("https://api.day.app", KEY),
    f"https://api.day.app/{KEY}/标题/内容?sound=minuet": ("https://api.day.app", KEY),
    f"api.day.app/{KEY}": ("https://api.day.app", KEY),
    KEY: ("https://api.day.app", KEY),
    f"http://192.168.1.5:8080/{KEY}/": ("http://192.168.1.5:8080", KEY),
    f"https://example.com/bark/{KEY}/": ("https://example.com/bark", KEY),
    "http://nas.local:8080/abc123/": ("http://nas.local:8080", "abc123"),
    f"HTTPS://api.day.app/{KEY}": ("https://api.day.app", KEY),
}
for raw, (server, key) in cases.items():
    r, err = P(Core.parseBarkUrl, raw)
    assert r is not None, (raw, err)
    assert (lua_str(r.server), lua_str(r.key)) == (server, key), (raw, r.server, r.key)

for bad in ["", "   ", "ftp://x.com/" + KEY, "https://api.day.app/", "https://a.com/x/y", "不是地址"]:
    r, err = P(Core.parseBarkUrl, bad)
    assert r is None and err, bad

assert lua_str(Core.maskKey(KEY)) == "ynJ5…vFhF"
assert lua_str(Core.maskKey("abc")) == "abc"

# --- Template --------------------------------------------------------------
T = lua_str(Core.DEFAULT_TEMPLATE)
fill = lambda *a: lua_str(Core.fillTemplate(*a))
assert fill(T, "原文", "三体", "刘慈欣") == "请结合上下文解释下面这段文字（出自《三体》，刘慈欣）：\n原文"
assert fill(T, "原文", "三体", None) == "请结合上下文解释下面这段文字（出自《三体》）：\n原文"
assert fill(T, "原文", None, "刘慈欣") == "请结合上下文解释下面这段文字（作者：刘慈欣）：\n原文"
assert fill(T, "原文", None, None) == "请结合上下文解释下面这段文字：\n原文"
assert fill(T, "原文", "  ", "\n") == "请结合上下文解释下面这段文字：\n原文"
assert fill(T, "原文", "书", "甲\n乙") == "请结合上下文解释下面这段文字（出自《书》，甲、乙）：\n原文"
# raw placeholders written by hand get the same cleanup
raw = "解释（出自《{title}》，{author}）：\n{text}"
assert fill(raw, "x", None, None) == "解释：\nx"
assert fill(raw, "x", "书", None) == "解释（出自《书》）：\nx"
assert fill(raw, "x", None, "人") == "解释（人）：\nx"
# cleanup never touches the selected text
assert fill(raw, "（）《》", None, None) == "解释：\n（）《》"
# percent signs and unknown placeholders survive
assert fill("{text} {foo}", "100%", None, None) == "100% {foo}"

# --- UTF-8 safe truncation --------------------------------------------------
ELL = "…"
def check_trunc(s, budget):
    out, cut = P(Core.truncate, s, budget)
    out = lua_str(out)  # decoding fails if a character was split
    assert int(Core.jsonCost(out)) <= budget, (s[:20], budget)
    if cut:
        assert out.endswith(ELL)
        assert s.startswith(out[:-1])
    else:
        assert out == s
    return out, cut

mixed = "中文English😀混合<&>\"\\\n" * 200
for budget in range(10, 400, 7):
    check_trunc(mixed, budget)
assert check_trunc("短", 100) == ("短", False)
out, cut = check_trunc("😀😀😀😀", 10)
assert cut and out == "😀" + ELL
# json cost follows Go's escaping
assert Core.jsonCost("a<b") == 1 + 6 + 1
assert Core.jsonCost('"\n') == 4
assert Core.jsonCost("中") == 3
assert Core.jsonCost(" ") == 6

# --- Building the request ---------------------------------------------------
conf = lua.table_from({"server": "https://api.day.app", "key": KEY, "group": "Kindle"})
msg = lua.table_from({"text": "选中的\"文字\"", "title": "三体", "author": "刘慈欣", "template": T})
req = Core.buildRequest(conf, msg)
assert lua_str(req.url) == "https://api.day.app/push"
payload = json.loads(lua_str(req.json))
assert payload == {
    "device_key": KEY,
    "title": "《三体》",
    "body": "请结合上下文解释下面这段文字（出自《三体》，刘慈欣）：\n选中的\"文字\"",
    "group": "Kindle",
    "autoCopy": "1",
}, payload
assert "copy" not in payload  # body is copied; no duplicate field
assert not req.truncated

# no template, no title
req = Core.buildRequest(conf, lua.table_from({"text": "raw"}))
payload = json.loads(lua_str(req.json))
assert payload["body"] == "raw" and payload["title"] == "KOReader"

# a very long selection is cut, the question around it is kept
long_text = "很长的段落。" * 2000
req = Core.buildRequest(conf, lua.table_from({"text": long_text, "title": "书", "template": T}))
payload = json.loads(lua_str(req.json))
assert req.truncated
assert payload["body"].startswith("请结合上下文解释下面这段文字（出自《书》）：\n很长的段落。")
assert payload["body"].endswith(ELL)
# total of what APNs sees stays under budget
total = int(Core.jsonCost(payload["body"])) + int(Core.jsonCost(payload["title"]))
assert total <= int(Core.PAYLOAD_BUDGET), total
# rough APNs payload estimate the way bark-server builds it
apns = json.dumps({"aps": {"alert": {"title": payload["title"], "body": payload["body"]},
                           "sound": "1107.caf", "category": "myNotificationCategory",
                           "mutable-content": 1, "thread-id": "Kindle"},
                   "group": "Kindle", "autocopy": "1"}, ensure_ascii=False)
assert len(apns.encode("utf-8")) < 4096, len(apns.encode("utf-8"))

# a template without {text} still sends the selection
req = Core.buildRequest(conf, lua.table_from({"text": "原文", "template": "请解释："}))
assert json.loads(lua_str(req.json))["body"] == "请解释：\n原文"

# control characters are escaped into valid JSON
req = Core.buildRequest(conf, lua.table_from({"text": "a\tb\x01c\\d"}))
assert json.loads(lua_str(req.json))["body"] == "a\tb\x01c\\d"

# --- Interpreting responses -------------------------------------------------
def interp(*a):
    ok, m = P(Core.interpretResponse, *a)
    return ok, lua_str(m)

assert interp(200, '{"code":200,"message":"success","timestamp":1}', None) == (True, None)
ok, m = interp(400, '{"code":400,"message":"failed to get device token: failed to get [x] device token from database","timestamp":1}', None)
assert not ok and "不认识这个 key" in m
ok, m = interp(500, '{"code":500,"message":"push failed: BadDeviceToken","timestamp":1}', None)
assert not ok and "500" in m and "BadDeviceToken" in m
ok, m = interp(404, "Not Found", None)
assert not ok and "404" in m
ok, m = interp(502, "", None)
assert not ok and "502" in m
for err, want in [("proxy not supported", "HTTP 代理"), ("timeout", "超时"), ("wantread", "超时"),
                  ("host not found", "找不到服务器"), ("connection refused", "拒绝连接"),
                  ("certificate verify failed", "证书"), ("something odd", "something odd"), (None, "未知")]:
    ok, m = interp(None, None, err)
    assert not ok and want in m, (err, m)

print("test_core: all passed")
