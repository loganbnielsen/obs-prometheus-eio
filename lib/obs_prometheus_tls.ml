type error =
  [ `No_system_ca_bundle
  | `Tls_config_error of string
  ]

type https_wrapper =
  Uri.t ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r ->
  Tls_eio.t

let system_ca_bundle_paths =
  [ "/etc/ssl/certs/ca-certificates.crt"   (* Debian/Ubuntu/WSL *)
  ; "/etc/pki/tls/certs/ca-bundle.crt"     (* RHEL/CentOS/Fedora *)
  ; "/etc/ssl/ca-bundle.pem"               (* OpenSUSE *)
  ; "/etc/ssl/cert.pem"                    (* macOS/Alpine *)
  ]

let read_file path =
  try Some (In_channel.with_open_text path In_channel.input_all)
  with _ -> None

let load_certificates ca_paths =
  ca_paths
  |> List.find_map (fun path ->
       match read_file path with
       | None -> None
       | Some pem ->
         match X509.Certificate.decode_pem_multiple pem with
         | Ok certs when certs <> [] -> Some certs
         | _ -> None)
  |> function
  | Some certs -> Ok certs
  | None -> Error `No_system_ca_bundle

let authenticator ?(ca_paths = system_ca_bundle_paths) () =
  let time () = Ptime.of_float_s (Unix.gettimeofday ()) in
  match load_certificates ca_paths with
  | Ok certs -> Ok (X509.Authenticator.chain_of_trust ~time certs)
  | Error _ as error -> error

let make_https_wrapper ?ca_paths () : (https_wrapper, error) result =
  match authenticator ?ca_paths () with
  | Error _ as error -> error
  | Ok authenticator ->
    match Tls.Config.client ~authenticator () with
    | Error (`Msg msg) -> Error (`Tls_config_error msg)
    | Ok tls_config ->
      Ok
        (fun uri raw ->
          let host =
            Uri.host uri
            |> Option.map (fun h -> Domain_name.(host_exn (of_string_exn h)))
          in
          Tls_eio.client_of_flow ?host tls_config raw)

(* tls-eio's handshake needs Mirage_crypto_rng.default_generator seeded before
   it generates any key/nonce material — without this, every TLS handshake
   raises "The default generator is not yet initialized" at the point of
   first use. Ported from aws-eio's Aws_tls fix (round-4 finding there): the
   same unseeded-RNG bug exists here too, since every prior test in this repo
   used plain-HTTP local mock servers and never exercised a real handshake.
   Using the synchronous getentropy-based seed (Mirage_crypto_rng_unix.use_default),
   not the Eio-native continuously-reseeding mirage-crypto-rng-eio, to avoid
   requiring env/sw here — getentropy has no accumulator state to go stale, so a
   single blocking syscall at first-TLS-use is sufficient indefinitely.

   NOT a bare `lazy`: Stdlib.Lazy is documented as unsafe across domains —
   concurrent Lazy.force from different domains can raise
   CamlinternalLazy.Undefined for whichever domain loses the race (confirmed
   reproducible in aws-eio's sibling copy of this module). Double-checked
   locking below: the fast path is a lock-free Atomic.get; the mutex is only
   ever taken on the (at most once per domain-race) slow path. *)
let default_https_wrapper_cache : (https_wrapper, error) result option Atomic.t = Atomic.make None
let default_https_wrapper_mutex = Mutex.create ()

let default_https_wrapper () =
  match Atomic.get default_https_wrapper_cache with
  | Some result -> result
  | None ->
    Mutex.lock default_https_wrapper_mutex;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock default_https_wrapper_mutex)
      (fun () ->
        match Atomic.get default_https_wrapper_cache with
        | Some result -> result (* another domain won the race while we waited for the lock *)
        | None ->
          Mirage_crypto_rng_unix.use_default ();
          let result = make_https_wrapper () in
          Atomic.set default_https_wrapper_cache (Some result);
          result)

let https_for_uri uri =
  match Uri.scheme uri with
  | Some scheme when String.lowercase_ascii scheme = "https" ->
    Result.map (fun https -> Some https) (default_https_wrapper ())
  | _ -> Ok None

let error_to_string = function
  | `No_system_ca_bundle ->
    "no system CA bundle found; refusing to connect without certificate verification"
  | `Tls_config_error msg ->
    "TLS config error: " ^ msg
