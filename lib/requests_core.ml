(** Money requests, payment links and bill splits between customers of one institution. *)

(** The checked identifier type behind every id below. *)
module Validated_id = Validated_id

(** A customer of the institution. *)
module Customer_id = Customer_id

(** A money request. *)
module Request_id = Request_id

(** A payment link, as its owner knows it. *)
module Link_id = Link_id

(** A bill split. *)
module Split_id = Split_id

(** Short normalised text: notes and titles. *)
module Note = Note

(** A customer with a display name. *)
module Party = Party

(** Lifetimes and limits. *)
module Policy = Policy

(** The states of a money request. *)
module Request_status = Request_status

(** The states of a payment link. *)
module Link_status = Link_status

(** Why an operation was refused. *)
module Refusal = Refusal

(** Notices for customers, as values. *)
module Notice = Notice
