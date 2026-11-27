//! 新版站点边缘加密协议（dx150-edge-v1）。
//!
//! 站点前端实现见 `/static/web/js/edge-api-crypto.js`：
//! ECDH P-256 握手 → HKDF-SHA256 派生双向密钥 → AES-256-GCM 信封。
//! 旧的 `/api/edge/request` 信封已经停用（HTTP 503），新版按 scope 拆分到
//! `/api/{public,dynamic,playback,user}/request`。

use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use hkdf::Hkdf;
use once_cell::sync::Lazy;
use p256::ecdh::EphemeralSecret;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::PublicKey;
use rand_core::OsRng;
use serde_json::{json, Value};
use sha2::Sha256;
use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

const PROTOCOL: &str = "dx150-edge-v1";
const MAX_SEQUENCE: u32 = 16384;

#[derive(Clone)]
struct Session {
    kid: String,
    sid: String,
    info: String,
    clock_offset: i64,
    expires_at: i64,
    sequence: u32,
    request_key: [u8; 32],
    response_key: [u8; 32],
    visitor: Option<String>,
}

static SESSIONS: Lazy<Mutex<HashMap<String, Session>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static OPEN_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn derive_key(shared: &[u8], salt: &[u8], info: &str, direction: &str) -> Result<[u8; 32], String> {
    let hk = Hkdf::<Sha256>::new(Some(salt), shared);
    let mut key = [0u8; 32];
    hk.expand(format!("{info}\n{direction}").as_bytes(), &mut key)
        .map_err(|_| "加密密钥派生失败".to_string())?;
    Ok(key)
}

fn nonce(sequence: u32) -> [u8; 12] {
    let mut iv = [0u8; 12];
    iv[8..12].copy_from_slice(&sequence.to_be_bytes());
    iv
}

fn additional_data(info: &str, direction: &str, sequence: u32, ts: i64) -> Vec<u8> {
    format!("{info}\n{direction}\n{sequence}\n{ts}").into_bytes()
}

fn encrypt(key: &[u8; 32], iv: &[u8; 12], aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| "加密密钥无效".to_string())?;
    cipher
        .encrypt(Nonce::from_slice(iv), Payload { msg: plaintext, aad })
        .map_err(|_| "请求加密失败".to_string())
}

fn decrypt(key: &[u8; 32], iv: &[u8; 12], aad: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>, String> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| "加密密钥无效".to_string())?;
    cipher
        .decrypt(Nonce::from_slice(iv), Payload { msg: ciphertext, aad })
        .map_err(|_| "响应解密失败".to_string())
}

async fn open_session(origin: &str, scope: &str) -> Result<Session, String> {
    let secret = EphemeralSecret::random(&mut OsRng);
    let client_pub = secret.public_key().to_encoded_point(false);
    let hello = json!({
        "v": 1,
        "type": "hello",
        "client_pub": URL_SAFE_NO_PAD.encode(client_pub.as_bytes()),
    });
    let url = format!("{origin}/api/{scope}/request");
    let resp = crate::net::raw_request("POST", &url, Some(&hello), None).await?;
    let status = resp.status();
    let visitor = resp
        .headers()
        .get("x-edge-visitor")
        .or_else(|| resp.headers().get("x-hg-visitor"))
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let text = resp.text().await.map_err(|e| crate::net::err_text(&e))?;
    if !status.is_success() {
        return Err(format!("加密握手失败 (HTTP {})", status.as_u16()));
    }
    let hello: Value =
        serde_json::from_str(&text).map_err(|_| "加密握手响应无效".to_string())?;
    if hello.get("v").and_then(Value::as_i64) != Some(1)
        || hello.get("type").and_then(Value::as_str) != Some("hello")
    {
        return Err("加密握手响应无效".into());
    }
    let kid = hello
        .get("kid")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or("加密握手响应无效")?
        .to_string();
    let sid = hello
        .get("sid")
        .and_then(Value::as_str)
        .filter(|s| s.len() >= 16)
        .ok_or("加密握手响应无效")?
        .to_string();
    let site = hello
        .get("site")
        .and_then(Value::as_str)
        .ok_or("加密握手响应无效")?
        .to_string();
    let server_time = hello
        .get("server_time")
        .and_then(Value::as_i64)
        .ok_or("加密握手响应无效")?;
    let expires_at = hello
        .get("expires_at")
        .and_then(Value::as_i64)
        .ok_or("加密握手响应无效")?;
    if expires_at <= server_time || expires_at - server_time > 600 {
        return Err("加密握手响应无效".into());
    }
    let server_pub_raw = URL_SAFE_NO_PAD
        .decode(
            hello
                .get("server_pub")
                .and_then(Value::as_str)
                .ok_or("加密握手响应无效")?,
        )
        .map_err(|_| "加密握手响应无效")?;
    let salt = URL_SAFE_NO_PAD
        .decode(
            hello
                .get("salt")
                .and_then(Value::as_str)
                .ok_or("加密握手响应无效")?,
        )
        .map_err(|_| "加密握手响应无效")?;
    if salt.len() != 32 {
        return Err("加密握手响应无效".into());
    }
    let server_pub = PublicKey::from_sec1_bytes(&server_pub_raw).map_err(|_| "加密握手响应无效")?;
    let shared = secret.diffie_hellman(&server_pub);
    let info = format!("{PROTOCOL}\n{scope}\n{site}\n{kid}\n{sid}");
    let request_key = derive_key(shared.raw_secret_bytes().as_slice(), &salt, &info, "req")?;
    let response_key = derive_key(shared.raw_secret_bytes().as_slice(), &salt, &info, "res")?;
    let now = now_secs();
    Ok(Session {
        kid,
        sid,
        info,
        clock_offset: server_time - now,
        expires_at: now + (expires_at - server_time),
        sequence: 0,
        request_key,
        response_key,
        visitor,
    })
}

