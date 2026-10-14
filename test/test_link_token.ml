open! Core
open Requests_core

let%expect_test "encoding matches RFC 4648 base64url without padding" =
  let bytes = String.init 32 ~f:(fun i -> Char.of_int_exn (i * 8)) in
  let t = Link_token.of_random_bytes bytes |> Or_error.ok_exn in
  print_endline (Link_token.to_string t);
  [%expect {| AAgQGCAoMDhASFBYYGhweICIkJigqLC4wMjQ2ODo8Pg |}];
  print_s [%sexp (Link_token.of_random_bytes "short" |> Result.is_ok : bool)];
  [%expect {| false |}]
;;

let%expect_test "parsing accepts only canonical 43-character tokens" =
  let check s = print_s [%sexp (Link_token.of_string s |> Result.is_ok : bool)] in
  check "AAgQGCAoMDhASFBYYGhweICIkJigqLC4wMjQ2ODo8Pg";
  check "AAgQGCAoMDhASFBYYGhweICIkJigqLC4wMjQ2ODo8Ph";
  check "AAgQGCAoMDhASFBYYGhweICIkJigqLC4wMjQ2ODo8P";
  check "AAgQGCAoMDhASFBYYGhweICIkJigqLC4wMjQ2ODo8+g";
  [%expect {|
    true
    false
    false
    false
    |}]
;;

let%test_unit "generated tokens round-trip and do not repeat" =
  let tokens = List.init 1000 ~f:(fun _ -> Link_token.generate ()) in
  List.iter tokens ~f:(fun t ->
    [%test_result: Link_token.t]
      ~expect:t
      (Link_token.of_string (Link_token.to_string t) |> Or_error.ok_exn));
  [%test_result: int]
    ~expect:1000
    (List.dedup_and_sort tokens ~compare:Link_token.compare |> List.length)
;;

let%test_unit "every 32-byte string encodes to a token that parses back" =
  Quickcheck.test
    (String.gen_with_length 32 Char.quickcheck_generator)
    ~sexp_of:String.sexp_of_t
    ~f:(fun bytes ->
      let t = Link_token.of_random_bytes bytes |> Or_error.ok_exn in
      [%test_result: int] ~expect:Link_token.length (String.length (Link_token.to_string t));
      [%test_result: Link_token.t]
        ~expect:t
        (Link_token.of_string (Link_token.to_string t) |> Or_error.ok_exn))
;;
