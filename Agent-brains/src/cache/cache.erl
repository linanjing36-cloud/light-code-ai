-module(cache).
-include("cache.hrl").
-export([init_table_config/0]).

init_table_config()->
	% ets:new(?TBALE, [set,public,named_table,{keyPos, #sql_config.tab}]).
	ok.