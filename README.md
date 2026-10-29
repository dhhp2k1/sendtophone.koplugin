# 发送到手机（sendtophone.koplugin）

KOReader 小插件：在书里划词后点"发送到手机"，文字通过 [Bark](https://github.com/Finb/Bark) 推送到 iPhone。下拉或长按通知，文字就进了剪贴板，直接粘贴到 ChatGPT、Claude 或 Gemini 的 App 里提问。

这是独立插件，不依赖也不修改 SimpleUI。

## 安装（USB）

1. 在 KOReader 里退出（菜单 → 退出），再用 USB 连接电脑。
2. 把 `sendtophone.koplugin` 整个文件夹拷到 Kindle 的 `koreader/plugins/` 下。
3. 在电脑上安全弹出，拔线，启动 KOReader。

## 第一次设置

1. iPhone 上打开 Bark App，首页会有一个地址，形如 `https://api.day.app/xxxxxxxx/`，复制它。
2. 在 Kindle 上：菜单 → 工具 → 发送到手机 → Bark 地址，粘贴后点"保存"。
   - 在 Kindle 上手打很麻烦，可以把地址存成 `bark.txt` 拷进 Kindle，在 KOReader 里打开它，长按复制，再粘贴进来。
   - 也可以只填 key，或者填自建服务器地址（例如 `http://192.168.1.5:8080/key/`）。
3. 点"发送测试推送"，iPhone 收到通知就说明通了。

## 用法

划词 → 高亮菜单里点"发送到手机" → iPhone 收到通知 → 下拉通知（文字自动进剪贴板）→ 打开 AI App 粘贴。

默认会把文字套进提问模板：

```
请结合上下文解释下面这段文字（出自《书名》，作者）：
选中的文字
```

在"编辑提问模板"里可以改，可用 `{text}`、`{title}`、`{author}`、`{source}`。取不到书名或作者时，对应部分会自动去掉。关掉"套用提问模板"就只发原文。

## 细节

- 设置保存在 `koreader/settings/sendtophone.lua`。
- 苹果推送有 4KB 上限，太长的选段会在字符边界截断，末尾加"…"，发送成功时会提示"内容过长，已截断"。截断只发生在选中的文字上，模板部分保留。
- KOReader 的"HTTP 代理"开着时，HTTPS 请求会失败（KOReader 的 HTTPS 库不支持代理），插件会提示你关掉。
- 出错时看 `koreader/crash.log`，搜索 `SendToPhone`。

## 开发

```
python3 -m pip install lupa==2.8
python3 -X utf8 tests/test_core.py
python3 -X utf8 tests/test_plugin.py
```

测试在 LuaJIT 下运行插件代码（和 Kindle 上的 KOReader 一样），KOReader 模块用假的替代。