async fn get_session(origin: &str, scope: &str) -> Result<Session, String> {
    let key = format!("{origin}|{scope}");
    let now = now_secs();
    {
        let sessions = SESSIONS.lock().await;
        if let Some(session) = sessions.get(&key) {
            if session.expires_at > now + 5 && session.sequence < MAX_SEQUENCE {
                return Ok(session.clone());
            }
        }
    }
    let _guard = OPEN_LOCK.lock().await;
    {
        let sessions = SESSIONS.lock().await;
        if let Some(session) = sessions.get(&key) {
            if session.expires_at > now + 5 && session.sequence < MAX_SEQUENCE {
                return Ok(session.clone());
            }
        }
    }
    let session = open_session(origin, scope).await?;
    SESSIONS.lock().await.insert(key, session.clone());
    Ok(session)
}

/// 发起一次加密业务请求，返回内层 HTTP 状态码和响应正文。
pub async fn call(
    origin: &str,
    scope: &str,
    method: &str,
    path: &str,
    body: Option<&Value>,
    token: Option<&str>,
) -> Result<(u16, String), String> {
    let cache_key = format!("{origin}|{scope}");
    let mut last_error = String::new();
    for _ in 0..2 {
        let mut session = get_session(origin, scope).await?;
        let sequence = {
            let mut sessions = SESSIONS.lock().await;
            match sessions.get_mut(&cache_key) {
                Some(current) if current.sequence < MAX_SEQUENCE => {
                    current.sequence += 1;
                    session = current.clone();
                    current.sequence
                }
                _ => 0,
            }
        };
        if sequence == 0 {
            SESSIONS.lock().await.remove(&cache_key);
            last_error = "加密会话已到期".into();
            continue;
        }

        let (encoded, ctype) = match body {
            Some(value) => (
                STANDARD.encode(serde_json::to_vec(value).map_err(|e| e.to_string())?),
                "application/json",
            ),
            None => (String::new(), ""),
        };
        let mut request = json!({
            "method": method,
            "path": path,
            "body": encoded,
            "content_type": ctype,
        });
        if let Some(visitor) = &session.visitor {
            request["visitor_id"] = json!(visitor);
        }
        let mut packet = json!({ "request": request });
        if let Some(value) = token {
            if !value.is_empty() {
                packet["authorization"] = json!(format!("Bearer {value}"));
            }
        }

        let ts = now_secs() + session.clock_offset;
        let iv = nonce(sequence);
        let plaintext = serde_json::to_vec(&packet).map_err(|e| e.to_string())?;
        let aad = additional_data(&session.info, "req", sequence, ts);
        let ciphertext = encrypt(&session.request_key, &iv, &aad, &plaintext)?;
        let payload = json!({
            "v": 1,
            "type": "call",
            "kid": session.kid,
            "sid": session.sid,
            "seq": sequence,
            "ts": ts,
            "ciphertext": URL_SAFE_NO_PAD.encode(ciphertext),
        });
        let url = format!("{origin}/api/{scope}/request");
        let resp = crate::net::raw_request("POST", &url, Some(&payload), None).await?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| crate::net::err_text(&e))?;
        if !status.is_success() {
            if text.contains("session_expired") {
                SESSIONS.lock().await.remove(&cache_key);
                last_error = "加密会话已到期".into();
                continue;
            }
            return Err(format!("加密接口请求失败 (HTTP {})", status.as_u16()));
        }
        let result: Value =
            serde_json::from_str(&text).map_err(|_| "加密接口响应无效".to_string())?;
        if result.get("type").and_then(Value::as_str) != Some("result") {
            if result.get("error").and_then(Value::as_str) == Some("session_expired") {
                SESSIONS.lock().await.remove(&cache_key);
                last_error = "加密会话已到期".into();
                continue;
            }
            return Err("加密接口响应无效".into());
        }
        if result.get("sid").and_then(Value::as_str) != Some(session.sid.as_str())
            || result.get("kid").and_then(Value::as_str) != Some(session.kid.as_str())
            || result.get("seq").and_then(Value::as_u64) != Some(sequence as u64)
            || result.get("ts").and_then(Value::as_i64) != Some(ts)
        {
            return Err("加密接口响应不匹配".into());
        }
        let cipher = URL_SAFE_NO_PAD
            .decode(
                result
                    .get("ciphertext")
                    .and_then(Value::as_str)
                    .ok_or("加密接口响应无效")?,
            )
            .map_err(|_| "加密接口响应无效")?;
        let aad = additional_data(&session.info, "res", sequence, ts);
        let plaintext = decrypt(&session.response_key, &iv, &aad, &cipher)?;
        let inner: Value =
            serde_json::from_slice(&plaintext).map_err(|_| "加密接口响应无效".to_string())?;
        let inner_status = inner
            .get("status")
            .and_then(Value::as_u64)
            .ok_or("加密接口响应无效")? as u16;
        let body_text = inner.get("body").and_then(Value::as_str).unwrap_or("");
        let bytes = if body_text.is_empty() {
            Vec::new()
        } else {
            STANDARD
                .decode(body_text)
                .map_err(|_| "加密接口响应无效")?
        };
        return Ok((inner_status, String::from_utf8_lossy(&bytes).into_owned()));
    }
    Err(if last_error.is_empty() {
        "加密接口请求失败".to_string()
    } else {
        last_error
    })
}
