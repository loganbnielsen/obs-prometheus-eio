let default_bounds =
  [| 0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0 |]

(* ------------------------------------------------------------------ *)
(* Internal state                                                      *)
(* ------------------------------------------------------------------ *)

type label_key = (string * string) list

let sort_labels labels =
  List.sort (fun (a, _) (b, _) -> String.compare a b) labels

type counter_state = { mutable c_value : float }
type gauge_state   = { mutable g_value : float }

type histogram_state = {
  h_bounds : float array;
  mutable h_counts : int array;   (* length = Array.length h_bounds + 1; last slot = +Inf *)
  mutable h_sum    : float;
  mutable h_count  : int;
}

type family =
  | FCounter of {
      f_help   : string;
      f_labels : string list;
      f_series : (label_key, counter_state) Hashtbl.t;
    }
  | FGauge of {
      f_help   : string;
      f_labels : string list;
      f_series : (label_key, gauge_state) Hashtbl.t;
    }
  | FHistogram of {
      f_help   : string;
      f_labels : string list;
      f_bounds : float array;
      f_series : (label_key, histogram_state) Hashtbl.t;
    }

let string_of_metric_kind = function
  | `Counter -> "counter"
  | `Gauge -> "gauge"
  | `Histogram -> "histogram"

let family_kind = function
  | FCounter _ -> `Counter
  | FGauge _ -> `Gauge
  | FHistogram _ -> `Histogram

(* A metric-shape conflict (kind, label schema, duplicate label) is a
   programmer error at the emit/declare call site — the same class of
   mistake obs-eio itself rejects with Invalid_argument at registration
   time. Raising here (rather than logging-and-dropping) routes it through
   Obs_eio's on_backend_error handler instead of a stderr line nobody
   reads; ordinary application code calling with_span/register_* never
   sees the exception directly. *)
let kind_conflict_error ~name ~existing ~incoming =
  Invalid_argument
    (Printf.sprintf
       "obs-prometheus: metric family kind conflict for %s: existing %s, incoming %s"
       name (string_of_metric_kind existing) (string_of_metric_kind incoming))

(* First-registered help text wins the # HELP line; unlike a kind or label
   conflict this can't corrupt a family's shape, so it stays a warning. *)
let warn_on_help_mismatch ~name ~existing ~incoming =
  if existing <> incoming then
    Printf.eprintf
      "obs-prometheus: metric %s registered with conflicting help text \
       (keeping %S, ignoring %S)\n%!"
      name existing incoming

let label_names labels =
  List.sort String.compare (List.map fst labels)

let sort_label_names names =
  List.sort String.compare names

let duplicate_name names =
  let rec loop = function
    | a :: b :: _ when a = b -> Some a
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop names

let string_of_labels names =
  "[" ^ String.concat "; " (List.map (Printf.sprintf "%S") names) ^ "]"

let label_conflict_error ~name ~expected ~incoming =
  Invalid_argument
    (Printf.sprintf
       "obs-prometheus: metric %s label schema conflict: existing %s, incoming %s"
       name (string_of_labels expected) (string_of_labels incoming))

let check_no_duplicate_labels ~name labels =
  match duplicate_name labels with
  | Some label ->
    raise
      (Invalid_argument
         (Printf.sprintf "obs-prometheus: metric %s has duplicate label %S" name label))
  | None -> ()

let check_labels_match_family ~name ~expected ~incoming =
  check_no_duplicate_labels ~name incoming;
  if expected <> incoming then raise (label_conflict_error ~name ~expected ~incoming)

type registry = {
  r_families : (string, family) Hashtbl.t;
  r_mutex    : Mutex.t;
}

(* ------------------------------------------------------------------ *)
(* Accumulation                                                        *)
(* ------------------------------------------------------------------ *)

let get_or_create tbl key make =
  match Hashtbl.find_opt tbl key with
  | Some v -> v
  | None ->
    let v = make () in
    Hashtbl.add tbl key v;
    v

