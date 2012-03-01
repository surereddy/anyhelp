%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2012, James Aimonetti
%%% @doc
%%%
%%% Agent Callflow Data:
%%%   pin_retries :: integer()
%%%   min_digits :: integer()
%%%   max_digits :: integer()
%%%
%%% @end
%%% Created : 10 Jan 2012 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(cf_agent).

-export([handle/2]).

-include("../callflow.hrl").

-record(prompts, {
          pin_prompt = <<"/system_media/hotdesk-enter_pin">>
         ,invalid_pin_prompt = <<"/system_media/conf-bad_pin">>
         ,retries_exceeded_prompt = <<"/system_media/conf-to_many_attempts">>
         ,welcome_prompt = <<"/system_media/vm-setup_complete">>
         ,logged_in_prompt = <<"/system_media/hotdesk-logged_in">>
         }).

-spec handle/2 :: (wh_json:json_object(), whapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    whapps_call_command:answer(Call),
    case find_agent(Data, wh_json:get_integer_value(<<"pin_retries">>, Data, 3), Call) of
        {ok, AgentJObj} ->
            play_welcome(Call),
            put_on_hold(Call),
            publish_agent_available(AgentJObj, Call),
            cf_exe:transfer(Call);
        {error, _} ->
            cf_exe:continue(Call)
    end.

publish_agent_available(AgentJObj, Call) ->
    send_available(AgentJObj, Call).

send_available(AgentJObj, Call) ->
    Req = [{<<"Agent-ID">>, wh_json:get_value(<<"id">>, AgentJObj)}
           ,{<<"Skills">>, wh_json:get_value(<<"skills">>, AgentJObj, [])}
           ,{<<"Call-ID">>, cf_exe:callid(Call)}
           ,{<<"Control-Queue">>, cf_exe:control_queue(Call)}
           ,{<<"Account-DB">>, whapps_call:account_db(Call)}
           | wh_api:default_headers(<<>>, ?APP_NAME, ?APP_VERSION)],

    wapi_acd:publish_agent_online(Req).

put_on_hold(Call) ->
    whapps_call_command:hold(Call).

play_welcome(Call) ->
    #prompts{welcome_prompt=WelcomePrompt} = #prompts{},
    whapps_call_command:play(WelcomePrompt, Call).

prompt_and_get_pin(#prompts{pin_prompt=PinPrompt}, Data, Call) ->
    MinPinDigits = wh_json:get_integer_value(<<"min_digits">>, Data, 3),
    MaxPinDigits = wh_json:get_integer_value(<<"max_digits">>, Data, 5),

    whapps_call_command:b_play_and_collect_digits(MinPinDigits, MaxPinDigits, PinPrompt, Call).

find_agent(_Data, 0, Call) ->
    lager:debug("retries exceeded"),
    #prompts{retries_exceeded_prompt=RetriesPrompt} = #prompts{},
    whapps_call_command:play(RetriesPrompt, Call),
    {error, retries_exceeded};
find_agent(Data, Retries, Call) ->
    lager:debug("retries left: ~b", [Retries]),
    Prompts = #prompts{},
    case prompt_and_get_pin(Prompts, Data, Call) of
        {ok, Pin} -> % Pin = <<"315">>
            lager:debug("got ~s for pin", [Pin]),
            AccountDb = whapps_call:account_db(Call),
            ViewOptions = [{<<"include_docs">>, true}, {<<"key">>, Pin}],
            case couch_mgr:get_results(AccountDb, <<"agents/listing_by_pin">>, ViewOptions) of
                {ok, []} ->
                    lager:debug("no agent found with pin"),
                    #prompts{invalid_pin_prompt=InvalidPinPrompt}=Prompts,
                    whapps_call_command:b_play(InvalidPinPrompt, Call),
                    find_agent(Data, Retries-1, Call);
                {ok, [AgentJObj]} ->
                    lager:debug("agent found"),
                    {ok, AgentJObj};
                {error, _E} ->
                    lager:debug("error loading agent: ~p", [_E]),
                    #prompts{invalid_pin_prompt=InvalidPinPrompt}=Prompts,
                    whapps_call_command:b_play(InvalidPinPrompt, Call),
                    find_agent(Data, Retries-1, Call)
            end;
        {error, _E}=E ->
            lager:debug("error getting pin: ~p", [_E]),
            E
    end.