mod benchmark;
mod text;

use clap::{Parser, Subcommand};
use koe_core::asr_factory;

#[derive(Parser)]
#[command(name = "koe", about = "Koe voice input tool CLI")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Transcribe an audio or video file to text
    Transcribe {
        /// Path to the audio or video file (any format supported by ffmpeg)
        file: String,
        /// Show interim (partial) results as they arrive
        #[arg(long, short = 'i')]
        interim: bool,
        /// Path to DoubaoIME credentials file
        #[arg(long)]
        credentials: Option<String>,
        /// ASR provider to use (default: the provider from ~/.koe/config.yaml)
        #[arg(long, short = 'p')]
        provider: Option<String>,
    },
    /// Benchmark ASR providers over a corpus of audio files with references.
    ///
    /// The corpus directory holds audio files (any ffmpeg-supported format),
    /// each with a sibling .txt file of the same stem containing the
    /// reference transcript.
    Benchmark {
        /// Directory containing audio files + .txt reference transcripts
        corpus_dir: String,
        /// Comma-separated provider names, or "all" for every provider
        /// available in this build (default: the configured provider)
        #[arg(long)]
        providers: Option<String>,
        /// Emit JSON instead of Markdown
        #[arg(long)]
        json: bool,
    },
    /// Dictionary management
    Dict {
        #[command(subcommand)]
        action: DictCommands,
    },
}

#[derive(Subcommand)]
enum DictCommands {
    /// Add terms to the dictionary (after your confirmation)
    Add {
        /// Terms to append to ~/.koe/dictionary.txt
        #[arg(required = true)]
        terms: Vec<String>,
    },
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    // Ensure ~/.koe/ and the online-provider defaults exist
    let _ = koe_core::config::ensure_defaults();

    let result = match cli.command {
        Commands::Transcribe {
            file,
            interim,
            credentials,
            provider,
        } => transcribe(&file, interim, credentials.as_deref(), provider.as_deref()).await,
        Commands::Benchmark {
            corpus_dir,
            providers,
            json,
        } => run_benchmark(&corpus_dir, providers.as_deref(), json).await,
        Commands::Dict { action } => match action {
            DictCommands::Add { terms } => dict_add(&terms),
        },
    };

