use rcgen::{
    CertificateParams, DnType, KeyPair, KeyUsagePurpose, PublicKeyData, PKCS_ECDSA_P256_SHA256,
};

pub struct CdpIdentity {
    pub certificate_der: Vec<u8>,
    pub private_key_der: Vec<u8>,
    pub public_key_der: Vec<u8>,
}

/// Generate a local MS-CDP identity. The caller persists it in its own sandbox.
pub fn generate() -> anyhow::Result<CdpIdentity> {
    let key_pair = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)?;
    let mut params = CertificateParams::default();
    params
        .distinguished_name
        .push(DnType::CommonName, "CLink Windows Nearby");
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyAgreement];
    let cert = params.self_signed(&key_pair)?;
    Ok(CdpIdentity {
        certificate_der: cert.der().to_vec(),
        private_key_der: key_pair.serialize_der(),
        public_key_der: key_pair.subject_public_key_info(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distinct_keys_match_their_certificates() {
        let one = generate().unwrap();
        let two = generate().unwrap();
        assert_ne!(one.public_key_der, two.public_key_der);
        assert!(one.certificate_der.windows(one.public_key_der.len())
            .any(|part| part == one.public_key_der));
        let imported = KeyPair::try_from(one.private_key_der.as_slice()).unwrap();
        assert_eq!(imported.subject_public_key_info(), one.public_key_der);
    }
}