let emit reg (e : Obs_eio.metric_event) =
  let key = sort_labels e.labels in
  Mutex.lock reg.r_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock reg.r_mutex) (fun () ->
    match e.kind with
    | `Counter delta ->
      let labels = label_names e.labels in
      check_no_duplicate_labels ~name:e.name labels;
      let fam =
        get_or_create reg.r_families e.name (fun () ->
          FCounter { f_help = e.help; f_labels = labels; f_series = Hashtbl.create 4 })
      in
      (match fam with
       | FCounter { f_help; f_labels; f_series } ->
         warn_on_help_mismatch ~name:e.name ~existing:f_help ~incoming:e.help;
         check_labels_match_family ~name:e.name ~expected:f_labels ~incoming:labels;
         let s = get_or_create f_series key (fun () -> { c_value = 0.0 }) in
         s.c_value <- s.c_value +. float_of_int delta
       | other ->
         raise (kind_conflict_error ~name:e.name ~existing:(family_kind other) ~incoming:`Counter))
    | `Gauge v ->
      let labels = label_names e.labels in
      check_no_duplicate_labels ~name:e.name labels;
      let fam =
        get_or_create reg.r_families e.name (fun () ->
          FGauge { f_help = e.help; f_labels = labels; f_series = Hashtbl.create 4 })
      in
      (match fam with
       | FGauge { f_help; f_labels; f_series } ->
         warn_on_help_mismatch ~name:e.name ~existing:f_help ~incoming:e.help;
         check_labels_match_family ~name:e.name ~expected:f_labels ~incoming:labels;
         let s = get_or_create f_series key (fun () -> { g_value = 0.0 }) in
         s.g_value <- v
       | other ->
         raise (kind_conflict_error ~name:e.name ~existing:(family_kind other) ~incoming:`Gauge))
    | `Histogram obs ->
      let labels = label_names e.labels in
      check_no_duplicate_labels ~name:e.name labels;
      let fam =
        get_or_create reg.r_families e.name (fun () ->
          FHistogram {
            f_help   = e.help;
            f_labels = labels;
            f_bounds = default_bounds;
            f_series = Hashtbl.create 4;
          })
      in
      (match fam with
       | FHistogram { f_help; f_labels; f_bounds; f_series } ->
         warn_on_help_mismatch ~name:e.name ~existing:f_help ~incoming:e.help;
         check_labels_match_family ~name:e.name ~expected:f_labels ~incoming:labels;
         let n_bounds = Array.length f_bounds in
         let s =
           get_or_create f_series key (fun () -> {
             h_bounds = f_bounds;
             h_counts = Array.make (n_bounds + 1) 0;
             h_sum    = 0.0;
             h_count  = 0;
           })
         in
         (* Prometheus cumulative histogram: increment all buckets where le >= obs. *)
         Array.iteri (fun i le ->
           if obs <= le then s.h_counts.(i) <- s.h_counts.(i) + 1
         ) f_bounds;
         s.h_counts.(n_bounds) <- s.h_counts.(n_bounds) + 1;  (* +Inf always *)
         s.h_sum   <- s.h_sum +. obs;
         s.h_count <- s.h_count + 1
       | other ->
         raise (kind_conflict_error ~name:e.name ~existing:(family_kind other) ~incoming:`Histogram)))

(* Makes a metric visible at scrape time (zero-valued if unlabeled) before
   its first emit; a labeled metric has no label combination to pre-seed,
   so only the family is created. *)
