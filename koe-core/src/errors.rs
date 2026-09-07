use std::fmt;

#[derive(Debug)]
pub enum KoeError {
    Config(String),
    SessionInvalidState { from: String, action: String },
    PermissionDenied(String),
    PasteFailed(String),
    AudioBuffer(String),
    Internal(String),
}

impl fmt::Display for KoeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            KoeError::Config(msg) => write!(f, "config error: {msg}"),
            KoeError::SessionInvalidState { from, action } => {
                write!(f, "invalid state transition: {action} from {from}")
            }
            KoeError::PermissionDenied(msg) => write!(f, "permission denied: {msg}"),
            KoeError::PasteFailed(msg) => write!(f, "paste failed: {msg}"),
            KoeError::AudioBuffer(msg) => write!(f, "audio buffer error: {msg}"),
            KoeError::Internal(msg) => write!(f, "internal error: {msg}"),
        }
    }
}

impl std::error::Error for KoeError {}

pub type Result<T> = std::result::Result<T, KoeError>;
