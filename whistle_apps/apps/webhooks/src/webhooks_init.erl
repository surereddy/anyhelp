%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Search all accounts for webhooks and start the appropriate handlers
%%% @end
%%% Created : 29 Nov 2011 by James Aimonetti <james22600hz.org>
%%%-------------------------------------------------------------------
-module(webhooks_init).

-export([start_link/0]).

-include("webhooks.hrl").

start_link() ->
    _ = [ spawn(fun() -> maybe_start_handler(Db) end) || Db <- whapps_util:get_all_accounts(encoded)],
    ignore.

maybe_start_handler(Db) ->
    case couch_mgr:get_results(Db, <<"webhooks/crossbar_listing">>, [{<<"include_docs">>, true}]) of
        {ok, []} -> lager:debug("No webhooks in ~s", [Db]), ignore;
        {ok, WebHooks} ->
            lager:debug("Starting webhooks listener(s) for ~s: ~b", [Db, length(WebHooks)]),
            [webhooks_listener_sup:start_listener(Db, wh_json:get_value(<<"doc">>, Hook)) || Hook <- WebHooks];
        {error, _E} ->
            lager:debug("Failed to load webhooks view for account ~s", [Db])
    end.
