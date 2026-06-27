-module(prompt_templates_tests).

-include_lib("eunit/include/eunit.hrl").

core_non_empty_test() ->
    ?assert(byte_size(prompt_templates:core()) > 50).

phase_hint_first_turn_test() ->
    Hint = prompt_templates:phase_hint(first_turn),
    ?assertNotEqual(<<>>, Hint),
    ?assertNotEqual(nomatch, binary:match(Hint, util:u("首次"))).

phase_hint_thinking_empty_test() ->
    ?assertEqual(<<>>, prompt_templates:phase_hint(thinking)).

phase_hint_near_loop_limit_test() ->
    Hint = prompt_templates:phase_hint(near_loop_limit),
    ?assertNotEqual(<<>>, Hint),
    ?assertNotEqual(nomatch, binary:match(Hint, util:u("上限"))).
