Red/System [
	Title:   "Red interpreter"
	Author:  "Nenad Rakocevic"
	File: 	 %interpreter.reds
	Tabs:	 4
	Rights:  "Copyright (C) 2011-2015 Nenad Rakocevic. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
]

#define CHECK_INFIX [
	if all [
		next < end
		TYPE_OF(next) = TYPE_WORD
	][
		value: _context/get next
		if TYPE_OF(value) = TYPE_OP [
			either next = as red-word! pc [
				#if debug? = yes [if verbose > 0 [log "infix detected!"]]
				infix?: yes
			][
				if TYPE_OF(pc) = TYPE_WORD [
					left: _context/get as red-word! pc
				]
				unless all [
					TYPE_OF(pc) = TYPE_WORD
					any [
						TYPE_OF(left) = TYPE_ACTION
						TYPE_OF(left) = TYPE_NATIVE
						TYPE_OF(left) = TYPE_FUNCTION
					]
					literal-first-arg? as red-native! left	;-- a literal argument is expected
				][
					#if debug? = yes [if verbose > 0 [log "infix detected!"]]
					infix?: yes
				]
			]
			if infix? [
				if next + 1 = end [fire [TO_ERROR(script no-op-arg) next]]
			]
		]
	]
]

#define FETCH_ARGUMENT [
	if pc >= end [fire [TO_ERROR(script no-arg) fname value]]
	
	switch TYPE_OF(value) [
		TYPE_WORD [
			#if debug? = yes [if verbose > 0 [log "evaluating argument"]]
			pc: eval-expression pc end no yes
		]
		TYPE_GET_WORD [
			#if debug? = yes [if verbose > 0 [log "fetching argument as-is"]]
			stack/push pc
			pc: pc + 1
		]
		default [
			#if debug? = yes [if verbose > 0 [log "fetching argument"]]
			switch TYPE_OF(pc) [
				TYPE_GET_WORD [
					copy-cell _context/get as red-word! pc stack/push*
				]
				TYPE_PAREN [
					either TYPE_OF(value) = TYPE_LIT_WORD [
						stack/mark-interp-native as red-word! pc	;@@ ~paren
						eval as red-block! pc yes
						stack/unwind
					][
						stack/push pc
					]
				]
				TYPE_GET_PATH [
					eval-path pc pc + 1 end no yes yes no
				]
				default [
					stack/push pc
				]
			]
			pc: pc + 1
		]
	]
]

