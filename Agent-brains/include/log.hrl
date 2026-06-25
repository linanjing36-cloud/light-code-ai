-ifndef('__LOG_H__').
-define('__LOG_H__', true).

-ifdef(debug).
    -define(log(F, D), lager:info(F,D)).
    -define(log(F), lager:info(F)).
    -define(log_trace(F, D), lager:info(F,D)).
    -define(log_trace(F), lager:info(F)).
    -define(log_warning(F, D), lager:warning(F,D)).
    -define(log_warning(F), lager:warning(F)).
    -define(log_error(F, D), lager:error(F,D)).
    -define(log_error(F), lager:error(F)).
    -define(debug(F, D), lager:debug(F,D)).
    -define(debug(F), lager:debug(F)).
-else.
-define(IFDEBUG,false).
-ifdef(debug_log).
    -define(log(F, D), lager:info(F,D)).
    -define(log(F), lager:info(F)).
    -define(log_trace(F, D), lager:info(F,D)).
    -define(log_trace(F), lager:info(F)).
    -define(log_warning(F, D), lager:warning(F,D)).
    -define(log_warning(F), lager:warning(F)).
    -define(log_error(F, D), lager:error(F,D)).
    -define(log_error(F), lager:error(F)).
    -define(debug(F, D), lager:debug(F,D)).
    -define(debug(F), lager:debug(F)).
-else.
    -define(log(F, D), lager:info(F,D)).
    -define(log(F), lager:info(F)).
    -define(log_trace(F, D), lager:info(F,D)).
    -define(log_trace(F), lager:info(F)).
    -define(log_warning(F, D), lager:warning(F,D)).
    -define(log_warning(F), lager:warning(F)).
    -define(log_error(F, D), lager:error(F,D)).
    -define(log_error(F), lager:error(F)).
    -define(debug(F, D), ok).
    -define(debug(F), ok).
-endif.
-endif.

-endif. %% -ifndef('__LOG_H__').



%%-ifndef('__LOG_H__').
%%-define('__LOG_H__', true).
%%
%%-ifdef(debug).
%%-define(log(F, D), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log(F), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_trace(F, D), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log_trace(F), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_warning(F, D), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log_warning(F), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_error(F, D), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log_error(F), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_ue(Tag, KvList), syslog_svr:logs_local("[~s:~p] ~s", [atom_to_list(?MODULE), ?LINE, syslog_svr:log_ue_format_str(Tag, KvList)])).
%%-define(log_ue(Tag), syslog_svr:logs_local("[~s:~p] ~s", [atom_to_list(?MODULE), ?LINE, syslog_svr:log_ue_format_str(Tag, [])])).
%%-define(debug(F, D), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(debug(F), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-else.
%%-define(IFDEBUG,false).
%%-ifdef(debug_log).
%%-define(log(F, D), syslog_svr:log_info("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log(F), syslog_svr:log_info("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_trace(F, D), syslog_svr:log_trace("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log_trace(F), syslog_svr:log_trace("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_warning(F, D), syslog_svr:log_warning("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log_warning(F), syslog_svr:log_warning("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_error(F, D), syslog_svr:log_error("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log_error(F), syslog_svr:log_error("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_ue(Tag, KvList), syslog_svr:log_ue("[~s:~p] ~s", [atom_to_list(?MODULE), ?LINE, syslog_svr:log_ue_format_str(Tag, KvList)])).
%%-define(log_ue(Tag), syslog_svr:log_ue("[~s:~p] ~s", [atom_to_list(?MODULE), ?LINE, syslog_svr:log_ue_format_str(Tag, [])])).
%%-define(debug(F, D), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(debug(F), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-else.
%%-define(log(F, D), syslog_svr:log_info("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log(F), syslog_svr:log_info("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_trace(F, D), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log_trace(F), syslog_svr:logs_local("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_warning(F, D), syslog_svr:log_warning("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log_warning(F), syslog_svr:log_warning("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_error(F, D), syslog_svr:log_error("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE] ++ D)).
%%-define(log_error(F), syslog_svr:log_error("[~s:~p] " ++ F, [atom_to_list(?MODULE), ?LINE])).
%%-define(log_ue(Tag, KvList), syslog_svr:log_ue("[~s:~p] ~s", [atom_to_list(?MODULE), ?LINE, syslog_svr:log_ue_format_str(Tag, KvList)])).
%%-define(log_ue(Tag), syslog_svr:log_ue("[~s:~p] ~s", [atom_to_list(?MODULE), ?LINE, syslog_svr:log_ue_format_str(Tag, [])])).
%%-define(debug(_F, _D),  ok).
%%-define(debug(_F),  ok).
%%-endif.
%%-endif.
%%
%%-endif. %% -ifndef('__LOG_H__').