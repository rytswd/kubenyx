//! The one shared "no server verification" TLS piece for kubenyx's
//! probe-style clients (kubenyx-ready, kubenyx-snap, kubenyx-lb). These
//! probes ask "is this port serving TLS+HTTP?", never "who are you?" —
//! self-signed component endpoints (kcm/scheduler healthz) and guest CAs
//! that are unreachable from the host by design make identity checks
//! meaningless there. Deduplicated into this crate so the dangerous bit
//! has exactly one implementation to audit; anything that DOES care about
//! identity must build a verifying config itself (kubenyx-ready's
//! --cacert path is the template).

use std::sync::Arc;

/// Accepts any server certificate. Handshake signature verification still
/// runs (a garbage handshake fails); only the identity/chain check is
/// skipped.
#[derive(Debug)]
pub struct NoVerify(pub Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

/// ClientConfig builder with the ring provider, safe default protocol
/// versions and NoVerify installed. Callers finish it with their client
/// auth choice (`with_no_client_auth()` / `with_client_auth_cert(..)`).
pub fn insecure_client_builder(
) -> rustls::ConfigBuilder<rustls::ClientConfig, rustls::client::WantsClientCert> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .expect("tls versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoVerify(provider)))
}
