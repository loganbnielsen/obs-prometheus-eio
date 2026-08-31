(** Prometheus backend for obs-eio.
    Accumulates counter/gauge/histogram deltas in-process and renders them as
    Prometheus text exposition format on demand.

    Typical use — long-running worker or service:
    {[
      let (prom_backend, render) = Obs_prometheus.create () in
      let ot = Obs_eio.create ~service:"payments-worker"
                 ~mono_clock:env#mono_clock ~backend:prom_backend () in

      let msgs = Obs_eio.register_counter ot
        ~name:"kafka_messages_processed_total"
        ~help:"Total Kafka messages processed"
        ~label_names:["topic"; "status"] in

      (* In handler: *)
      msgs ~labels:[("topic", "payments"); ("status", "ok")] 1;

      (* Expose /metrics — wire render() into your HTTP handler: *)
      let body = render () in
      ignore body
    ]} *)

val create : unit -> Obs_eio.backend * (unit -> string)
(** [create ()] returns a backend and a renderer.
    Pass the backend to [Obs_eio.create ~backend].
    Call the renderer to produce a Prometheus /metrics text body on demand.
    The backend is safe to call from multiple fibers and domains simultaneously.
    [emit_metric]/[declare_metric] raise [Invalid_argument] if a metric name is
    re-registered with a different kind, a different label-name set, or a
    request carries a duplicate label — each is a caller bug, not a runtime
    condition to silently drop. [Obs_eio] routes that exception to
    [on_backend_error] rather than letting it reach application code. A
    conflicting HELP string is not one of these: the first-registered text
    wins and later ones are ignored. *)

type push_error =
  | Invalid_config of string  (** Invalid [timeout] or [url], rejected before any I/O. *)
  | Tls_setup of string       (** TLS setup failed for an [https://] URL. *)
  | Timeout of float          (** The push did not complete within this many seconds. *)
  | Http_error of int         (** Pushgateway responded with this non-2xx status. *)
  | Network_error of string   (** Connection failure, or any other transport-level exception. *)

val push_error_to_string : push_error -> string

val push
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> ?timeout:float
     (** Request timeout in seconds. Must be positive. Default: [5.0]. *)
  -> ?headers:(string * string) list
     (** Extra HTTP headers, e.g. auth/proxy headers. *)
  -> url:string
     (** Pushgateway base URL, e.g. ["http://localhost:9091"]. Must be an
         [http://] or [https://] URL with a host. *)
  -> job:string
     (** Pushgateway job label, e.g. ["payments-worker"] *)
  -> (unit -> string)
     (** The renderer returned by [create] *)
  -> (unit, push_error) result
(** Push the current metric snapshot to a Prometheus Pushgateway.
    Returns [Ok ()] immediately if the renderer produces no output (no metrics emitted yet).
    Otherwise performs one synchronous HTTP PUT on the calling fiber, bounded by
    [timeout]. [Eio.Cancel.Cancelled] is always re-raised, never converted to
    [Error]. For long-running services use the renderer + scrape endpoint instead. *)
