pub mod cdp_identity;

pub mod crypto {
    pub mod cert;
    pub mod hash {
        use sha2::{Digest, Sha256};
        pub fn sha256(bytes: &[u8]) -> Vec<u8> { Sha256::digest(bytes).to_vec() }
    }
}