interpreter: context [
	verbose: 0
	
	log: func [msg [c-string!]][
		print "eval: "
		print-line msg
	]
	
	literal-first-arg?: func [
		native 	[red-native!]
		return: [logic!]
		/local
			fun	  [red-function!]
			value [red-value!]
			tail  [red-value!]
			s	  [series!]
	][
		s: as series! either TYPE_OF(native) = TYPE_FUNCTION [
			fun: as red-function! native
			fun/spec/value
		][
			native/spec/value
		]
		value: s/offset
		tail:  s/tail
		
		while [value < tail][
			switch TYPE_OF(value) [
				TYPE_WORD 		[return no]
				TYPE_LIT_WORD	[return yes]
				default 		[0]
			]
			value: value + 1
		]
		no
	]
	
	set-locals: func [
		fun [red-function!]
		/local
			tail  [red-value!]
			value [red-value!]
			s	  [series!]
			set?  [logic!]
	][
		s: as series! fun/spec/value
		value: s/offset
		tail:  s/tail
		set?:  no
		
		while [value < tail][
			switch TYPE_OF(value) [
				TYPE_WORD
				TYPE_GET_WORD
				TYPE_LIT_WORD [
					if set? [none/push]
				]
				TYPE_REFINEMENT [
					unless set? [set?: yes]
					logic/push false
				]
				default [0]								;-- ignore other values
			]
			value: value + 1
		]
	]
	
	eval-function: func [
		fun  [red-function!]
		body [red-block!]
		/local
			ctx	  [red-context!]
			saved [node!]
	][
		ctx: GET_CTX(fun)
		saved: ctx/values
		ctx/values: as node! stack/arguments
		stack/set-in-func-flag yes
		
		catch RED_THROWN_ERROR [eval body yes]
		
		stack/set-in-func-flag no
		ctx/values: saved
		switch system/thrown [
			RED_THROWN_ERROR	[throw RED_THROWN_ERROR] ;-- let exception pass through
			RED_THROWN_BREAK	[fire [TO_ERROR(throw break)]]
			RED_THROWN_CONTINUE	[fire [TO_ERROR(throw continue)]]
			RED_THROWN_THROW	[throw RED_THROWN_THROW] ;-- let exception pass through
			default [0]									 ;-- else, do nothing
		]
		system/thrown: 0
	]
	
	exec-routine: func [
		rt	 [red-routine!]
		/local
			native [red-native!]
			arg	   [red-value!]
			bool   [red-logic!]
			int	   [red-integer!]
			s	   [series!]
			ret	   [integer!]
			count  [integer!]
			call
	][
		s: as series! rt/more/value
		native: as red-native! s/offset + 2
		call: as function! [return: [integer!]] native/code
		count: (routine/get-arity rt) - 1				;-- zero-based stack access
		
		while [count >= 0][
			arg: stack/arguments + count
			switch TYPE_OF(arg) [
				TYPE_LOGIC	 [push logic/get arg]
				TYPE_INTEGER [push integer/get arg]
				default		 [push arg]
			]
			count: count - 1
		]
		either positive? rt/ret-type [
			ret: call
			switch rt/ret-type [
				TYPE_LOGIC	[
					bool: as red-logic! stack/arguments
					bool/header: TYPE_LOGIC
					bool/value: ret <> 0
				]
				TYPE_INTEGER [
					int: as red-integer! stack/arguments
					int/header: TYPE_INTEGER
					int/value: ret
				]
				default [assert false]					;-- should never happen
			]
		][
			call
		]
	]
	
	eval-infix: func [
		value 	  [red-value!]
		pc		  [red-value!]
		end		  [red-value!]
		sub?	  [logic!]
		return:   [red-value!]
		/local
			next	[red-word!]
			left	[red-value!]
			fun		[red-function!]
			blk		[red-block!]
			slot	[red-value!]
			arg		[red-value!]
			more	[red-value!]
			infix?	[logic!]
			op		[red-op!]
			s		[series!]
			type	[integer!]
			pos		[byte-ptr!]
			bits	[byte-ptr!]
			set?	[logic!]
			args	[node!]
			node	[node!]
			call-op
	][
		stack/keep
		pc: pc + 1										;-- skip operator
		pc: eval-expression pc end yes yes				;-- eval right operand
		op: as red-op! value
		fun: null
		
		either op/header and body-flag <> 0 [
			node: as node! op/code
			s: as series! node/value
			more: s/offset
			fun: as red-function! more + 3
			
			s: as series! fun/more/value
			blk: as red-block! s/offset + 1
			if TYPE_OF(blk) = TYPE_BLOCK [args: blk/node]
		][
			args: op/args
		]
		if null? args [
			args: _function/preprocess-spec as red-native! op

			either fun <> null [
				blk/header: TYPE_BLOCK
				blk/head:	0
				blk/node:	args
			][
				op/args: args
			]
		]
		
		s: as series! args/value
		slot: s/offset + 1
		bits: (as byte-ptr! slot) + 4
		arg:  stack/arguments
		type: TYPE_OF(arg)
		BS_TEST_BIT(bits type set?)
		unless set? [ERR_EXPECT_ARGUMENT(type 0)]
		
		slot: slot + 2
		bits: (as byte-ptr! slot) + 4
		arg:  arg + 1
		type: TYPE_OF(arg)
		BS_TEST_BIT(bits type set?)
		unless set? [ERR_EXPECT_ARGUMENT(type 1)]

		either fun <> null [
			either TYPE_OF(fun) = TYPE_ROUTINE [
				exec-routine as red-routine! fun
			][
				set-locals fun
				eval-function fun as red-block! more
			]
		][
			if op/header and flag-native-op <> 0 [push yes]	;-- type-checking for natives.
			call-op: as function! [] op/code
			call-op
			0											;-- @@ to make compiler happy!
		]
		
		#if debug? = yes [
			if verbose > 0 [
				value: stack/arguments
				print-line ["eval: op return type: " TYPE_OF(value)]
			]
		]
		infix?: no
		next: as red-word! pc
		CHECK_INFIX
		if infix? [pc: eval-infix value pc end sub?]
		pc
	]
	
	eval-arguments: func [
		native 	[red-native!]
		pc		[red-value!]
		end	  	[red-value!]
		path	[red-path!]
		ref-pos [red-value!]
		return: [red-value!]
		/local
			fun	  	  [red-function!]
			function? [logic!]
			routine?  [logic!]
			value	  [red-value!]
			tail	  [red-value!]
			expected  [red-value!]
			path-end  [red-value!]
			fname	  [red-word!]
			blk		  [red-block!]
			vec		  [red-vector!]
			bool	  [red-logic!]
			arg		  [red-value!]
			s		  [series!]
			required? [logic!]
			args	  [node!]
			p		  [int-ptr!]
			ref-array [int-ptr!]
			index	  [integer!]
			size	  [integer!]
			type	  [integer!]
			pos		  [byte-ptr!]
			bits 	  [byte-ptr!]
			set? 	  [logic!]
			call
	][
		routine?:  TYPE_OF(native) = TYPE_ROUTINE
		function?: any [routine? TYPE_OF(native) = TYPE_FUNCTION]
		fname:	   as red-word! pc - 1
		args:	   null

		either function? [
			fun: as red-function! native
			s: as series! fun/more/value
			blk: as red-block! s/offset + 1
			if TYPE_OF(blk) = TYPE_BLOCK [args: blk/node]
		][
			args: native/args
		]
		if null? args [
			args: _function/preprocess-spec native
			
			either function? [
				blk/header: TYPE_BLOCK
				blk/head:	0
				blk/node:	args
			][
				native/args: args
			]
		]
		
		unless null? path [
			path-end: block/rs-tail as red-block! path
			fname: as red-word! ref-pos
			
			if ref-pos + 1 < path-end [					;-- test if refinements are following the function
				either null? path/args [
					args: _function/preprocess-options native path ref-pos args fname function?
					path/args: args
				][
					args: path/args
				]
			]
		]
		
		s: as series! args/value
		value:	   s/offset
		tail:	   s/tail
		required?: yes
		index: 	   0
		
		while [value < tail][
			expected: value + 1
			
			if TYPE_OF(value) <> TYPE_SET_WORD [
				switch TYPE_OF(expected) [
					TYPE_TYPESET [
						either required? [
							bits: (as byte-ptr! expected) + 4
							BS_TEST_BIT(bits TYPE_UNSET set?)
							
							either all [
								set?					;-- if unset! is accepted
								pc >= end				;-- if no more values to fetch
								TYPE_OF(value) = TYPE_LIT_WORD ;-- and if spec argument is a lit-word!
							][
								unset/push				;-- then, supply an unset argument
							][
								FETCH_ARGUMENT
								arg:  stack/top - 1
								type: TYPE_OF(arg)
								BS_TEST_BIT(bits type set?)
								unless set? [ERR_EXPECT_ARGUMENT(type index)]
								index: index + 1
							]
						][
							none/push
						]
					]
					TYPE_LOGIC [
						stack/push expected
						bool: as red-logic! expected
						required?: bool/value
					]
					TYPE_VECTOR [
						vec: as red-vector! expected
						s: GET_BUFFER(vec)
						p: as int-ptr! s/offset
						size: (as-integer (as int-ptr! s/tail) - p) / 4
						ref-array: system/stack/top - size
						system/stack/top: ref-array		;-- reserve space on native stack for refs array
						copy-memory as byte-ptr! ref-array as byte-ptr! p size * 4
					]
					default [assert false]				;-- trap it, if stack corrupted 
				]
			]
			value: value + 2
		]
		
		unless function? [
			system/stack/top: ref-array					;-- reset native stack to our custom arguments frame
			if TYPE_OF(native) = TYPE_NATIVE [push no]	;-- avoid 2nd type-checking for natives.
			call: as function! [] native/code			;-- direct call for actions/natives
			call
		]
		pc
	]
	
	eval-path: func [
		value   [red-value!]							;-- path to evaluate
		pc		[red-value!]
		end		[red-value!]
		set?	[logic!]
		get?	[logic!]
		sub?	[logic!]
		case?	[logic!]
		return: [red-value!]
		/local 
			path	[red-path!]
			head	[red-value!]
			tail	[red-value!]
			item	[red-value!]
			parent	[red-value!]
			gparent	[red-value!]
			saved	[red-value!]
			arg		[red-value!]
	][
		#if debug? = yes [if verbose > 0 [print-line "eval: path"]]
		
		path:   as red-path! value
		head:   block/rs-head as red-block! path
		tail:   block/rs-tail as red-block! path
		if head = tail [fire [TO_ERROR(script empty-path)]]
		
		item:   head + 1
		saved:  stack/top
		
		if TYPE_OF(head) <> TYPE_WORD [fire [TO_ERROR(script word-first) path]]
		
		parent: _context/get as red-word! head
		
		switch TYPE_OF(parent) [
			TYPE_ACTION								;@@ replace with TYPE_ANY_FUNCTION
			TYPE_NATIVE
			TYPE_ROUTINE
			TYPE_FUNCTION [
				if set? [fire [TO_ERROR(script invalid-path-set) path]]
				if get? [fire [TO_ERROR(script invalid-path-get) path]]
				pc: eval-code parent pc end yes path item - 1 parent
				return pc
			]
			TYPE_UNSET [fire [TO_ERROR(script no-value)	head]]
			default	   [0]
		]
				
		while [item < tail][
			#if debug? = yes [if verbose > 0 [print-line ["eval: path parent: " TYPE_OF(parent)]]]
			
			value: either any [
				TYPE_OF(item) = TYPE_GET_WORD 
				all [
					parent = head
					TYPE_OF(item) = TYPE_WORD
					TYPE_OF(parent) <> TYPE_OBJECT
				]
			][
				_context/get as red-word! item
			][
				item
			]
			switch TYPE_OF(value) [
				TYPE_UNSET [fire [TO_ERROR(script no-value)	item]]
				TYPE_PAREN [
					stack/mark-interp-native words/_body ;@@ ~paren
					eval as red-block! value yes		;-- eval paren content
					stack/unwind
					value: stack/top - 1
				]
				default [0]								;-- compilation pass-thru
			]
			#if debug? = yes [if verbose > 0 [print-line ["eval: path item: " TYPE_OF(value)]]]
			
			gparent: parent								;-- save grand-parent reference
			arg: either all [set? item + 1 = tail][stack/arguments][null]
			parent: actions/eval-path parent value arg path case?
			
			unless get? [
				switch TYPE_OF(parent) [
					TYPE_ACTION							;@@ replace with TYPE_ANY_FUNCTION
					TYPE_NATIVE
					TYPE_ROUTINE
					TYPE_FUNCTION [
						pc: eval-code parent pc end yes path item gparent
						return pc
					]
					default [0]
				]
			]
			item: item + 1
		]
		if set? [object/path-parent/header: TYPE_NONE]	;-- disables owner checking

		stack/top: saved
		either sub? [stack/push parent][stack/set-last parent]
		pc
	]
	
	eval-code: func [
		value	[red-value!]
		pc		[red-value!]
		end		[red-value!]
		sub?	[logic!]
		path	[red-path!]
		slot 	[red-value!]
		parent	[red-value!]
		return: [red-value!]
		/local
			name [red-word!]
			obj  [red-object!]
			fun	 [red-function!]
			int	 [red-integer!]
			s	 [series!]
			ctx	 [node!]
	][
		name: as red-word! either null? slot [pc - 1][slot]
		if TYPE_OF(name) <> TYPE_WORD [name: words/_anon]
		
		switch TYPE_OF(value) [
			TYPE_ACTION 
			TYPE_NATIVE [
				#if debug? = yes [if verbose > 0 [log "pushing action/native frame"]]
				stack/mark-interp-native name
				pc: eval-arguments as red-native! value pc end path slot 	;-- fetch args and exec
				either sub? [stack/unwind][stack/unwind-last]
				#if debug? = yes [
					if verbose > 0 [
						value: stack/arguments
						print-line ["eval: action/native return type: " TYPE_OF(value)]
					]
				]
			]
			TYPE_ROUTINE [
				#if debug? = yes [if verbose > 0 [log "pushing routine frame"]]
				stack/mark-interp-native name
				pc: eval-arguments as red-native! value pc end path slot
				exec-routine as red-routine! value
				either sub? [stack/unwind][stack/unwind-last]
				#if debug? = yes [
					if verbose > 0 [
						value: stack/arguments
						print-line ["eval: routine return type: " TYPE_OF(value)]
					]
				]
			]
			TYPE_FUNCTION [
				#if debug? = yes [if verbose > 0 [log "pushing function frame"]]
				obj: as red-object! parent
				ctx: either all [
					parent <> null
					TYPE_OF(parent) = TYPE_OBJECT
				][
					obj/ctx
				][
					fun: as red-function! value
					s: as series! fun/more/value
					int: as red-integer! s/offset + 4
					either TYPE_OF(int) = TYPE_INTEGER [
						ctx: as node! int/value
					][
						name/ctx						;-- get a context from calling name
					]
				]
				stack/mark-interp-func name
				pc: eval-arguments as red-native! value pc end path slot
				_function/call as red-function! value ctx
				either sub? [stack/unwind][stack/unwind-last]
				#if debug? = yes [
					if verbose > 0 [
						value: stack/arguments
						print-line ["eval: function return type: " TYPE_OF(value)]
					]
				]
			]
		]
		pc
	]
	
	eval-expression: func [
		pc		  [red-value!]
		end	  	  [red-value!]
		prefix?	  [logic!]								;-- TRUE => don't check for infix
		sub?	  [logic!]
		return:   [red-value!]
		/local
			next   [red-word!]
			value  [red-value!]
			left   [red-value!]
			w	   [red-word!]
			op	   [red-value!]
			sym	   [integer!]
			infix? [logic!]
	][
		#if debug? = yes [if verbose > 0 [print-line ["eval: fetching value of type " TYPE_OF(pc)]]]
		
		infix?: no
		unless prefix? [
			next: as red-word! pc + 1
			CHECK_INFIX
			if infix? [
				stack/mark-interp-native as red-word! pc + 1
				sub?: yes								;-- force sub? for infix expressions
				op: value
			]
		]
		
		switch TYPE_OF(pc) [
			TYPE_PAREN [
				stack/mark-interp-native words/_body
				eval as red-block! pc yes
				either sub? [stack/unwind][stack/unwind-last]
				pc: pc + 1
			]
			TYPE_SET_WORD [
				stack/mark-interp-native as red-word! pc ;@@ ~set
				word/push as red-word! pc
				pc: pc + 1
				if pc >= end [fire [TO_ERROR(script need-value) pc - 1]]
				pc: eval-expression pc end no yes
				word/set
				either sub? [stack/unwind][stack/unwind-last]
				#if debug? = yes [
					if verbose > 0 [
						value: stack/arguments
						print-line ["eval: set-word return type: " TYPE_OF(value)]
					]
				]
			]
			TYPE_SET_PATH [
				value: pc
				pc: pc + 1
				if pc >= end [fire [TO_ERROR(script need-value) value]]
				pc: eval-expression pc end no yes		;-- yes: push value on top of stack
				pc: eval-path value pc end yes no sub? no
			]
			TYPE_GET_WORD [
				copy-cell _context/get as red-word! pc stack/push*
				pc: pc + 1
			]
			TYPE_LIT_WORD [
				either sub? [
					w: word/push as red-word! pc		;-- nested expression: push value
				][
					w: as red-word! stack/set-last pc	;-- root expression: return value
				]
				w/header: TYPE_WORD						;-- coerce it to a word!
				pc: pc + 1
			]
			TYPE_WORD [
				#if debug? = yes [
					if verbose > 0 [
						print "eval: '"
						print-symbol as red-word! pc
						print lf
					]
				]
				value: _context/get as red-word! pc
				pc: pc + 1
				
				switch TYPE_OF(value) [
					TYPE_UNSET [
						fire [
							TO_ERROR(script no-value)
							pc - 1
						]
					]
					TYPE_LIT_WORD [
						word/push as red-word! value	;-- push lit-word! on stack
					]
					TYPE_ACTION							;@@ replace with TYPE_ANY_FUNCTION
					TYPE_NATIVE
					TYPE_ROUTINE
					TYPE_FUNCTION [
						pc: eval-code value pc end sub? null null value
					]
					TYPE_OP [
						fire [TO_ERROR(script no-op-arg) pc - 1]
					]
					default [
						#if debug? = yes [if verbose > 0 [log "getting word value"]]
						either sub? [
							stack/push value			;-- nested expression: push value
						][
							stack/set-last value		;-- root expression: return value
						]
						#if debug? = yes [
							if verbose > 0 [
								value: stack/arguments
								print-line ["eval: word return type: " TYPE_OF(value)]
							]
						]
					]
				]
			]
			TYPE_PATH [
				value: pc
				pc: pc + 1
				pc: eval-path value pc end no no sub? no
			]
			TYPE_GET_PATH [
				value: pc
				pc: pc + 1
				pc: eval-path value pc end no yes sub? no
			]
			TYPE_LIT_PATH [
				value: stack/push pc
				value/header: TYPE_PATH
				pc: pc + 1
			]
			TYPE_OP [
				--NOT_IMPLEMENTED--						;-- op used in prefix mode
			]
			TYPE_ACTION							;@@ replace with TYPE_ANY_FUNCTION
			TYPE_NATIVE
			TYPE_ROUTINE
			TYPE_FUNCTION [
				value: pc + 1
				if value >= end [value: end]
				pc: eval-code pc value end sub? null null null
			]
			default [
				either sub? [
					stack/push pc						;-- nested expression: push value
				][
					stack/set-last pc					;-- root expression: return value
				]
				pc: pc + 1
			]
		]
		
		if infix? [
			pc: eval-infix op pc end sub?
			unless prefix? [
				either sub? [stack/unwind][stack/unwind-last]
			]
		]
		pc
	]

	eval-next: func [
		value	[red-value!]
		tail	[red-value!]
		sub?	[logic!]
		return: [red-value!]							;-- return start of next expression
	][
		stack/mark-interp-native words/_body			;-- outer stack frame
		value: eval-expression value tail no sub?
		either sub? [stack/unwind][stack/unwind-last]
		value
	]
	
	eval: func [
		code   [red-block!]
		chain? [logic!]									;-- chain it with previous stack frame
		/local
			value [red-value!]
			tail  [red-value!]
			arg	  [red-value!]
	][
		value: block/rs-head code
		tail:  block/rs-tail code
		if value = tail [
			arg: stack/arguments
			arg/header: TYPE_UNSET
			exit
		]

		stack/mark-eval words/_body						;-- outer stack frame
		
		while [value < tail][
			#if debug? = yes [if verbose > 0 [log "root loop..."]]
			value: eval-expression value tail no no
			if value + 1 < tail [stack/reset]
		]
		either chain? [stack/unwind-last][stack/unwind]
	]
	
]