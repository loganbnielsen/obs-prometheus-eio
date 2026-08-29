(** Prometheus backend for obs-eio.
    Accumulates counter/gauge/histogram deltas in-process and renders them as
    Prometheus text exposition format on demand.

    Typical use — long-running worker or service:
    {[
      let (prom_backend, render) = Obs_prometheus.create () in
      let ot = Obs_eio.create ~service:"payments-worker"
                 ~mono_clock:env#mono_clock ~backend:prom_backend in

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
    The backend is safe to call from multiple fibers and domains simultaneously. *)

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
  -> (unit, string) result
(** Push the current metric snapshot to a Prometheus Pushgateway.
    Returns [Ok ()] immediately if the renderer produces no output (no metrics emitted yet).
    Otherwise performs one synchronous HTTP PUT on the calling fiber, bounded by
    [timeout]. Returns [Error msg] for invalid timeout/URL, timeout, TLS setup
    failure, connection failure, or non-2xx HTTP response. [Eio.Cancel.Cancelled]
    is always re-raised, never converted to [Error]. For long-running services use
    the renderer + scrape endpoint instead. *)
