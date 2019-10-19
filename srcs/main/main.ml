open Android_inputmethodservice
open Android_view

external _hack : unit -> unit = "Java_juloo_javacaml_Caml_startup"

(** Key value to string *)
let render_key =
	let open Key in
	let render_event =
		function
		| Escape		-> "Esc"
		| Tab			-> "\xE2\x87\xA5"
		| Backspace		-> "\xE2\x8C\xAB"
		| Delete		-> "\xE2\x8C\xA6"
		| Enter			-> "\xE2\x8F\x8E"
		| Left			-> "\xE2\x86\x90"
		| Right			-> "\xE2\x86\x92"
		| Up			-> "\xE2\x86\x91"
		| Down			-> "\xE2\x86\x93"
		| Page_up		-> "\xE2\x87\x9E"
		| Page_down		-> "\xE2\x87\x9F"
		| Home			-> "\xE2\x86\x96"
		| End			-> "\xE2\x86\x98"
	and render_modifier =
		function
		| Shift				-> "\xE2\x87\xA7"
		| Ctrl				-> "ctrl"
		| Alt				-> "alt"
		| Accent Acute		-> "\xCC\x81"
		| Accent Grave		-> "\xCC\x80"
		| Accent Circumflex	-> "\xCC\x82"
		| Accent Tilde		-> "\xCC\x83"
		| Accent Cedilla	-> "\xCC\xA7"
		| Accent Trema		-> "\xCC\x88"
	in
	function
	| Typing (Char (c, _))		->
		(* TODO: OCaml and Java are useless at unicode *)
		Java.to_string (Utils.java_string_of_code_point c)
	| Typing (Event (ev, _))	-> render_event ev
	| Modifier m				-> render_modifier m
	| Nothing					-> ""
	| Change_pad Default		-> "ABC"
	| Change_pad Numeric		-> "123"

type t = {
	touch_state		: Touch_event.state;
	layout			: Key.t KeyboardLayout.t;
	modifiers		: Modifiers.t;
	ims				: Input_method_service.t;
	view			: View.t;
  key_repeat : Key_repeat.t;
	dp				: float -> float;
}

let task t = Keyboard_service.Task t

let view_invalidate view =
	task (fun () -> View.invalidate view; Lwt.return (fun t -> t, []))

let send tv =
	let send t =
		begin match tv with
			| Key.Char (c, 0)	-> Keyboard_service.send_char t.ims c
			| Char (c, meta)	-> Keyboard_service.send_char_meta t.ims c meta
			| Event (ev, meta)	-> Keyboard_service.send_event t.ims ev meta
		end;
		t, []
	in
	task (fun () -> Lwt.return send)

let create ~ims ~view ~dp () = {
	touch_state = Touch_event.empty_state;
	layout = Layouts.qwerty;
	modifiers = Modifiers.empty;
	key_repeat = Key_repeat.empty;
	ims; view; dp
}

let rec handle_key_repeat_timeout t =
  let key_repeat, repeats, timeout =
    Key_repeat.on_timeout t.key_repeat
  in
  { t with key_repeat }, List.map send repeats @ key_repeat_timeout timeout

and key_repeat_timeout = function
  | Some t ->
      let task () =
        Keyboard_service.timeout (Int64.of_int t)
        |> Lwt.map (fun () -> handle_key_repeat_timeout)
      in
      [ Keyboard_service.Task task ]
  | None -> []

let handle_down t = function
	| Key.Modifier m	->
		{ t with modifiers = Modifiers.on_down m t.modifiers }, []
	| Typing tv			->
      let key_repeat, timeout = Key_repeat.on_down t.key_repeat tv in
      { t with key_repeat }, key_repeat_timeout timeout
	| Change_pad pad	->
		let layout = match pad with
			| Default	-> Layouts.qwerty
			| Numeric	-> Layouts.numeric
		in
		{ t with layout;
			modifiers = Modifiers.empty;
			touch_state = Touch_event.empty_state }, []
	| _					-> t, []

let handle_cancel t = function
	| Key.Modifier m	->
		{ t with modifiers = Modifiers.on_cancel m t.modifiers }, []
	| Typing kv			->
      let key_repeat = Key_repeat.on_up t.key_repeat kv in
      { t with key_repeat }, []
	| _					-> t, []

let handle_up t = function
	| Key.Typing tv			->
		let tv = Modifiers.apply tv t.modifiers
		and modifiers = Modifiers.on_key_press t.modifiers
    and key_repeat = Key_repeat.on_up t.key_repeat tv in
    { t with modifiers; key_repeat }, [ send tv ]
	| Modifier m			->
		{ t with modifiers = Modifiers.on_up m t.modifiers }, []
	| _						-> t, []

let update (`Touch_event ev) t =
	let invalidate = view_invalidate t.view in
	match Touch_event.on_touch t.view t.layout t.touch_state ev with
	| Key_down (key, ts)				->
		let t, tasks = handle_down t key.v in
		{ t with touch_state = ts }, invalidate :: tasks
	| Key_up (_, v, ts)				->
		let t, tasks = handle_up t v in
		{ t with touch_state = ts }, invalidate :: tasks
	| Pointer_changed (_, v', v, ts)	->
		let t, tasks = handle_cancel t v' in
		let t, tasks' = handle_down t v in
		{ t with touch_state = ts }, invalidate :: (tasks @ tasks')
	| Cancelled (_, v, ts)			->
		let t, tasks = handle_cancel t v in
		{ t with touch_state = ts }, invalidate :: tasks
	| Ignore							-> t, []

let draw t canvas =
	let is_activated key =
		match Touch_event.key_activated t.touch_state key with
		| exception Not_found	-> false
		| _						-> true
	and render_key k =
		let k = match k with
			| Key.Typing tv	-> Key.Typing (Modifiers.apply tv t.modifiers)
			| k				-> k
		in
		render_key k
	in
	Drawing.keyboard is_activated t.dp render_key t.layout canvas

let () =
	Printexc.record_backtrace true;
	Android_enable_logging.enable "UNEXPECTED KEYBOARD";
	let service = Keyboard_service.keyboard_service create update draw in
	UnexpectedKeyboardService.register service
