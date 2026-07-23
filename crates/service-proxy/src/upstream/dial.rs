//! Hand-rolled HTTP/1.1 request/response framing to the echo upstream.

use std::collections::HashMap;
use std::time::Duration;

use bytes::Bytes;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;

const DIAL_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub host: String,
    pub headers: HashMap<String, Vec<String>>,
    pub body: Bytes,
}

#[derive(Debug, Clone)]
pub struct Response {
    pub status_code: u16,
    pub headers: HashMap<String, Vec<String>>,
    pub body: Bytes,
}

#[derive(Debug, thiserror::Error)]
pub enum UpstreamError {
    #[error("dial: {0}")]
    Dial(#[source] std::io::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("parse: {0}")]
    Parse(String),
}

pub async fn dial(addr: &str) -> Result<TcpStream, UpstreamError> {
    tokio::time::timeout(DIAL_TIMEOUT, TcpStream::connect(addr))
        .await
        .map_err(|_| UpstreamError::Dial(std::io::Error::new(std::io::ErrorKind::TimedOut, "dial timeout")))?
        .map_err(UpstreamError::Dial)
}

pub async fn forward_http(addr: &str, req: &Request) -> Result<Response, UpstreamError> {
    let mut conn = dial(addr).await?;
    let resp = forward(&mut conn, req).await?;
    // Connection closes when conn drops.
    Ok(resp)
}

pub async fn forward<S>(conn: &mut S, req: &Request) -> Result<Response, UpstreamError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    write_request(conn, req).await?;
    read_response(conn).await
}

async fn write_request<W: AsyncWrite + Unpin>(w: &mut W, req: &Request) -> Result<(), UpstreamError> {
    let mut buf = Vec::with_capacity(256 + req.body.len());
    buf.extend_from_slice(format!("{} {} HTTP/1.1\r\n", req.method, req.path).as_bytes());
    if !req.host.is_empty() {
        buf.extend_from_slice(format!("Host: {}\r\n", req.host).as_bytes());
    }
    for (k, values) in &req.headers {
        let lower = k.to_ascii_lowercase();
        if lower == "connection" || lower == "content-length" || lower == "host" {
            continue;
        }
        for v in values {
            buf.extend_from_slice(format!("{k}: {v}\r\n").as_bytes());
        }
    }
    buf.extend_from_slice(
        format!(
            "Content-Length: {}\r\nConnection: keep-alive\r\n\r\n",
            req.body.len()
        )
        .as_bytes(),
    );
    if !req.body.is_empty() {
        buf.extend_from_slice(&req.body);
    }
    w.write_all(&buf).await?;
    w.flush().await?;
    Ok(())
}

async fn read_response<R: AsyncRead + Unpin>(r: &mut R) -> Result<Response, UpstreamError> {
    let mut reader = BufReader::new(r);
    let mut status_line = String::new();
    reader.read_line(&mut status_line).await?;
    if status_line.is_empty() {
        return Err(UpstreamError::Parse("empty status line".into()));
    }
    let mut parts = status_line.split_whitespace();
    let _version = parts.next();
    let code: u16 = parts
        .next()
        .ok_or_else(|| UpstreamError::Parse("missing status code".into()))?
        .parse()
        .map_err(|_| UpstreamError::Parse("bad status code".into()))?;

    let mut headers: HashMap<String, Vec<String>> = HashMap::new();
    let mut content_length: Option<usize> = None;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).await?;
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else {
            return Err(UpstreamError::Parse(format!("bad header: {line}")));
        };
        let name = name.trim().to_string();
        let value = value.trim().to_string();
        if name.eq_ignore_ascii_case("content-length") {
            content_length = value.parse().ok();
        }
        headers.entry(name).or_default().push(value);
    }

    let body = if let Some(n) = content_length {
        let mut buf = vec![0u8; n];
        reader.read_exact(&mut buf).await?;
        Bytes::from(buf)
    } else {
        // Echo upstream always sends Content-Length; empty body if absent.
        Bytes::new()
    };

    Ok(Response {
        status_code: code,
        headers,
        body,
    })
}

/// Write an HTTP/1.1 response to the client with Connection: close.
pub async fn write_response<W: AsyncWrite + Unpin>(
    w: &mut W,
    resp: &Response,
) -> Result<(), UpstreamError> {
    let reason = reason_phrase(resp.status_code);
    let mut buf = Vec::with_capacity(256 + resp.body.len());
    buf.extend_from_slice(format!("HTTP/1.1 {} {}\r\n", resp.status_code, reason).as_bytes());
    for (k, values) in &resp.headers {
        let lower = k.to_ascii_lowercase();
        if lower == "connection" || lower == "content-length" {
            continue;
        }
        for v in values {
            buf.extend_from_slice(format!("{k}: {v}\r\n").as_bytes());
        }
    }
    buf.extend_from_slice(
        format!(
            "Content-Length: {}\r\nConnection: close\r\n\r\n",
            resp.body.len()
        )
        .as_bytes(),
    );
    if !resp.body.is_empty() {
        buf.extend_from_slice(&resp.body);
    }
    w.write_all(&buf).await?;
    w.flush().await?;
    Ok(())
}

pub async fn write_error<W: AsyncWrite + Unpin>(w: &mut W, status: u16) -> Result<(), UpstreamError> {
    write_response(
        w,
        &Response {
            status_code: status,
            headers: HashMap::new(),
            body: Bytes::new(),
        },
    )
    .await
}

fn reason_phrase(code: u16) -> &'static str {
    match code {
        200 => "OK",
        400 => "Bad Request",
        502 => "Bad Gateway",
        500 => "Internal Server Error",
        _ => "OK",
    }
}
