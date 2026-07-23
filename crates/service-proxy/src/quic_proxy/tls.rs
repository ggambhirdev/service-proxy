//! In-memory self-signed TLS for QUIC/HTTP3 (benchmark harness only).

use std::sync::Arc;

use quinn::ServerConfig;
use rcgen::CertifiedKey;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

pub fn generate_self_signed_server_config(
    alpn: &[&str],
) -> Result<ServerConfig, Box<dyn std::error::Error + Send + Sync>> {
    let CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec!["localhost".into()])?;
    let cert_der = CertificateDer::from(cert);
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(signing_key.serialize_der()));

    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert_der], key_der)?;
    tls.alpn_protocols = alpn.iter().map(|s| s.as_bytes().to_vec()).collect();
    tls.max_early_data_size = u32::MAX;

    let mut transport = quinn::TransportConfig::default();
    transport.max_concurrent_bidi_streams(quinn::VarInt::from_u32(10_000));

    let mut server = ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(tls)?,
    ));
    server.transport = Arc::new(transport);
    Ok(server)
}
