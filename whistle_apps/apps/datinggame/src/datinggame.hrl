-include_lib("whistle/include/wh_types.hrl").
-include_lib("whistle/include/wh_amqp.hrl").
-include_lib("whistle/include/wh_log.hrl").
-include_lib("whistle/include/wh_databases.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-record(dg_agent, {
          id = <<>> :: binary()
          ,call_id = <<>> :: binary()
          ,control_queue = <<>> :: binary()
          ,signed_in = wh_util:current_tstamp() :: integer()
          ,skills = wh_json:new() :: json_object()
         }).

-record(dg_customer, {
          call_id = <<>> :: binary()
         ,control_queue = <<>> :: binary()
         ,skills_needed = wh_json:new() :: json_object()
         ,record_call = true :: boolean()
         }).

-define(APP_NAME, <<"dating_game">>).
-define(APP_VERSION, <<"0.1.0">>).

-define(ANY_DIGIT, [
                     <<"1">>, <<"2">>, <<"3">>
                    ,<<"4">>, <<"5">>, <<"6">>
                    ,<<"7">>, <<"8">>, <<"9">>
                    ,<<"*">>, <<"0">>, <<"#">>
                   ]).