    if let Err(e) = result {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

// ─── Transcribe ─────────────────────────────────────────────────────

/// Resolve a provider-name argument against what this build supports.
/// `None` falls back to the provider configured in ~/.koe/config.yaml.
fn resolve_provider(
    cfg: &koe_core::config::Config,
    requested: Option<&str>,
) -> Result<String, String> {
    let name = requested.unwrap_or(&cfg.asr.provider).to_string();
    let supported = asr_factory::supported_providers();
    if supported.contains(&name.as_str()) {
        Ok(name)
    } else {
        Err(format!(
            "unsupported provider '{name}' (available in this build: {})",
            supported.join(", ")
        ))
    }
}

async fn transcribe(
    file: &str,
    show_interim: bool,
    credentials: Option<&str>,
    provider: Option<&str>,
) -> Result<(), String> {
    use koe_asr::{AsrEvent, TranscriptAggregator};

    let path = std::path::Path::new(file);
    if !path.exists() {
        return Err(format!("file not found: {file}"));
    }

    // Decode audio/video to raw PCM using ffmpeg
    eprintln!("Decoding {file} ...");
    let pcm_data = decode_to_pcm(file)?;
    let duration_secs = pcm_data.len() as f64 / (16000.0 * 2.0); // 16kHz, 16-bit mono
    eprintln!("Audio: {:.1}s, {} bytes PCM", duration_secs, pcm_data.len());

    let cfg = koe_core::config::load_config().map_err(|e| format!("load config: {e}"))?;
    let provider_name = resolve_provider(&cfg, provider)?;
    let (mut config, mut asr) = asr_factory::create_asr_provider(&cfg, &provider_name, &[]);

    // --credentials overrides the DoubaoIME credential path from config
    if let Some(cred_path) = credentials {
        config
            .custom_headers
            .insert("credential_path".to_string(), cred_path.to_string());
    }

    eprintln!("Connecting to {provider_name} ASR...");
    asr.connect(&config)
        .await
        .map_err(|e| format!("connect: {e}"))?;

    // Feed PCM in chunks (20ms frames = 640 bytes at 16kHz 16-bit mono)
    // Send without delay (realtime=false equivalent) for faster processing.
    const CHUNK_SIZE: usize = 640;
    for chunk in pcm_data.chunks(CHUNK_SIZE) {
        asr.send_audio(chunk)
            .await
            .map_err(|e| format!("send_audio: {e}"))?;
    }

    asr.finish_input()
        .await
        .map_err(|e| format!("finish_input: {e}"))?;

    // Collect results
    let mut aggregator = TranscriptAggregator::new();
    loop {
        match asr.next_event().await.map_err(|e| format!("event: {e}"))? {
            AsrEvent::Interim(text) => {
                aggregator.update_interim(&text);
                if show_interim {
                    eprint!("\r\x1b[2K[interim] {text}");
                }
            }
            AsrEvent::Definite(text) => {
                aggregator.update_definite(&text);
                if show_interim {
                    eprint!("\r\x1b[2K[definite] {text}");
                }
            }
            AsrEvent::Final(text) => {
                aggregator.update_final(&text);
                if show_interim {
                    eprintln!();
                }
                break;
            }
            AsrEvent::Error(msg) => {
                if show_interim {
                    eprintln!();
                }
                asr.close().await.ok();
                return Err(format!("ASR error: {msg}"));
            }
            AsrEvent::Closed(_) => {
                if show_interim {
                    eprintln!();
                }
                break;
            }
            _ => {}
        }
    }

    asr.close().await.ok();

    let result = aggregator.best_text();
    if result.is_empty() {
        eprintln!("No speech detected.");
    } else {
        println!("{result}");
    }

    Ok(())
}

// ─── Dictionary ─────────────────────────────────────────────────────

fn dict_add(terms: &[String]) -> Result<(), String> {
    let cfg = koe_core::config::load_config().map_err(|e| format!("load config: {e}"))?;
    let dict_path = koe_core::config::resolve_dictionary_path(&cfg);
    let existing = koe_core::dictionary::load_dictionary(&dict_path)
        .map_err(|e| format!("load dictionary: {e}"))?;
    let existing_lower: Vec<String> = existing.iter().map(|e| e.to_lowercase()).collect();

    let mut content = if dict_path.exists() {
        std::fs::read_to_string(&dict_path).map_err(|e| format!("read dictionary: {e}"))?
    } else {
        String::new()
    };

    let mut added = 0;
    for term in terms {
        let term = term.trim();
        if term.is_empty() {
            continue;
        }
        if existing_lower.contains(&term.to_lowercase()) {
            println!("already present: {term}");
            continue;
        }
        if !content.is_empty() && !content.ends_with('\n') {
            content.push('\n');
        }
        content.push_str(term);
        content.push('\n');
        println!("added: {term}");
        added += 1;
    }

    if added > 0 {
        std::fs::write(&dict_path, content).map_err(|e| format!("write dictionary: {e}"))?;
        println!(
            "{added} term(s) written to {} (takes effect next session)",
            dict_path.display()
        );
    }
    Ok(())
}

// ─── Benchmark ──────────────────────────────────────────────────────

async fn run_benchmark(
    corpus_dir: &str,
    providers: Option<&str>,
    json: bool,
) -> Result<(), String> {
    let cfg = koe_core::config::load_config().map_err(|e| format!("load config: {e}"))?;

    let provider_names: Vec<String> = match providers {
        None => vec![resolve_provider(&cfg, None)?],
        Some("all") => asr_factory::supported_providers()
            .iter()
            .map(|s| s.to_string())
            .collect(),
        Some(list) => list
            .split(',')
            .map(|name| resolve_provider(&cfg, Some(name.trim())).map(|_| name.trim().to_string()))
            .collect::<Result<Vec<_>, _>>()?,
    };

    let corpus = benchmark::load_corpus(std::path::Path::new(corpus_dir))?;
    eprintln!(
        "Benchmarking {} provider(s) over {} file(s)",
        provider_names.len(),
        corpus.len()
    );

    // Decode every file once; all providers consume the same PCM.
    let mut pcm_cache = Vec::with_capacity(corpus.len());
    for entry in &corpus {
        let file = entry.audio.to_string_lossy().to_string();
        eprintln!("Decoding {file} ...");
        let pcm = decode_to_pcm(&file)?;
        let audio_secs = pcm.len() as f64 / (16000.0 * 2.0);
        pcm_cache.push((audio_secs, pcm));
    }

    let mut reports = Vec::new();
    for name in &provider_names {
        eprintln!("Provider: {name}");
        reports.push(benchmark::run_provider(&cfg, name, &corpus, &pcm_cache).await);
    }

    if json {
        let value: Vec<serde_json::Value> = reports
            .iter()
            .map(|r| {
                serde_json::json!({
                    "provider": r.provider,
                    "overall_error_rate": r.overall_error_rate(),
                    "mean_finalize_ms": r.mean_finalize_ms(),
                    "mean_rtf": r.mean_rtf(),
                    "files": r.files,
                    "errors": r.errors,
                })
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&value).map_err(|e| format!("json: {e}"))?
        );
    } else {
        println!("{}", benchmark::render_markdown(&reports));
    }

    Ok(())
}

/// Decode an audio/video file to raw PCM (16kHz, mono, s16le) using ffmpeg.
fn decode_to_pcm(file: &str) -> Result<Vec<u8>, String> {
    let output = std::process::Command::new("ffmpeg")
        .args([
            "-i",
            file,
            "-f",
            "s16le",
            "-acodec",
            "pcm_s16le",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-v",
            "error",
            "pipe:1",
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                "ffmpeg not found. Please install ffmpeg to decode audio/video files.".to_string()
            } else {
                format!("failed to run ffmpeg: {e}")
            }
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("ffmpeg failed: {stderr}"));
    }

    if output.stdout.is_empty() {
        return Err("ffmpeg produced no audio output".to_string());
    }

    Ok(output.stdout)
}
