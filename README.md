# Koe（声）— 在线语音输入定制版

这是基于 [Koe](https://github.com/missuo/koe) 的 macOS 在线语音输入定制版。

## 定制内容

- 只保留在线 ASR：豆包输入法（DoubaoIME）、豆包、通义千问、GLM、MiMo。
- 移除本地语音模型、模型下载、本地语音权限和对应 Swift/Rust 依赖。
- 移除 LLM 文本修正、LLM 配置、提示词、模板和模型管理界面。
- 设置界面改为中文，仅保留语音识别、快捷键、悬浮窗、词典和关于页面。
- 增加“句末去除标点”开关，位置为“设置 → 悬浮窗 → 显示设置”。
- 悬浮窗使用黑白灰配色，不使用红、蓝、橙等状态色。

## 编译要求

- macOS 14 或更高版本
- Apple Silicon Mac
- Xcode 和命令行工具
- Rust（通过 `rustup` 安装）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 从源码编译

```bash
git clone https://github.com/RSK21X/koe-without-llm.git
cd koe-without-llm
make build
```

`make build` 会自动生成 Xcode 项目、编译 Rust 和 macOS 应用，并将命令行组件放入应用包中。

编译后的应用通常位于：

```text
~/Library/Developer/Xcode/DerivedData/Koe-*/Build/Products/Release/Koe.app
```

也可以只编译 Rust 部分：

```bash
make build-rust
```

本定制版不再提供 `make build-mlx`。

## 在线 ASR 配置

首次启动后，配置文件位于 `~/.koe/config.yaml`。默认服务商是免费的豆包输入法：

```yaml
asr:
  provider: doubaoime

output:
  strip_trailing_punctuation: false
```

将 `strip_trailing_punctuation` 改为 `true`，或在设置界面打开“句末去除标点”，即可移除识别结果末尾常见的中英文标点。它只处理句末，不会删除正文中的标点。

在线服务的密钥仍保存在 `~/.koe/config.yaml` 中；豆包输入法不需要用户填写 API 密钥，但使用时需要网络连接。

## 运行所需权限

- 麦克风：采集语音。
- 辅助功能：将识别结果自动粘贴到当前应用。
- 输入监控：监听全局快捷键。

本版本不再使用 Apple Speech，因此不会申请“语音识别”权限。

## 许可证

本项目沿用上游的 MIT License。修改后的源码仍可自行编译和继续修改。
