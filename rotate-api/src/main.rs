//! rotate-api — on-demand VPN cover rotation HTTP API.
//!
//! Listens on 127.0.0.1:9001.  nginx proxies the secret-token paths here.
//!
//! POST /rotate/xray  — trigger xray rotation, returns 202 immediately
//! POST /rotate/mtg   — trigger mtg rotation, returns 202 immediately
//! GET  /rotate/xray  — poll status: {"running": bool}
//! GET  /rotate/mtg   — poll status: {"running": bool}
//!
//! Security:
//!   - Binds only to loopback; nginx is the only proxy.
//!   - Extra loopback check via ConnectInfo rejects any non-127.0.0.1 source.
//!   - Concurrent rotation of the same type returns 409 Conflict.

use std::{collections::HashMap, env, net::SocketAddr, path::PathBuf, sync::Arc};

use axum::{
    extract::{ConnectInfo, Path, State},
    http::StatusCode,
    response::Json,
    routing::post,
    Router,
};
use serde_json::{json, Value};
use tokio::{net::TcpListener, process::Command, sync::Mutex};

type Running = Arc<Mutex<HashMap<String, tokio::process::Child>>>;

#[tokio::main]
async fn main() {
    let running: Running = Arc::new(Mutex::new(HashMap::new()));

    let app = Router::new()
        .route("/rotate/{kind}", post(rotate).get(rotate_status))
        .with_state(running)
        .into_make_service_with_connect_info::<SocketAddr>();

    let listener = TcpListener::bind("127.0.0.1:9001")
        .await
        .expect("Failed to bind 127.0.0.1:9001");

    eprintln!("rotate-api: listening on 127.0.0.1:9001");
    axum::serve(listener, app).await.unwrap();
}

/// POST /rotate/{kind} — trigger rotation, returns 202 immediately.
async fn rotate(
    State(running): State<Running>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Path(kind): Path<String>,
) -> (StatusCode, Json<Value>) {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, Json(json!({"error": "forbidden"})));
    }

    let script_name = match kind.as_str() {
        "xray" => "rotate-reality-cover.sh",
        "mtg" => "rotate-mtg-cover.sh",
        _ => return (StatusCode::NOT_FOUND, Json(json!({"error": "unknown endpoint"}))),
    };

    let script_path = scripts_dir().join(script_name);
    let mut map = running.lock().await;

    // Return 409 if the previous child for this type is still running.
    if let Some(child) = map.get_mut(&kind) {
        if child.try_wait().unwrap_or(None).is_none() {
            return (
                StatusCode::CONFLICT,
                Json(json!({"error": "rotation already in progress"})),
            );
        }
    }

    match Command::new("bash")
        .arg(&script_path)
        // stdout is dropped; stderr inherits so rotation logs appear in journald.
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::inherit())
        .spawn()
    {
        Ok(child) => {
            let pid = child.id().unwrap_or(0);
            eprintln!("rotate-api: started {kind} rotation (pid {pid})");
            map.insert(kind, child);
            (StatusCode::ACCEPTED, Json(json!({"status": "started", "pid": pid})))
        }
        Err(e) => {
            eprintln!("rotate-api: failed to spawn {script_name}: {e}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": e.to_string()})),
            )
        }
    }
}

/// GET /rotate/{kind} — poll whether a rotation is still running.
/// Returns {"running": true|false}. The browser JS polls this after triggering
/// a rotation and reloads the credentials page as soon as running goes false.
async fn rotate_status(
    State(running): State<Running>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Path(kind): Path<String>,
) -> (StatusCode, Json<Value>) {
    if !addr.ip().is_loopback() {
        return (StatusCode::FORBIDDEN, Json(json!({"error": "forbidden"})));
    }

    if !matches!(kind.as_str(), "xray" | "mtg") {
        return (StatusCode::NOT_FOUND, Json(json!({"error": "unknown endpoint"})));
    }

    let mut map = running.lock().await;
    let is_running = map
        .get_mut(&kind)
        .map(|c| c.try_wait().unwrap_or(None).is_none())
        .unwrap_or(false);

    (StatusCode::OK, Json(json!({"running": is_running})))
}

/// Scripts live in WorkingDirectory (set by the systemd service to SCRIPT_DIR).
fn scripts_dir() -> PathBuf {
    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

