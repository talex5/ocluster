open Capnp_rpc_lwt
open Lwt.Infix

(* Setting this to true shows log output, which is useful if the tests hang.
   However, it also hides the Alcotest diff if it fails. *)
let verbose = false

let reporter =
  let report src level ~over k msgf =
    let k _ = over (); k () in
    let src = Logs.Src.name src in
    msgf @@ fun ?header ?tags:_ fmt ->
    Fmt.kpf k Fmt.stdout ("%a %a @[" ^^ fmt ^^ "@]@.")
      Fmt.(styled `Magenta string) (Printf.sprintf "%14s" src)
      Logs_fmt.pp_header (level, header)
  in
  { Logs.report = report }

let () =
  Fmt_tty.setup_std_outputs ();
  Logs.(set_level (Some Info));
  Logs.set_reporter reporter

let read_log job =
  let buffer = Buffer.create 1024 in
  let rec aux start =
    Api.Job.log job start >>= function
    | Error (`Capnp e) -> Fmt.failwith "Error tailing logs: %a" Capnp_rpc.Error.pp e
    | Ok ("", _) -> Lwt.return (Buffer.contents buffer)
    | Ok (data, next) ->
      Buffer.add_string buffer data;
      aux next
  in
  aux 0L

let submit service dockerfile =
  let job = Api.Submission.submit service ~dockerfile ~cache_hint:"1" in
  read_log job >>= fun log ->
  Api.Job.status job >|= function
  | Ok () -> log
  | Error (`Capnp _) -> Fmt.strf "%sFAILED@." log

(* Build on a single worker. *)
let simple _ () =
  let builder = Mock_builder.create () in
  let sched = Build_scheduler.create () in
  Capability.with_ref (Build_scheduler.submission_service sched) @@ fun submission_service ->
  Capability.with_ref (Build_scheduler.registration_service sched) @@ fun registry ->
  Mock_builder.run builder registry;
  let result = submit submission_service "example" in
  Mock_builder.set builder "example" (Unix.WEXITED 0);
  result >>= fun result ->
  Logs.app (fun f -> f "Result: %S" result);
  Alcotest.(check string) "Check job worked" "Building example\nJob succeeed\n" result;
  Lwt.return_unit

(* A failing build on a single worker. *)
let fails _ () =
  let builder = Mock_builder.create () in
  let sched = Build_scheduler.create () in
  Capability.with_ref (Build_scheduler.submission_service sched) @@ fun submission_service ->
  Capability.with_ref (Build_scheduler.registration_service sched) @@ fun registry ->
  Mock_builder.run builder registry;
  let result = submit submission_service "example2" in
  Mock_builder.set builder "example2" (Unix.WEXITED 1);
  result >>= fun result ->
  Logs.app (fun f -> f "Result: %S" result);
  Alcotest.(check string) "Check job worked" "Building example2\nDocker build exited with status 1\nFAILED\n" result;
  Lwt.return_unit

(* The job is submitted before any builders are registered. *)
let await_builder _ () =
  let builder = Mock_builder.create () in
  let sched = Build_scheduler.create () in
  Capability.with_ref (Build_scheduler.submission_service sched) @@ fun submission_service ->
  Capability.with_ref (Build_scheduler.registration_service sched) @@ fun registry ->
  let result = submit submission_service "example" in
  Mock_builder.run builder registry;
  Mock_builder.set builder "example" (Unix.WEXITED 0);
  result >>= fun result ->
  Logs.app (fun f -> f "Result: %S" result);
  Alcotest.(check string) "Check job worked" "Building example\nJob succeeed\n" result;
  Lwt.return_unit

(* A single builder can't do all the jobs and they queue up. *)
let builder_capacity _ () =
  let builder = Mock_builder.create () in
  let sched = Build_scheduler.create () in
  Capability.with_ref (Build_scheduler.submission_service sched) @@ fun submission_service ->
  Capability.with_ref (Build_scheduler.registration_service sched) @@ fun registry ->
  Mock_builder.run builder registry ~capacity:2;
  let r1 = submit submission_service "example1" in
  let r2 = submit submission_service "example2" in
  let r3 = submit submission_service "example3" in
  Lwt.pause () >>= fun () ->
  Mock_builder.set builder "example1" (Unix.WEXITED 0);
  Mock_builder.set builder "example2" (Unix.WEXITED 0);
  Mock_builder.set builder "example3" (Unix.WEXITED 0);
  r1 >>= fun result ->
  Alcotest.(check string) "Check job worked" "Building example1\nJob succeeed\n" result;
  r2 >>= fun result ->
  Alcotest.(check string) "Check job worked" "Building example2\nJob succeeed\n" result;
  r3 >>= fun result ->
  Alcotest.(check string) "Check job worked" "Building example3\nJob succeeed\n" result;
  Lwt.return_unit

(* Test our mock network. *)
let network _ () =
  Lwt_switch.with_switch (fun switch ->
      let builder = Mock_builder.create () in
      let sched = Build_scheduler.create () in
      Capability.with_ref (Build_scheduler.submission_service sched) @@ fun submission_service ->
      Capability.with_ref (Build_scheduler.registration_service sched) @@ fun registry ->
      Mock_builder.run_remote builder ~switch registry;
      let result = submit submission_service "example" in
      Mock_builder.set builder "example" (Unix.WEXITED 0);
      result >>= fun result ->
      Logs.app (fun f -> f "Result: %S" result);
      Alcotest.(check string) "Check job worked" "Building example\nJob succeeed\n" result;
      Lwt.return_unit
    ) >>= fun () ->
  Lwt.pause ()

(* The worker disconnects. *)
let worker_disconnects _ () =
  let switch = Lwt_switch.create () in
  let builder = Mock_builder.create () in
  let sched = Build_scheduler.create () in
  Capability.with_ref (Build_scheduler.submission_service sched) @@ fun submission_service ->
  Capability.with_ref (Build_scheduler.registration_service sched) @@ fun registry ->
  Mock_builder.run_remote builder ~switch registry;
  (* Run a job to ensure it's connected. *)
  let result = submit submission_service "example" in
  Mock_builder.set builder "example" (Unix.WEXITED 0);
  result >>= fun result ->
  Alcotest.(check string) "Check job worked" "Building example\nJob succeeed\n" result;
  (* Drop network *)
  Lwt_switch.turn_off switch >>= fun () ->
  Lwt.pause () >>= fun () ->
  (* Try again *)
  let result = submit submission_service "example" in
  (* Worker reconnects *)
  let switch = Lwt_switch.create () in
  Mock_builder.run_remote builder ~switch registry;
  Mock_builder.set builder "example" (Unix.WEXITED 0);
  result >>= fun result ->
  Alcotest.(check string) "Check job worked" "Building example\nJob succeeed\n" result;
  Lwt.return_unit

let () =
  Lwt_main.run @@ Alcotest_lwt.run ~verbose "build-scheduler" [
    "main", [
      Alcotest_lwt.test_case "simple" `Quick simple;
      Alcotest_lwt.test_case "fails" `Quick fails;
      Alcotest_lwt.test_case "await_builder" `Quick await_builder;
      Alcotest_lwt.test_case "builder_capacity" `Quick builder_capacity;
      Alcotest_lwt.test_case "network" `Quick network;
      Alcotest_lwt.test_case "worker_disconnects" `Quick worker_disconnects;
    ]
  ]