let declare reg (d : Obs_eio.metric_declaration) =
  Mutex.lock reg.r_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock reg.r_mutex) (fun () ->
    let labels = sort_label_names d.declaration_label_names in
    match d.declaration_kind with
    | `Counter ->
      let fam =
        get_or_create reg.r_families d.declaration_name (fun () ->
          FCounter { f_help = d.declaration_help; f_labels = labels; f_series = Hashtbl.create 4 })
      in
      (match fam with
       | FCounter { f_help; f_labels; f_series } ->
         warn_on_help_mismatch ~name:d.declaration_name ~existing:f_help ~incoming:d.declaration_help;
         check_labels_match_family ~name:d.declaration_name ~expected:f_labels ~incoming:labels;
         if d.declaration_label_names = [] then
           ignore (get_or_create f_series [] (fun () -> { c_value = 0.0 }))
       | other ->
         raise (kind_conflict_error ~name:d.declaration_name ~existing:(family_kind other) ~incoming:`Counter))
    | `Gauge ->
      let fam =
        get_or_create reg.r_families d.declaration_name (fun () ->
          FGauge { f_help = d.declaration_help; f_labels = labels; f_series = Hashtbl.create 4 })
      in
      (match fam with
       | FGauge { f_help; f_labels; f_series } ->
         warn_on_help_mismatch ~name:d.declaration_name ~existing:f_help ~incoming:d.declaration_help;
         check_labels_match_family ~name:d.declaration_name ~expected:f_labels ~incoming:labels;
         if d.declaration_label_names = [] then
           ignore (get_or_create f_series [] (fun () -> { g_value = 0.0 }))
       | other ->
         raise (kind_conflict_error ~name:d.declaration_name ~existing:(family_kind other) ~incoming:`Gauge))
    | `Histogram ->
      let fam =
        get_or_create reg.r_families d.declaration_name (fun () ->
          FHistogram {
            f_help   = d.declaration_help;
            f_labels = labels;
            f_bounds = default_bounds;
            f_series = Hashtbl.create 4;
          })
      in
      (match fam with
       | FHistogram { f_help; f_labels; f_bounds; f_series } ->
         warn_on_help_mismatch ~name:d.declaration_name ~existing:f_help ~incoming:d.declaration_help;
         check_labels_match_family ~name:d.declaration_name ~expected:f_labels ~incoming:labels;
         if d.declaration_label_names = [] then
           ignore (get_or_create f_series [] (fun () -> {
             h_bounds = f_bounds;
             h_counts = Array.make (Array.length f_bounds + 1) 0;
             h_sum    = 0.0;
             h_count  = 0;
           }))
       | other ->
         raise (kind_conflict_error ~name:d.declaration_name ~existing:(family_kind other) ~incoming:`Histogram)))

(* ------------------------------------------------------------------ *)
(* Renderer                                                            *)
(* ------------------------------------------------------------------ *)

(* Snapshot types — immutable copies taken while the mutex is held. *)
type family_snap =
  | SCounter   of string * (label_key * float) list
  | SGauge     of string * (label_key * float) list
  | SHistogram of string * float array * (label_key * int array * float * int) list

let snapshot reg =
  Mutex.lock reg.r_mutex;
  let result =
    Hashtbl.fold (fun name fam acc ->
      let snap = match fam with
        | FCounter { f_help; f_series; _ } ->
          let series =
            Hashtbl.fold (fun k s acc -> (k, s.c_value) :: acc) f_series []
          in
          SCounter (f_help, series)
        | FGauge { f_help; f_series; _ } ->
          let series =
            Hashtbl.fold (fun k s acc -> (k, s.g_value) :: acc) f_series []
          in
          SGauge (f_help, series)
        | FHistogram { f_help; f_bounds; f_series; _ } ->
          let series =
            Hashtbl.fold (fun k s acc ->
              (k, Array.copy s.h_counts, s.h_sum, s.h_count) :: acc
            ) f_series []
          in
          SHistogram (f_help, f_bounds, series)
      in
      (name, snap) :: acc)
    reg.r_families []
  in
  Mutex.unlock reg.r_mutex;
  List.sort (fun (a, _) (b, _) -> String.compare a b) result

(* Prometheus text exposition: HELP text is not quoted, so only backslash
   and newline need escaping (no '"' — that escape is only for label values). *)
let escape_help_text s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | c    -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let escape_label_value s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"'  -> Buffer.add_string buf "\\\""
    | '\n' -> Buffer.add_string buf "\\n"
    | c    -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let render_labels labels =
  match labels with
  | [] -> ""
  | _  ->
    "{" ^
    String.concat ","
      (List.map (fun (k, v) -> k ^ "=\"" ^ escape_label_value v ^ "\"") labels)
    ^ "}"

let render_float f =
  if Float.is_nan f      then "NaN"
  else if f = infinity   then "+Inf"
  else if f = neg_infinity then "-Inf"
  else Printf.sprintf "%g" f

