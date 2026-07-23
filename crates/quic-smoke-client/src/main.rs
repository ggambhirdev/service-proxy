use std::net::ToSocketAddrs;
use std::sync::Arc;

use clap::Parser;
use quinn::ClientConfig;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};

#[derive(Parser)]
struct Args {
    #[arg(long, default_value = "127.0.0.1:8443")]
    addr: String,
    #[arg(long, default_value = "hello")]
    payload: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();

    let args = Args::parse();
    let addr = args
        .addr
        .to_socket_addrs()?
        .next()
        .ok_or("bad addr")?;

    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(insecure_client_config()?);

    let conn = endpoint.connect(addr, "localhost")?.await?;
    let (mut send, mut recv) = conn.open_bi().await?;

    let payload = args.payload.as_bytes();
    let len = (payload.len() as u32).to_be_bytes();
    send.write_all(&len).await?;
    send.write_all(payload).await?;
    send.finish()?;

    let mut len_buf = [0u8; 4];
    recv.read_exact(&mut len_buf).await?;
    let n = u32::from_be_bytes(len_buf) as usize;
    let mut body = vec![0u8; n];
    recv.read_exact(&mut body).await?;
    println!("{}", String::from_utf8_lossy(&body));
    Ok(())
}

fn insecure_client_config() -> Result<ClientConfig, Box<dyn std::error::Error + Send + Sync>> {
    let mut tls = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(SkipServerVerification))
        .with_no_client_auth();
    tls.alpn_protocols = vec![b"service-proxy-quic".to_vec()];
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
