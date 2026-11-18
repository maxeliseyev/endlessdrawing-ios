# WS v3 manifest fixtures

Synthetic membership/fetch/fallback messages, no real secrets or drawings. Canonical copy is backend tests/fixtures/ws-v3, frontend copy uses the same SHA-256 manifest. Regenerate TS with node scripts/generate-wire-fixtures.mjs tests/fixtures/ws-v3 in frontend. Regenerate Rust with UPDATE_WS_FIXTURES=1 WS_FIXTURES_VERSION=ws-v3 cargo test --lib codec::tests::export_rust_fixtures -- --ignored in backend. Copy both encoder outputs and update hashes together after reviewing changes. Ordinary tests never regenerate fixtures.
