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

点"发送到手机"后会先让你选一种问法：

| 问法 | 发出去的问题 |
|---|---|
| 简短解释 | 用两三句话、不超过100字，解释下面这段文字在书中的意思（出自《书名》，作者）：… |
| 查词 | “选中的词”在这里是什么意思？一句话回答（出自《书名》，作者）。 |
| 翻译 | 把下面这段文字翻译成中文（原文是中文就翻译成英文），只给译文：… |
| 详细解释 | 请结合上下文解释下面这段文字（出自《书名》，作者）：… |
| 只发原文 | 选中的文字本身 |

在 工具 → 发送到手机 → 编辑问法 里可以改名字和模板，可用 `{text}`、`{title}`、`{author}`、`{source}`；模板留空就是只发原文。取不到书名或作者时，对应部分会自动去掉。关掉"划词后先选问法"，就不弹选择，直接用第一种。

## 点通知直接问 AI（快捷指令）

打开"点通知后运行快捷指令"后，在 iPhone 上点 Bark 通知，会运行一个快捷指令，选中的文字（套好模板的问题）作为输入。快捷指令里可以直接调用 ChatGPT 或 Claude App，答案弹在屏幕上，不用复制粘贴、也不用自己打开 App。

在 iPhone 的"快捷指令"App 里新建一个快捷指令，名字叫 `问AI`（和 Kindle 上设置的名称一致）：

1. 添加操作 **Ask ChatGPT**（ChatGPT App 提供）或 **Ask Claude**（Claude App 提供），把"消息/提示"设为 **快捷指令输入**。
2. 添加操作 **显示结果**（或"快速查看"），内容选上一步的回答。
3. 想留底的话，可以再加 **拷贝到剪贴板** 或 **添加到备忘录**。

第一次运行时 iOS 会问是否允许，选"始终允许"。Gemini App 的快捷指令目前不能传入文字，用不了这个方法。

代价：问题在推送里要放两份（一份显示，一份放在链接里），能发的长度大约是原来的四分之一，中文约 280 字。超出会截断并提示。

## 翻译（国内）

划词菜单里多了一个"翻译（国内）"按钮，结果直接显示在 Kindle 上，不用发到手机。中文翻成英文，其他语言翻成中文。KOReader 自带的"翻译"连的是谷歌，在国内用不了，这个是替代入口。

两个翻译引擎，在 工具 → 发送到手机 → 翻译设置 里切换：

- **微软翻译**（默认）：免费，不用任何设置。这是 Edge 浏览器内置翻译用的接口，不是官方公开的 API，以后可能会变。
- **百度翻译**：官方接口，稳定。需要在 [fanyi-api.baidu.com](https://fanyi-api.baidu.com) 注册，开通"通用文本翻译"（标准版免费），把 APP ID 和密钥填进翻译设置。填好后会自动切到百度。

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
python3 -X utf8 tests/test_translate.py
```

测试在 LuaJIT 下运行插件代码（和 Kindle 上的 KOReader 一样），KOReader 模块用假的替代。
