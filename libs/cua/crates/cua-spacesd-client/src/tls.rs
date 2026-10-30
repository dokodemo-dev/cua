// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Cua AI, Inc.

//! Same bundled + native trust policy as the SDK's reqwest auth/discovery clients.
use crate::{Error, Result};
use rustls::{ClientConfig, RootCertStore};
use std::sync::Arc;

/// Roots that stay in the bundled list after their operator's keys were
/// compromised (2026-10 eMudhra incident). Apple's store and Mozilla already
/// distrust them; the bundled list lags behind, so the SDK filters them out
/// here rather than trusting a compromised CA on relay and gRPC connections.
/// Matching is on the subject name as ASCII, which appears verbatim inside the
/// DER of the Name; no X.509 parser is needed for two fixed names.
const DISTRUSTED_SUBJECTS: &[&[u8]] = &[
    b"emSign ECC Root CA - G3",
    b"AAA Certificate Services",
];

fn is_distrusted(subject: &[u8]) -> bool {
    DISTRUSTED_SUBJECTS
        .iter()
        .any(|needle| subject.windows(needle.len()).any(|window| window == *needle))
}

pub(crate) fn root_store() -> Result<RootCertStore> {
    let mut roots = RootCertStore::empty();
    roots.extend(
        webpki_roots::TLS_SERVER_ROOTS
            .iter()
            .filter(|anchor| !is_distrusted(anchor.subject.as_ref()))
            .cloned(),
    );
    // SSL_CERT_FILE / SSL_CERT_DIR, when present, select the native input.
    // Match reqwest: tolerate unavailable/empty native stores and partial parse
    // failures, but fail when every returned native certificate is invalid DER.
    // Never include native loader errors (which may contain private paths).
    let native = rustls_native_certs::load_native_certs();
    // The native store can still carry a root the operator was told to
    // distrust (a stale trust setting, or a bundle named by SSL_CERT_FILE), so
    // the same names are dropped there too: the scan works on the DER because
    // the Name is embedded verbatim.
    let trusted: Vec<_> = native
        .certs
        .into_iter()
        .filter(|cert| !is_distrusted(cert.as_ref()))
        .collect();
    let (valid, invalid) = roots.add_parsable_certificates(trusted);
    if valid == 0 && invalid > 0 {
        return Err(Error::Transport(
            "zero valid certificates found in native root store".into(),
        ));
    }
    Ok(roots)
}

pub(crate) fn client_config() -> Result<ClientConfig> {
    Ok(
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .map_err(|e| Error::Transport(e.to_string()))?
            .with_root_certificates(root_store()?)
            .with_no_client_auth(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compromised_roots_are_not_bundled() {
        let bundled = webpki_roots::TLS_SERVER_ROOTS.len();
        let blocked = webpki_roots::TLS_SERVER_ROOTS
            .iter()
            .filter(|anchor| is_distrusted(anchor.subject.as_ref()))
            .count();
        assert!(blocked > 0, "the compromised roots must be present to filter");
        let filtered = webpki_roots::TLS_SERVER_ROOTS
            .iter()
            .filter(|anchor| !is_distrusted(anchor.subject.as_ref()))
            .count();
        assert_eq!(filtered, bundled - blocked);
        // The live store is bundled plus the native roots, so check the names
        // rather than the count: no distrusted subject may survive in it.
        let store = root_store().expect("the store loads");
        for anchor in store.roots.iter() {
            assert!(
                !is_distrusted(anchor.subject.as_ref()),
                "a distrusted root survived in the store: {}",
                String::from_utf8_lossy(anchor.subject.as_ref())
                    .chars()
                    .filter(|c| c.is_ascii_graphic() || *c == ' ')
                    .collect::<String>()
            );
        }
        assert!(store.roots.len() >= filtered);
    }

    #[test]
    fn unrelated_roots_keep_their_place() {
        let kept = root_store().expect("the bundled roots load");
        let has_isrg = webpki_roots::TLS_SERVER_ROOTS.iter().any(|anchor| {
            anchor.subject.as_ref().windows(b"ISRG Root X1".len()).any(|w| w == b"ISRG Root X1")
                && !is_distrusted(anchor.subject.as_ref())
        });
        assert!(has_isrg, "the bundled list still carries a well-known root");
        assert!(kept.roots.len() > 100);
    }

    #[test]
    fn empty_native_source_retains_bundled_roots() {
        const CHILD: &str = "CUA_TEST_BUNDLED_ROOTS_CHILD";
        if std::env::var_os(CHILD).is_some() {
            let roots = super::root_store().unwrap();
            let expected: Vec<_> = webpki_roots::TLS_SERVER_ROOTS
                .iter()
                .filter(|anchor| !super::is_distrusted(anchor.subject.as_ref()))
                .cloned()
                .collect();
            assert_eq!(roots.roots, expected);
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let empty = dir.path().join("empty.pem");
        std::fs::write(&empty, "").unwrap();
        for path in [empty, dir.path().join("missing.pem")] {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "tls::tests::empty_native_source_retains_bundled_roots",
                ])
                .env(CHILD, "1")
                .env("SSL_CERT_FILE", path)
                .env_remove("SSL_CERT_DIR")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
}
