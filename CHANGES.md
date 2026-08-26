# Changes

## 0.1.0

- Initial standalone OPAM package: `obs-eio` Prometheus backend, text exposition
  renderer, and Pushgateway client.
- **Fixed (post-tag, found by independent review of the sibling `aws-eio` package's
  identical copy of this code):** the HTTPS wrapper (`Obs_prometheus_tls`) never
  seeded `Mirage_crypto_rng`, so every real TLS handshake failed with "The default
  generator is not yet initialized" — invisible to every test here since none of
  them exercised real TLS. Fixed with a domain-safe (`Atomic`+`Mutex`) cached seed,
  not a bare `Stdlib.Lazy.t` (documented unsafe across OCaml 5 domains).
- **Extracted (post-tag): `Obs_prometheus_tls` moved out to the standalone
  `https-eio` package.** The same wrapper turned out to be duplicated
  byte-for-byte in aws-eio's `Aws_tls`, obs-loki-eio's `Obs_loki_tls`, and Sun's
  in-tree `Kafka_service_tls`. `Obs_prometheus_tls` is deleted; `obs_prometheus.ml`
  now depends on `https-eio` directly, which also replaces the hand-rolled
  CA-bundle path list with the maintained `ca-certs` package. The TLS regression
  tests moved to `https-eio`'s own test suite.
