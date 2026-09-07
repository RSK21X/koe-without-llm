# koe-asr（在线 ASR）

`koe-asr` 为 Koe 提供统一的异步在线语音识别接口。本定制版只包含在线服务，不包含本地模型或本地推理代码。

## 支持的服务商

| 配置名 | 服务 | 凭证 |
|---|---|---|
| `doubaoime` | 豆包输入法在线识别 | 不需要用户填写密钥 |
| `doubao` | 火山引擎豆包 | App Key + Access Key |
| `qwen` | 阿里云百炼通义千问 | API Key |
| `glm` | 智谱 GLM | API Key |
| `mimo` | 小米 MiMo | API Key |

## 使用方式

在 `Cargo.toml` 中引用：

```toml
[dependencies]
koe-asr = { path = "../koe-asr" }
```

所有服务商都实现同一个 `AsrProvider` 接口：

```rust
use koe_asr::{AsrConfig, AsrEvent, AsrProvider, DoubaoImeProvider};

#[tokio::main]
async fn main() -> Result<(), koe_asr::AsrError> {
    let mut asr = DoubaoImeProvider::new();
    asr.connect(&AsrConfig::default()).await?;

    // 持续发送 16 kHz、单声道、16-bit little-endian PCM 音频。
    // asr.send_audio(&pcm_chunk).await?;
    asr.finish_input().await?;

    loop {
        match asr.next_event().await? {
            AsrEvent::Interim(text) => println!("中间结果：{text}"),
            AsrEvent::Definite(text) => println!("确定结果：{text}"),
            AsrEvent::Final(text) => {
                println!("最终结果：{text}");
                break;
            }
            AsrEvent::Closed(_) => break,
            _ => {}
        }
    }

    asr.close().await?;
    Ok(())
}
```

实际应用通常使用 `TranscriptAggregator` 合并中间结果、确定结果和最终结果；Koe 主程序已经包含完整的会话处理逻辑。

## 说明

- 该 crate 的在线服务调用仍需要网络连接。
- 服务商的 API 密钥由上层配置传入，不会由 crate 固定保存。
- 本定制版不再提供 Apple Speech、MLX、Sherpa-ONNX 或 WeType 后端，也不提供本地模型下载接口。

## 许可证

MIT License
