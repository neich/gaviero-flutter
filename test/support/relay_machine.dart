/// Placeholder relay values for tests that inject their own connector or
/// directory fetcher and so never open a real TLS connection. Tests that do
/// (relay_test, pinned_tls_test) use the real CA in `fixtures/pinned_tls/`.
library;

const testTlsCa = 'test-ca';
const testRelayHost = 'gaviero.example.com';
const testRelaySecret = 'relay-secret';
