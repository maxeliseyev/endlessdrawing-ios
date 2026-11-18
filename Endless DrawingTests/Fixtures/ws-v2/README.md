# Shared WS v2 fixtures

Synthetic semantic corpus; no captured session secrets or real drawings. Canonical copy: backend `tests/fixtures/ws-v2/`. Frontend carries the same files and SHA-256 manifest. Both decoders read the outputs of both encoders; byte equality between different encoders is not required.

Regenerate TypeScript files with `node scripts/generate-wire-fixtures.mjs tests/fixtures/ws-v2` in frontend, then copy `.ts.msgpack` to the canonical directory. Regenerate Rust files explicitly with `UPDATE_WS_FIXTURES=1 cargo test --lib codec::tests::export_rust_fixtures -- --ignored` in backend, then copy `.rust.msgpack` to frontend. Update `sha256.json` in both copies together after reviewing semantic changes. Never regenerate fixtures automatically in ordinary tests.
