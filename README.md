# obs-prometheus-eio

Prometheus backend for [`obs-eio`](https://github.com/loganbnielsen/obs-eio).
Accumulates counter/gauge/histogram deltas in-process and renders them as Prometheus
text exposition format on demand. Designed for long-running services that expose a
`/metrics` scrape endpoint, plus a Pushgateway client for short-lived jobs that
Prometheus cannot scrape directly.

Not a general-purpose Prometheus client and not a replacement for `prometheus` or
`prometheus-eio`: it is the Prometheus backend for `obs-eio`'s `Obs.backend` interface,
for services that already use `obs-eio` for tracing and logging.

Extracted from the [Sun](https://github.com/loganbnielsen/sun) platform, where it
continues to be used as an external dependency.

## Build

```bash
eval $(opam env)
dune build
```

## Test

```bash
# Unit tests (no infrastructure)
dune runtest

# Also run the live Pushgateway round-trip test
PUSHGATEWAY_URL=http://localhost:9091 PROMETHEUS_URL=http://localhost:9090 dune test --force
```

## Public API

```ocaml
val create : unit -> Obs.backend * (unit -> string)
(** [create ()] returns a backend and a renderer.
    Pass the backend to [Obs.create ~backend].
    Call the renderer to produce a Prometheus /metrics text body on demand.

    The backend is safe to use from multiple fibers and domains simultaneously. *)

val push
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
     (** Pushgateway base URL, e.g. "http://localhost:9091" *)
  -> job:string
     (** Pushgateway job label, e.g. "payments-worker" *)
  -> (unit -> string)
     (** The renderer returned by [create] *)
  -> (unit, string) result
(** Push the current metric snapshot to a Prometheus Pushgateway.
    Use for short-lived jobs (cron, batch) that Prometheus cannot scrape directly.
    Not recommended for long-running services — use the renderer + scrape endpoint instead. *)
```

## Metric Families

Each `register_*` call in `Obs` declares a metric family identified by `(name, label_names)`.
The Prometheus backend builds a registry keyed on `name` when the first event arrives.

| `Obs` call | Prometheus type | Accumulation |
|---|---|---|
| `register_counter` | `counter` | Adds delta to running total per `(name, labels)` |
| `register_gauge` | `gauge` | Replaces current value per `(name, labels)` |
| `register_histogram` | `histogram` | Sorts observation into pre-defined buckets |

Histogram buckets are always
`[0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0]` — there is currently no
per-metric override. `Obs.register_histogram` has no `~buckets` parameter; deleting it
was the honest choice over an option that looked configurable but was silently ignored.

## Rendered Output Format

Standard Prometheus text exposition format, one family per `register_*` call:

```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="POST",status="200"} 42
http_requests_total{method="GET",status="200"} 17

# HELP request_duration_seconds Request latency
# TYPE request_duration_seconds histogram
request_duration_seconds_bucket{le="0.005"} 3
request_duration_seconds_bucket{le="0.01"} 7
...
request_duration_seconds_bucket{le="+Inf"} 59
request_duration_seconds_sum 12.4
request_duration_seconds_count 59
```

## State Management

Use a standard `Mutex` (not `Eio.Mutex`) to protect the registry map. This is safe
across Eio domains and does not require a switch in scope. Lock is held only for the
duration of a hashtable read/write — contention is negligible.

```ocaml
type registry = {
  mutable families : (string, family) Hashtbl.t;
  mutex            : Mutex.t;
}
```

## Implementation Notes

- **Registry key:** `name` string. `label_names` and `help` are stored on first event;
  subsequent events only update the value map. A later event with a different `help`
  string for the same `name` is logged to stderr and ignored — the first `help` wins.
  A metric-kind conflict (e.g. a `counter` registered where a `gauge` already exists
  under that `name`) is logged and the conflicting event is dropped entirely.
- **HELP text:** backslash and newline are escaped in the rendered `# HELP` line
  (label values additionally escape `"`, since label values are quoted and HELP text
  is not).
- **Value key inside a family:** `labels` association list, sorted by key for stable
  lookup. Sort on write, not on every read.
- **Counter:** accumulate with `+= delta`. Never reset.
- **Gauge:** replace with latest value. Last write wins.
- **Histogram:** maintain per-bucket counts + `_sum` + `_count`. On each observation,
  increment every bucket where `le >= value`, plus `+Inf`, plus sum and count.
- **Renderer:** takes the mutex, snapshots all families, releases the mutex, formats text.
  Does not hold the lock while formatting.
- **`emit_span` handler:** ignored — spans go to a tracing/logging backend such as
  `obs-loki-eio`, not Prometheus. Set to `fun _ -> ()`.

## Example Usage

```ocaml
let (prom_backend, render) = Obs_prometheus.create () in
let ot = Obs.create ~service:"payments-worker"
           ~mono_clock:env#mono_clock ~backend:prom_backend in

let msgs_processed = Obs.register_counter ot
  ~name:"kafka_messages_processed_total"
  ~help:"Total Kafka messages processed"
  ~label_names:["topic"; "status"] in

let request_latency = Obs.register_histogram ot
  ~name:"request_duration_seconds"
  ~help:"Request latency"
  ~label_names:["route"] in

(* In your handler: *)
msgs_processed ~labels:[("topic", "payments"); ("status", "ok")] 1;
request_latency ~labels:[("route", "/charge")] 0.042;

(* Expose /metrics — wire render() into your HTTP handler: *)
let metrics_body = render () in
```

To expose both metrics and tracing/logging from one `Obs.t`, compose this backend with
`obs-loki-eio` (or any other `obs-eio` backend):

```ocaml
let backend = Obs.compose prom_backend loki_backend in
let ot = Obs.create ~service:"payments-worker" ~mono_clock:env#mono_clock ~backend in
```

## Local Development

A local Pushgateway (and Prometheus, to verify the push landed) is only needed for the
live round-trip test; unit tests need nothing running.

```bash
docker run -d --name pushgateway -p 9091:9091 prom/pushgateway
docker run -d --name prometheus -p 9090:9090 prom/prometheus
```

## Out of Scope (v1)

- `/metrics` HTTP server — the renderer returns a string; wiring it to an HTTP endpoint
  is the caller's responsibility
- Metric expiry / staleness — counters and gauges accumulate indefinitely
- OpenMetrics format (`application/openmetrics-text`) — standard text exposition only
- `emit_span` — spans go to a logging/tracing backend such as `obs-loki-eio`; this
  package receives only metric events
- Summary type — use histogram instead
