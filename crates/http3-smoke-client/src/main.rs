use std::net::ToSocketAddrs;
use std::sync::Arc;

use bytes::{Buf, Bytes};
use clap::Parser;
use http::{Method, Request};
use quinn::ClientConfig;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};

#[derive(Parser)]
struct Args {
    #[arg(long, default_value = "https://127.0.0.1:8443/echo")]
    url: String,
    #[arg(long, default_value = "hello")]
    payload: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();

    let args = Args::parse();
    let uri: http::Uri = args.url.parse()?;
    let host = uri.host().unwrap_or("localhost");
    let port = uri.port_u16().unwrap_or(443);
    let addr = format!("{host}:{port}")
        .to_socket_addrs()?
        .next()
        .ok_or("bad addr")?;

    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(insecure_client_config()?);

    let conn = endpoint.connect(addr, host)?.await?;
    let quinn_conn = h3_quinn::Connection::new(conn);
    let (mut driver, mut send_request) = h3::client::new(quinn_conn).await?;
    tokio::spawn(async move {
        let _ = driver.wait_idle().await;
    });

    let req = Request::builder()
        .method(Method::POST)
        .uri(&args.url)
        .header("content-type", "application/octet-stream")
        .body(())?;
    let mut stream = send_request.send_request(req).await?;
    stream
        .send_data(Bytes::from(args.payload.into_bytes()))
        .await?;
    stream.finish().await?;

    let response = stream.recv_response().await?;
    let mut body = Vec::new();
    while let Some(mut chunk) = stream.recv_data().await? {
        let n = chunk.remaining();
        body.extend_from_slice(&chunk.copy_to_bytes(n));
    }
    println!(
        "status={} body={}",
        response.status(),
        String::from_utf8_lossy(&body)
    );
    Ok(())
}

fn insecure_client_config() -> Result<ClientConfig, Box<dyn std::error::Error + Send + Sync>> {
    let mut tls = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(SkipServerVerification))
        .with_no_client_auth();
    tls.alpn_protocols = vec![b"h3".to_vec()];
    Ok(ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(tls)?,
    )))
}

#[derive(Debug)]
struct SkipServerVerification;

impl rustls::client::danger::ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
