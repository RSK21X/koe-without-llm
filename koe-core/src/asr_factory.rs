//! Construction of ASR providers from configuration.
//!
//! Extracted from the session-start path so that other entry points
//! (koe-cli transcription and benchmarking) can build the same providers
//! from the same config without duplicating per-provider wiring.

use crate::config::{self, Config};
use koe_asr::{
    AsrConfig, AsrProvider, DoubaoImeProvider, DoubaoWsProvider, GlmAsrProvider, MimoAsrProvider,
    QwenAsrProvider,
};

/// Provider names that can be constructed in this build.
/// This product build deliberately exposes online ASR providers only.
pub fn supported_providers() -> Vec<&'static str> {
    vec!["doubaoime", "doubao", "qwen", "glm", "mimo"]
}

/// Build the `AsrConfig` and provider instance for `provider_name`.
///
/// Unknown names — including local providers not compiled into this build —
/// fall back to the Doubao WebSocket provider, mirroring the historical
/// session-start behaviour. Callers that want an explicit error instead
/// should validate against [`supported_providers`] first.
///
/// `dictionary` feeds provider-side hotword biasing where supported
/// (for example, Doubao hotwords).
pub fn create_asr_provider(
    cfg: &Config,
    provider_name: &str,
    dictionary: &[String],
) -> (AsrConfig, Box<dyn AsrProvider>) {
    match provider_name {
        "doubaoime" => {
            let ime = &cfg.asr.doubaoime;
            let credential_path = if std::path::Path::new(&ime.credential_path).is_absolute() {
                ime.credential_path.clone()
            } else {
                config::config_dir()
                    .join(&ime.credential_path)
                    .to_string_lossy()
                    .to_string()
            };
            let mut custom_headers = std::collections::HashMap::new();
            custom_headers.insert("credential_path".to_string(), credential_path);
            let config = AsrConfig {
                url: String::new(),
                app_key: String::new(),
                access_key: String::new(),
                api_key: String::new(),
                resource_id: String::new(),
                sample_rate_hz: 16000,
                connect_timeout_ms: ime.connect_timeout_ms,
                final_wait_timeout_ms: ime.final_wait_timeout_ms,
                enable_ddc: false,
                enable_itn: false,
                enable_punc: true,
                enable_nonstream: false,
                hotwords: Vec::new(),
                language: None,
                custom_headers,
                end_window_size: None,
                force_to_speech_time: None,
                vad_segment_duration: None,
                output_zh_variant: None,
                enable_accelerate_text: false,
                accelerate_score: None,
                context_messages: Vec::new(),
            };
            (config, Box::new(DoubaoImeProvider::new()))
        }
        "qwen" => {
            let qwen = &cfg.asr.qwen;
            let config = AsrConfig {
                url: qwen.url.clone(),
                app_key: qwen.model.clone(),
                access_key: qwen.api_key.clone(),
                api_key: String::new(),
                resource_id: String::new(),
                sample_rate_hz: 16000,
                connect_timeout_ms: qwen.connect_timeout_ms,
                final_wait_timeout_ms: qwen.final_wait_timeout_ms,
                enable_ddc: false,
                enable_itn: false,
                enable_punc: false,
                enable_nonstream: false,
                hotwords: Vec::new(),
                language: Some(qwen.language.clone()),
                custom_headers: qwen.headers.clone(),
                end_window_size: None,
                force_to_speech_time: None,
                vad_segment_duration: None,
                output_zh_variant: None,
                enable_accelerate_text: false,
                accelerate_score: None,
                context_messages: Vec::new(),
            };
            (config, Box::new(QwenAsrProvider::new()))
        }
        "glm" => {
            let glm = &cfg.asr.glm;
            let config = AsrConfig {
                url: glm.url.clone(),
                app_key: glm.model.clone(),
                access_key: glm.api_key.clone(),
                api_key: glm.api_key.clone(),
                resource_id: String::new(),
                sample_rate_hz: 16000,
                connect_timeout_ms: glm.connect_timeout_ms,
                final_wait_timeout_ms: glm.final_wait_timeout_ms,
                enable_ddc: false,
                enable_itn: false,
                enable_punc: false,
                enable_nonstream: false,
                hotwords: Vec::new(),
                language: glm.prompt.clone(),
                custom_headers: std::collections::HashMap::new(),
                end_window_size: None,
                force_to_speech_time: None,
                vad_segment_duration: None,
                output_zh_variant: None,
                enable_accelerate_text: false,
                accelerate_score: None,
                context_messages: Vec::new(),
            };
            (config, Box::new(GlmAsrProvider::new()))
        }
        "mimo" => {
            let mimo = &cfg.asr.mimo;
            let config = AsrConfig {
                url: mimo.url.clone(),
                app_key: mimo.model.clone(),
                access_key: String::new(),
                api_key: mimo.api_key.clone(),
                resource_id: String::new(),
                sample_rate_hz: 16000,
                connect_timeout_ms: mimo.connect_timeout_ms,
                final_wait_timeout_ms: mimo.final_wait_timeout_ms,
                enable_ddc: false,
                enable_itn: false,
                enable_punc: false,
                enable_nonstream: false,
                hotwords: Vec::new(),
                language: Some(mimo.language.clone()),
                custom_headers: std::collections::HashMap::new(),
                end_window_size: None,
                force_to_speech_time: None,
                vad_segment_duration: None,
                output_zh_variant: None,
                enable_accelerate_text: false,
                accelerate_score: None,
                context_messages: Vec::new(),
            };
            (config, Box::new(MimoAsrProvider::new()))
        }
        _ => {
            let doubao = &cfg.asr.doubao;
            let config = AsrConfig {
                url: doubao.url.clone(),
                app_key: doubao.app_key.clone(),
                access_key: doubao.access_key.clone(),
                api_key: doubao.api_key.clone(),
                resource_id: doubao.resource_id.clone(),
                sample_rate_hz: 16000,
                connect_timeout_ms: doubao.connect_timeout_ms,
                final_wait_timeout_ms: doubao.final_wait_timeout_ms,
                enable_ddc: doubao.enable_ddc,
                enable_itn: doubao.enable_itn,
                enable_punc: doubao.enable_punc,
                enable_nonstream: doubao.enable_nonstream,
                hotwords: dictionary.to_vec(),
                language: doubao.language.clone(),
                custom_headers: doubao.headers.clone(),
                end_window_size: doubao.end_window_size,
                force_to_speech_time: doubao.force_to_speech_time,
                vad_segment_duration: doubao.vad_segment_duration,
                output_zh_variant: doubao.output_zh_variant.clone(),
                enable_accelerate_text: doubao.enable_accelerate_text,
                accelerate_score: doubao.accelerate_score,
                context_messages: Vec::new(),
            };
            (config, Box::new(DoubaoWsProvider::new()))
        }
    }
}
