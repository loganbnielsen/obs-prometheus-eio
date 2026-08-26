type error =
  [ `No_system_ca_bundle
  | `Tls_config_error of string
  ]
(** TLS setup errors. HTTPS connections fail closed if no system CA bundle can be
    loaded; certificate verification is never silently disabled. *)

type https_wrapper =
  Uri.t ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r ->
  Tls_eio.t

val authenticator :
  ?ca_paths:string list -> unit -> (X509.Authenticator.t, error) result
(** Build an X.509 authenticator from the first readable CA bundle in [ca_paths],
    or standard system CA locations by default. *)

val make_https_wrapper : ?ca_paths:string list -> unit -> (https_wrapper, error) result
(** Build the [cohttp-eio] HTTPS wrapper used by the Pushgateway client. *)

val https_for_uri : Uri.t -> (https_wrapper option, error) result
(** Return [Some wrapper] for [https://] URIs, [None] otherwise. *)

val error_to_string : error -> string
(** Human-readable error text suitable for logs. *)
