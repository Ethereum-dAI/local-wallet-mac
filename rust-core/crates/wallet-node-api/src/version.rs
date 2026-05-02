pub const API_VERSION: u32 = 1;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_version_is_one() {
        assert_eq!(API_VERSION, 1);
    }

    #[test]
    fn generated_header_contains_version() {
        let header =
            std::fs::read_to_string(concat!(env!("OUT_DIR"), "/wallet_node_api_version.h"))
                .expect("header not found");
        assert!(
            header.contains("#define WALLET_NODE_API_VERSION 1"),
            "bad header: {header}"
        );
    }
}
