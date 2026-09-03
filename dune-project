(lang dune 3.0)
(name obs-prometheus-eio)
(version 0.1.0)
(generate_opam_files true)

(package
 (name obs-prometheus-eio)
 (synopsis "Prometheus text-exposition backend for obs-eio")
 (description "\
Accumulates counter/gauge/histogram deltas in-process and renders them as Prometheus
text exposition format on demand, plus an optional Pushgateway client for short-lived
jobs. Not a general-purpose Prometheus client and not a replacement for prometheus or
prometheus-eio: it is the Prometheus backend for obs-eio's Obs_eio.backend interface,
positioned for services that already use obs-eio for tracing and logging.")
 (maintainers "lbendtlynielsen@gmail.com")
 (authors "lbendtly")
 (license "MIT")
 (homepage "https://github.com/loganbnielsen/obs-prometheus-eio")
 (bug_reports "https://github.com/loganbnielsen/obs-prometheus-eio/issues")
 (source (github loganbnielsen/obs-prometheus-eio))
 (depends
  (ocaml (>= 5.4.0))
  (obs-eio (>= 0.1.0))
  (eio (>= 1.3))
  (eio_main (and (>= 1.3) :with-test))
  (cohttp-eio (>= 6.2.0))
  (uri (>= 4.4.0))
  (http (>= 6.0.0))
  (https-eio (>= 0.1.1))
  (alcotest :with-test)
  (odoc :with-doc)))
