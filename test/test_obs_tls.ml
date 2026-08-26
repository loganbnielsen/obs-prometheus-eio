let test_tls_authenticator_fails_closed_without_ca_bundle () =
  Alcotest.(check bool) "missing CA paths are rejected"
    true
    (match Obs_prometheus_tls.authenticator
             ~ca_paths:["/obs-prometheus-eio/does/not/exist/ca-certificates.crt"] () with
     | Error `No_system_ca_bundle -> true
     | _ -> false)

let test_tls_authenticator_ignores_invalid_ca_bundle () =
  let path = Filename.temp_file "obs-prometheus-invalid-ca" ".pem" in
  Fun.protect
    (fun () ->
       let oc = open_out path in
       output_string oc "not a pem certificate";
       close_out oc;
       Alcotest.(check bool) "invalid CA file is rejected"
         true
         (match Obs_prometheus_tls.authenticator ~ca_paths:[path] () with
          | Error `No_system_ca_bundle -> true
          | _ -> false))
    ~finally:(fun () -> Sys.remove path)

let test_tls_wrapper_returns_typed_error_without_ca_bundle () =
  Alcotest.(check bool) "wrapper setup returns typed CA error"
    true
    (match Obs_prometheus_tls.make_https_wrapper
             ~ca_paths:["/obs-prometheus-eio/does/not/exist/ca-certificates.crt"] () with
     | Error `No_system_ca_bundle -> true
     | _ -> false)

(* Regression test ported from aws-eio's Aws_tls fix: tls-eio's handshake
   needs Mirage_crypto_rng.default_generator seeded before it generates any
   key/nonce material, or every TLS handshake raises "The default generator
   is not yet initialized" at first use. Invisible to the tests above
   because none of them perform a real handshake. This performs a REAL
   local TLS handshake (self-signed cert/key in tls_fixtures/, not trusted
   by the system CA bundle) through Obs_prometheus_tls.https_for_uri and
   expects it to fail on certificate trust, not on the unseeded-RNG error. *)

let contains_substring ~needle haystack =
  let nlen = String.length needle and hlen = String.length haystack in
  let rec go i = i + nlen <= hlen && (String.sub haystack i nlen = needle || go (i + 1)) in
  nlen = 0 || go 0

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let fixtures_dir = "tls_fixtures"

let test_https_handshake_fails_on_cert_not_on_rng () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let cert = Result.get_ok (X509.Certificate.decode_pem (read_file (Filename.concat fixtures_dir "cert.pem"))) in
  let key = Result.get_ok (X509.Private_key.decode_pem (read_file (Filename.concat fixtures_dir "key.pem"))) in
  let server_config = Result.get_ok (Tls.Config.server ~certificates:(`Single ([ cert ], key)) ()) in
  let socket = Eio.Net.listen ~backlog:2 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with `Tcp (_, port) -> port | _ -> failwith "unexpected address family" in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Net.accept_fork ~sw socket
        ~on_error:(fun _ -> ())
        (fun conn _addr -> ( try ignore (Tls_eio.server_of_flow server_config conn) with _ -> ()));
      `Stop_daemon);
  let client_socket = Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  let dummy_uri = Uri.make ~scheme:"https" ~host:"localhost" () in
  match Obs_prometheus_tls.https_for_uri dummy_uri with
  | Error e -> Alcotest.fail ("expected an https wrapper, got: " ^ Obs_prometheus_tls.error_to_string e)
  | Ok None -> Alcotest.fail "expected Some wrapper for an https:// uri"
  | Ok (Some wrap) -> (
    let raw = (client_socket :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r) in
    match wrap dummy_uri raw with
    | (_ : Tls_eio.t) -> Alcotest.fail "expected the untrusted self-signed cert to be rejected"
    | exception exn ->
      let msg = Printexc.to_string exn in
      Alcotest.(check bool)
        "handshake reached certificate validation, not the unseeded-RNG error" true
        (not (contains_substring ~needle:"not yet initialized" msg)))

(* Regression test ported from aws-eio's fix for a second blocker: a bare
   `Stdlib.Lazy.t` is not domain-safe (Lazy.mli documents concurrent
   Lazy.force from different domains as raising CamlinternalLazy.Undefined
   for the losing domain). Fixed with double-checked locking over an
   Atomic.t cache (see Obs_prometheus_tls.default_https_wrapper). This
   exercises that fixed path under real concurrent-domain contention against
   a cache forced cold immediately beforehand, so it's exercising the actual
   first-use race rather than the lock-free warm-cache fast path. *)
let test_concurrent_domains_never_see_lazy_undefined () =
  let domain_count = 8 in
  Atomic.set Obs_prometheus_tls.default_https_wrapper_cache None;
  let ready_count = Atomic.make 0 in
  let go = Atomic.make false in
  let domains =
    List.init domain_count (fun _ ->
        Domain.spawn (fun () ->
            Atomic.incr ready_count;
            while not (Atomic.get go) do
              Domain.cpu_relax ()
            done;
            let uri = Uri.make ~scheme:"https" ~host:"localhost" () in
            try
              ignore (Obs_prometheus_tls.https_for_uri uri : (Obs_prometheus_tls.https_wrapper option, Obs_prometheus_tls.error) result);
              Ok ()
            with exn -> Error (Printexc.to_string exn)))
  in
  while Atomic.get ready_count < domain_count do
    Domain.cpu_relax ()
  done;
  Atomic.set go true;
  let results = List.map Domain.join domains in
  List.iteri
    (fun i result ->
      match result with
      | Ok () -> ()
      | Error msg -> Alcotest.failf "domain %d: %s" i msg)
    results

let () =
  let open Alcotest in
  run "obs_tls" [
    "tls", [
      test_case "authenticator fails closed without CA bundle" `Quick
        test_tls_authenticator_fails_closed_without_ca_bundle;
      test_case "authenticator ignores invalid CA bundle" `Quick
        test_tls_authenticator_ignores_invalid_ca_bundle;
      test_case "wrapper returns typed error without CA bundle" `Quick
        test_tls_wrapper_returns_typed_error_without_ca_bundle;
      test_case "fails on certificate trust, not on an unseeded RNG" `Quick
        test_https_handshake_fails_on_cert_not_on_rng;
      test_case "concurrent domains never see Lazy.Undefined" `Quick
        test_concurrent_domains_never_see_lazy_undefined;
    ];
  ]
