# Hikvision Rename

海康威视录像机 **通道名称批量改名** 工具。图形界面，支持从 Excel 粘贴名单，可先演练再正式提交。

[![Release](https://img.shields.io/github/v/release/fig3458/hikvision-rename?style=flat-square)](https://github.com/fig3458/hikvision-rename/releases/latest)
[![License](https://img.shields.io/github/license/fig3458/hikvision-rename?style=flat-square)](LICENSE)

---

## 下载

到 [Releases](https://github.com/fig3458/hikvision-rename/releases/latest) 下载 `ChannelRename.exe`，双击即可运行。

也可以克隆本仓库后：

```text
双击「打开改名工具.bat」
```

或直接运行源码：

```bash
python rename_gui.py
```

---

## 功能

| 能力 | 说明 |
|------|------|
| 可切换录像机 | 浏览器地址可改（如 `252` / `253`） |
| 免 CSV | 从 Excel 直接复制粘贴到名单框 |
| 多格式解析 | 空格 / 制表符 / `通道号,名称` |
| 预检查 | 「检查名单」先看解析对不对 |
| 演练模式 | 只跑通流程，不真正改名 |

---

## 使用步骤

### 1. 登录录像机网页

用浏览器打开并登录录像机地址，例如：

```text
http://192.168.22.252
```

### 2. 填写 Cookie

1. 按 `F12` → **应用程序 / Application**
2. 左侧 **Cookies** → 对应站点
3. 找到以 `WebSession_` 开头的项
4. 把 **名称**、**值** 填进工具

### 3. 填写 SessionTag

1. `F12` → **网络 / Network**
2. 点任意一条请求
3. 在 Headers 里找到 `SessionTag`，复制到工具

### 4. 粘贴改名名单

每行一条，支持以下格式：

```text
# 平台IP + 通道 + 摄像头IP + 名称
192.168.22.252 D40 192.168.22.238 负2层停车场

# Excel 复制粘贴（制表符分隔）同样支持

# 简易格式
37,负2楼10号电梯口
D38,某某摄像头
```

### 5. 先演练，再正式改

1. 勾选 **只演练不真正改名** → 点「开始改名」看日志
2. 确认无误后取消勾选，再执行真正改名
3. 回到网页刷新，核对通道名称

> Cookie 过期是最常见失败原因。重新登录网页，再复制 Cookie / SessionTag 即可。

---

## 换录像机时

1. 改工具里的浏览器地址  
2. 重新登录对应地址  
3. 重新复制 Cookie / SessionTag  

---

## 仓库文件

| 文件 | 说明 |
|------|------|
| `rename_gui.py` | 图形界面主程序 |
| `打开改名工具.bat` | 启动入口 |
| `改名工具.ps1` / `rename-channels.ps1` | PowerShell 相关脚本 |
| `使用说明.txt` | 简明操作说明 |
| `ChannelRename.spec` | PyInstaller 打包配置 |

打包后的可执行文件见 Release 中的 `ChannelRename.exe`。

---

## License

[MIT](LICENSE)
