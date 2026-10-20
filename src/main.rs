//! radio.kawaii.uz — the Kawaii Radio page: a showcase of the app and the way to get it (no music here).
//!
//! nginx on the kawaii.uz server sends only `/` and `/site/*` here (see deploy.sh); everything else on the
//! domain (songs, the chat, app updates, Kawaii ID sign-in) still goes to the Cloudflare Worker, so the app
//! keeps working exactly as before. This server only asks the Worker which app build is the latest and puts
//! its version and size into the page.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use serde::Deserialize;
use tokio::sync::RwLock;

const INDEX: &str = include_str!("../web/index.html");
const CSS: &str = include_str!("../web/app.css");
const JS: &str = include_str!("../web/app.js");
const LOGO: &str = include_str!("../web/logo.svg");

/// How long the Worker's answer about the latest build is reused.
const APP_TTL: Duration = Duration::from_secs(120);

#[derive(Deserialize, Clone)]
struct AppInfo {
    version: String,
    #[serde(default)]
    size: u64,
}

struct App {
    http: reqwest::Client,
    /// The Worker, straight (not through nginx, which would send `/` back here).
    upstream: String,
    /// Address the page is seen at (for link previews).
    public: String,
    latest: RwLock<Option<(Instant, AppInfo)>>,
}

impl App {
    /// The latest app build (fresh every 2 minutes; the old answer when the Worker can't be reached).
    async fn app_info(&self) -> Option<AppInfo> {
        if let Some((at, a)) = &*self.latest.read().await {
            if at.elapsed() < APP_TTL {
                return Some(a.clone());
            }
        }
        let fresh = async {
            let r = self.http.get(format!("{}/app/latest.json", self.upstream)).send().await.ok()?;
            if !r.status().is_success() {
                return None;
            }
            r.json::<AppInfo>().await.ok()
        }
        .await;
        match fresh {
            Some(info) => {
                *self.latest.write().await = Some((Instant::now(), info.clone()));
                Some(info)
            }
            None => self.latest.read().await.as_ref().map(|(_, a)| a.clone()),
        }
    }
}

fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// The page, with the latest build's version and size already in it.
async fn index(State(app): State<Arc<App>>) -> Response {
    let info = app.app_info().await;
    let version = info.as_ref().map(|i| i.version.clone()).unwrap_or_else(|| "1.0".into());
    let size = info.as_ref().filter(|i| i.size > 0).map(|i| format!("{:.1} MB", i.size as f64 / 1_048_576.0)).unwrap_or_else(|| "APK".into());
    let html = INDEX.replace("{{VERSION}}", &esc(&version)).replace("{{SIZE}}", &esc(&size)).replace("{{PUBLIC}}", &esc(&app.public));
    let mut r = Html(html).into_response();
    r.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    r
}

fn asset(body: &'static str, kind: &'static str) -> Response {
    (
        [(header::CONTENT_TYPE, HeaderValue::from_static(kind)), (header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=300"))],
        body,
    )
        .into_response()
}

/// Only with KR_DEV=1 (trying the page on a computer): everything else goes to the Worker, as nginx does on the server.
async fn dev_passthrough(State(app): State<Arc<App>>, uri: axum::http::Uri) -> Response {
    let url = format!("{}{}", app.upstream, uri.path_and_query().map(|p| p.as_str()).unwrap_or("/"));
    let Ok(r) = app.http.get(url).send().await else { return (StatusCode::BAD_GATEWAY, "upstream").into_response() };
    let status = StatusCode::from_u16(r.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let kind = r.headers().get("content-type").and_then(|v| HeaderValue::from_bytes(v.as_bytes()).ok());
    let body = r.bytes().await.unwrap_or_default();
    let mut out = (status, body).into_response();
    if let Some(k) = kind {
        out.headers_mut().insert(header::CONTENT_TYPE, k);
    }
    out
}

#[tokio::main]
async fn main() {
    let bind: SocketAddr = std::env::var("KR_BIND").unwrap_or_else(|_| "127.0.0.1:8095".into()).parse().expect("KR_BIND: host:port");
    let app = Arc::new(App {
        http: reqwest::Client::builder().timeout(Duration::from_secs(8)).user_agent("kawaii-radio-site").build().expect("http client"),
        upstream: std::env::var("KR_UPSTREAM").unwrap_or_else(|_| "https://kawaii-radio.kawaii-radio-cloud.workers.dev".into()),
        public: std::env::var("KR_PUBLIC").unwrap_or_else(|_| "https://radio.kawaii.uz".into()),
        latest: RwLock::new(None),
    });

    let routes = Router::new()
        .route("/", get(index))
        .route("/site/app.css", get(|| async { asset(CSS, "text/css; charset=utf-8") }))
        .route("/site/app.js", get(|| async { asset(JS, "text/javascript; charset=utf-8") }))
        .route("/site/logo.svg", get(|| async { asset(LOGO, "image/svg+xml") }))
        .route("/site/health", get(|| async { "ok" }));
    let dev = std::env::var("KR_DEV").is_ok_and(|v| v == "1");
    let routes = if dev { routes.fallback(dev_passthrough) } else { routes };
    let routes = routes.with_state(app);

    let listener = tokio::net::TcpListener::bind(bind).await.expect("bind");
    println!("kawaii-radio-site on http://{bind}");
    axum::serve(listener, routes)
        .with_graceful_shutdown(async {
            let ctrl_c = tokio::signal::ctrl_c();
            #[cfg(unix)]
            {
                let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("signal");
                tokio::select! { _ = ctrl_c => {}, _ = term.recv() => {} }
            }
            #[cfg(not(unix))]
            {
                let _ = ctrl_c.await;
            }
        })
        .await
        .expect("server");
}