let render reg =
  let snaps = snapshot reg in
  if snaps = [] then ""
  else
    let buf = Buffer.create 1024 in
    List.iter (fun (name, snap) ->
      match snap with
      | SCounter (help, series) ->
        Buffer.add_string buf ("# HELP " ^ name ^ " " ^ escape_help_text help ^ "\n");
        Buffer.add_string buf ("# TYPE " ^ name ^ " counter\n");
        List.iter (fun (labels, v) ->
          Buffer.add_string buf
            (name ^ render_labels labels ^ " " ^ render_float v ^ "\n")
        ) series;
        Buffer.add_char buf '\n'
      | SGauge (help, series) ->
        Buffer.add_string buf ("# HELP " ^ name ^ " " ^ escape_help_text help ^ "\n");
        Buffer.add_string buf ("# TYPE " ^ name ^ " gauge\n");
        List.iter (fun (labels, v) ->
          Buffer.add_string buf
            (name ^ render_labels labels ^ " " ^ render_float v ^ "\n")
        ) series;
        Buffer.add_char buf '\n'
      | SHistogram (help, bounds, series) ->
        Buffer.add_string buf ("# HELP " ^ name ^ " " ^ escape_help_text help ^ "\n");
        Buffer.add_string buf ("# TYPE " ^ name ^ " histogram\n");
        List.iter (fun (labels, counts, sum, count) ->
          Array.iteri (fun i le ->
            let le_labels = labels @ [("le", render_float le)] in
            Buffer.add_string buf
              (name ^ "_bucket" ^ render_labels le_labels ^ " " ^
               string_of_int counts.(i) ^ "\n")
          ) bounds;
          let inf_labels = labels @ [("le", "+Inf")] in
          Buffer.add_string buf
            (name ^ "_bucket" ^ render_labels inf_labels ^ " " ^
             string_of_int count ^ "\n");
          Buffer.add_string buf
            (name ^ "_sum" ^ render_labels labels ^ " " ^ render_float sum ^ "\n");
          Buffer.add_string buf
            (name ^ "_count" ^ render_labels labels ^ " " ^ string_of_int count ^ "\n")
        ) series;
        Buffer.add_char buf '\n'
    ) snaps;
    Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* Pushgateway HTTP client                                            *)
(* ------------------------------------------------------------------ *)

type push_error =
  | Invalid_config of string
  | Tls_setup of string
  | Timeout of float
  | Http_error of int
  | Response_too_large of int
  | Network_error of string

let push_error_to_string = function
  | Invalid_config msg -> msg
  | Tls_setup msg -> "Pushgateway push: " ^ msg
  | Timeout t -> Printf.sprintf "Pushgateway push timed out after %gs" t
  | Http_error code -> Printf.sprintf "Pushgateway returned HTTP %d" code
  | Response_too_large max_bytes ->
    Printf.sprintf "Pushgateway response exceeded the %d-byte limit" max_bytes
  | Network_error msg -> "Pushgateway push: " ^ msg

let push ~net ~clock ?(timeout = 5.0) ?(headers = []) ~url ~job renderer =
  let body = renderer () in
  if body = "" then Ok ()
  else
    let encoded_job = Uri.pct_encode ~component:`Path job in
    let target = Uri.with_path (Uri.of_string url) ("/metrics/job/" ^ encoded_job) |> Uri.to_string in
    let headers = ("Content-Type", "text/plain; version=0.0.4; charset=utf-8") :: headers in
    match Https_eio.request ~net ~clock ~timeout ~meth:`PUT ~url:target ~headers ~body () with
    | Ok (code, _) when code >= 200 && code < 300 -> Ok ()
    | Ok (code, _) -> Error (Http_error code)
    | Error (Https_eio.Invalid_config msg) -> Error (Invalid_config msg)
    | Error (Https_eio.Tls_setup msg) -> Error (Tls_setup msg)
    | Error (Https_eio.Timeout t) -> Error (Timeout t)
    | Error (Https_eio.Response_too_large max_bytes) -> Error (Response_too_large max_bytes)
    | Error (Https_eio.Network_error msg) -> Error (Network_error msg)

(* ------------------------------------------------------------------ *)
(* Public API                                                          *)
(* ------------------------------------------------------------------ *)

let create () =
  let reg = { r_families = Hashtbl.create 8; r_mutex = Mutex.create () } in
  let backend = {
    Obs_eio.emit_span      = (fun _ -> ());
    Obs_eio.emit_metric    = emit reg;
    Obs_eio.declare_metric = declare reg;
  } in
  (backend, fun () -> render reg)
