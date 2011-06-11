%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, Karl Anderson
%%% @doc
%%%
%%% @end
%%% Created : 8 April 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cf_temporal_route).

-include("../callflow.hrl").

-export([handle/2, list/6]).

-import(calendar, [
                    day_of_the_week/1, day_of_the_week/3, gregorian_seconds_to_datetime/1
                   ,datetime_to_gregorian_seconds/1, date_to_gregorian_days/1, date_to_gregorian_days/3
                   ,last_day_of_the_month/2, gregorian_days_to_date/1, universal_time/0
                  ]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(handle/2 :: (Data :: json_object(), Call :: #cf_call{}) -> tuple(continue, binary())).
handle(_, #cf_call{cf_pid=CFPid, call_id=CallId}=Call) ->
    put(callid, CallId),
    CFPid ! find_temporal_routes(Call).

list(Type, Interval, Rule, Start, Current, Count) ->
    Fun = fun(Date) -> event_date(Type, Interval, Rule, Start, Date) end,
    timer:tc(fun do_list/4, [Current, Fun, Count, 0]).

do_list(_, _, Count, Count) ->
    ok;
do_list(Date, Fun, Count, Acc) ->
    Result = Fun(Date),
    io:format("~3w: ~-12w~n", [Acc, Result]),
    do_list(Result, Fun, Count, Acc + 1).


find_temporal_routes(#cf_call{account_db=Db}) ->
    case couch_mgr:get_all_results(Db, <<"temporal-route/listing_by_occurence">>) of
        {ok, JObj} ->
            logger:format_log(info, "FOUND: ~p", [JObj]),
            {continue, <<"match">>};
        _ ->
            {continue, <<"no_match">>}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% The big daddy 
%% Calculates the date of the next event given the type, interval, 
%% rule, start date, and current date.
%% @end
%%--------------------------------------------------------------------
event_date("date", _, _, Date0, _) ->
    Date0;
event_date(_, 0, _, Date0, _) ->
    Date0;
event_date("daily", I0, _, {Y0, M0, D0}, {Y1, M1, D1}) ->
    %% Calculate the distance in days as a function of
    %%   the interval and fix
    DS0 = date_to_gregorian_days({Y0, M0, D0}),
    DS1 = date_to_gregorian_days({Y1, M1, D1}),
    Offset = trunc( ( DS1 - DS0 ) / I0 ) * I0,
    normalize_date({Y0, M0, D0 + Offset + I0});

event_date("weekly", I0, Weekdays, {Y0, M0, D0}, {Y1, M1, D1}) ->
    DOW0 = day_of_the_week({Y1, M1, D1}),
    Distance = iso_week_difference({Y0, M0, D0}, {Y1, M1, D1}),
    Offset = trunc( Distance / I0 ) * I0,
    case [ DOW1 || DOW1 <- [to_dow(D) || D <- Weekdays], DOW1 > DOW0 ] of
        %% During an 'active' week but before the last weekday in the list
        %%   move to the next day this week
        [Day|_] when Distance =:= Offset ->
            normalize_date({Y1, M1, D1 + Day - DOW0}); 
        %% Empty list:
        %%   The last DOW during an 'active' week, 
        %% Non Empty List that failed the guard:
        %%   During an 'inactive' week
        _ ->
            {WY0, W0} = iso_week_number({Y0, M0, D0}),
            {Y2, M2, D2} = iso_week_to_gregorian_date({WY0, W0 + Offset + I0}),
            normalize_date({Y2, M2, ( D2 - 1 ) + to_dow( hd( Weekdays ) )})
    end;

event_date("monthly", I0, {every, Weekday}, {Y0, M0, _}, {Y1, M1, D1}) ->
    Distance = ( Y1 - Y0 ) * 12 - M0 + M1,
    Offset = trunc( Distance / I0 ) * I0,
    case Distance =:= Offset andalso find_next_weekday({Y1, M1, D1}, Weekday) of
        %% If the next occurence of the weekday is during an 'active' month
        %%   and does not span the current month/year then it is correct
        {Y1, M1, _}=Date ->
            Date;
        %% In the special case were the next weekday does span the current
        %%   month/year but it should be every month (I0 == 1) then the
        %%   date is also correct
        Date when I0 =:= 1 ->
            Date;
        %% During an 'inactive' month, or when it inappropriately spans
        %%   a month/year boundary calculate the next iteration
        _ ->
            find_ordinal_weekday(Y0, M0 + Offset + I0, Weekday, first)
    end;

event_date("monthly", I0, {last, Weekday}, {Y0, M0, _}, {Y1, M1, D1}) ->
    Distance = ( Y1 - Y0 ) * 12 - M0 + M1,
    Offset = trunc( Distance / I0 ) * I0,
    case Distance =:= Offset andalso find_last_weekday({Y1, M1, 1}, Weekday) of
        %% If today is before the occurace day on an 'active' month since
        %%   the 'last' only happens once per month if we havent passed it
        %%   then it must be this month
        {_, _, D2}=Date when D1 < D2 -> 
            Date;
        %% In an 'inactive' month or when we have already passed
        %%   the last occurance of the DOW
        _ ->
            find_last_weekday({Y0, M0 + Offset + I0, 1}, Weekday)
    end;

%% WARNING: There is a known bug when requesting the fifth occurance
%%   of a weekday when I0 > 1 and the current month only has four instances
%%   of the given weekday, the calculation is incorrect.  I was told not 
%%   to worry about that now...
event_date("monthly", I0, {Ordinal, Weekday}, {Y0, M0, _}, {Y1, M1, D1}) ->
    Distance = ( Y1 - Y0 ) * 12 - M0 + M1,
    Offset = trunc( Distance / I0 ) * I0,
    case Distance =:= Offset andalso {find_ordinal_weekday(Y1, M1, Weekday, Ordinal), I0} of
        %% If today is before the occurance day on an 'active' month and
        %%   the occurance does not cross month/year boundaries then the 
        %%   calculated date is accurate
        {{_, M1, D2}=Date, _} when D1 < D2, I0 > 1 -> 
            Date;        
        {{_, M2, D2}=Date, 1} when D1 < D2; M1 < M2 -> 
            Date;
        %% In an 'inactive' month or when we have already passed
        %%   the last occurance of the DOW
        _ ->
            find_ordinal_weekday(Y0, M0 + Offset + I0, Weekday, Ordinal)
    end;

event_date("monthly", I0, Days, {Y0, M0, _}, {Y1, M1, D1}) ->
    Distance = ( Y1 - Y0 ) * 12 - M0 + M1,
    Offset = trunc( Distance / I0 ) * I0,
    case [D || D <- Days, D > D1] of
        %% The day hasn't happend on an 'active' month
        [Day|_] when Distance =:= Offset ->
            normalize_date({Y0, M0 + Offset, Day});
        %% Empty List:
        %%   All of the days in the list have already happened
        %% Non Empty List that failed the guard:
        %%   The day hasn't happend on an 'inactive' month
        _ -> 
            normalize_date({Y0, M0 + Offset + I0, hd( Days )})
    end;

%% WARNING: This function does not ensure the provided day actually
%%   exists in the month provided.  For temporal routes that isnt 
%%   an issue because we will 'pass' the invalid date and compute
%%   the next
event_date("yearly", I0, {Month, Day}, {Y0, _, _}, {Y1, M1, D1}) ->
    Distance = Y1 - Y0,
    Offset = trunc( Distance / I0 ) * I0,
    %% If it is currently an 'active' year before the requested
    %%   month or on the requested month but before the day
    %%   then just provide the occurance.  Otherwise work out 
    %%   the next occurance.
    case M1 =< Month andalso D1 < Day of
        %% It is before the requested month or
        %%   on the requested month but before the day
        %%   but only on an 'active' year
        true when Distance =:= Offset -> {Y1, Month, Day};
        %% The requested month or day in that month has 
        %%   been passed, furthermore, if the guard fails 
        %%   calculate for next iteration
        _ -> {Y0 + Offset + I0, Month, Day}
    end;

event_date("yearly", I0, {every, Weekday, Month}, {Y0, _, _}, {Y1, M1, D1}) ->
    Distance = Y1 - Y0,
    Offset = trunc( Distance / I0 ) * I0,
    case Distance =:= Offset andalso find_next_weekday({Y1, Month, D1}, Weekday) of
        %% During an 'active' year before the target month the calculated
        %%   occurance is accurate
        {Y1, Month, _}=Date when M1 < Month ->
            Date;
        %% During an 'active' year on the target month before the
        %%   calculated occurance day it is accurate
        {Y1, Month, D2}=Date when M1 =:= Month, D1 < D2 ->
            Date;
        %% During an 'inactive' year, or after the target month
        %%   calculate the next iteration
        _ ->
            find_ordinal_weekday(Y0 + Offset + I0, Month, Weekday, first)
    end;

event_date("yearly", I0, {last, Weekday, Month}, {Y0, _, _}, {Y1, M1, D1}) ->
    Distance = Y1 - Y0,
    Offset = trunc( Distance / I0 ) * I0,
    case Distance =:= Offset andalso find_last_weekday({Y1, Month, 1}, Weekday) of
        %% During an 'active' year before the target month the calculated
        %%   occurance is accurate
        {Y1, _, _}=Date when M1 < Month ->
            Date;
        %% During an 'active' year on the target month before the
        %%   calculated occurance day it is accurate
        {Y1, _, D2}=Date when M1 =:= Month, D1 < D2 ->
            Date;
        %% During an 'inactive' year, or after the target month
        %%   calculate the next iteration
        _ ->
            find_last_weekday({Y0 + Offset + I0, Month, 1}, Weekday)
    end;

event_date("yearly", I0, {Ordinal, Weekday, Month}, {Y0, _, _}, {Y1, M1, D1}) ->
    Distance = Y1 - Y0,
    Offset = trunc( Distance / I0 ) * I0,
    case Distance =:= Offset andalso find_ordinal_weekday(Y1, Month, Weekday, Ordinal) of 
        %% During an 'active' year before the target month the calculated
        %%   occurance is accurate
        {Y1, Month, _}=Date when M1 < Month ->
            Date;
        %% During an 'active' year on the target month before the
        %%   calculated occurance day it is accurate
        {Y1, Month, D2}=Date when M1 =:= Month, D1 < D2 ->
            Date;
        %% During an 'inactive' year or after the calculated
        %%   occurance determine the next iteration
        _ ->            
            find_ordinal_weekday(Y0 + Offset + I0, Month, Weekday, Ordinal)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalizes dates, for example corrects for months that are given
%% with more days then they have (ie: {2011, 1, 36} -> {2011, 2, 5}).
%% I have been refering to this as 'spanning a month/year border'
%% @end
%%--------------------------------------------------------------------
-spec(normalize_date/1 :: (Date :: date()) -> date()).
normalize_date({Y, M, D}) when M =:= 13 ->
    normalize_date({Y + 1, 1, D});
normalize_date({Y, M, D}) when M > 12 ->
    normalize_date({Y + 1, M - 12, D});
normalize_date({Y, M, D}=Date) ->
    case last_day_of_the_month(Y, M) of
        Days when D > Days ->
            normalize_date({Y, M + 1, D - Days});
        _ ->
            Date
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert the ordinal words to cardinal numbers representing
%% the position 
%% @end
%%--------------------------------------------------------------------
from_ordinal(first) -> 0;
from_ordinal(second) -> 1;
from_ordinal(third) -> 2;
from_ordinal(fourth) -> 3;
from_ordinal(fifth) -> 4.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Map the days of the week to cardinal numbers representing the 
%% position, in accordance with ISO 8601
%% @end
%%--------------------------------------------------------------------
to_dow(monday) -> 1;
to_dow(tuesday) -> 2;
to_dow(wensday) -> 3;
to_dow(thursday) -> 4;
to_dow(friday) -> 5;
to_dow(saturday) -> 6;
to_dow(sunday) -> 7.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
find_next_weekday({Y, M, D}, Weekday) ->
    RefDOW = to_dow(Weekday),
    case calendar:day_of_the_week({Y, M, D}) of
        %% Today is the DOW we wanted, calculate for next week 
        RefDOW ->
            normalize_date({Y, M, D + 7});
        %% If the DOW has not occured this week yet
        DOW when RefDOW > DOW ->
            normalize_date({Y, M, D + (RefDOW - DOW)});            
        %% If the DOW occurance has already happend, calculate
        %%   for the next week using the current DOW as a reference
        DOW ->
            normalize_date({Y, M, D + ( 7 - DOW ) + RefDOW})
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Safety wrapper on date_of_dow used to loop over failing attempts
%% until the date can be calculated.
%% @end
%%--------------------------------------------------------------------
find_ordinal_weekday(Y1, M1, Weekday, Ordinal) when M1 =:= 13 ->
    find_ordinal_weekday(Y1 + 1, 1, Weekday, Ordinal);
find_ordinal_weekday(Y1, M1, Weekday, Ordinal) when M1 > 12 ->
    find_ordinal_weekday(Y1 + 1, M1 - 12, Weekday, Ordinal);
find_ordinal_weekday(Y1, M1, Weekday, Ordinal) ->
    try
        date_of_dow(Y1, M1, Weekday, Ordinal)
    catch
        _:_ ->
            find_ordinal_weekday(Y1, M1 + 1, Weekday, Ordinal)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
find_last_weekday({Y, M, D}, Weekday) when M =:= 13 ->
    find_last_weekday({Y + 1, 1, D}, Weekday);
find_last_weekday({Y, M, D}, Weekday) when M > 12 ->
    find_last_weekday({Y + 1, M - 12, D}, Weekday);
find_last_weekday({Y, M, _}, Weekday) ->
    %% Assumption/Principle:
    %%   A DOW can never occur more than four times in a month.
    %% ---------------------------------------------------------
    %% First attempt to calulate the date of the fouth DOW
    %% occurance.  Since the function corrects an invalid
    %% date by crossing month/year boundries, cause a badmatch
    %% if this happens. Therefore, during the exception the last
    %% occurance MUST be in the third week.
    try
        {Y, M, _} = date_of_dow(Y, M, Weekday, fifth)
    catch
        _:_ ->
            date_of_dow(Y, M, Weekday, fourth)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Unsafe calculation of the date for a specific day of the week, this
%% function will explode on occasion. 
%% @end
%%--------------------------------------------------------------------
-spec(date_of_dow/4 :: (Year :: non_neg_integer(), Month :: 2..13
                       ,Weekday :: 1..7, Ordinal :: 0..4) -> date()).
date_of_dow(Year, 1, Weekday, Ordinal) ->
    date_of_dow(Year - 1, 13, Weekday, Ordinal);
date_of_dow(Year, Month, Weekday, Ordinal) ->
    RefDate = {Year, Month - 1, last_day_of_the_month(Year, Month - 1)},
    RefDays = date_to_gregorian_days(RefDate),
    DOW = to_dow(Weekday),
    Occurance = from_ordinal(Ordinal),
    Days = case day_of_the_week(RefDate) of
               DOW ->
                   RefDays + 7 + (7 * Occurance );
               RefDOW when DOW < RefDOW ->
                   RefDays + DOW + (7 - RefDOW) + (7 * Occurance);
               RefDOW ->
                   RefDays + abs(DOW - RefDOW) + (7 * Occurance)
          end,
    {Y, M, D} = gregorian_days_to_date(Days),
    normalize_date({Y, M, D}).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Calculates the distance, in total ISO weeks, between two dates
%% @end
%%--------------------------------------------------------------------
-spec(iso_week_difference/2 :: (Week0 :: iso_week(), Week1 :: iso_week()) -> non_neg_integer()).
iso_week_difference({Y0, M0, D0}, {Y1, M1, D1}) ->
    %% I rather dislike this approach, but it is the best of MANY evils that I came up with...
    %% The idea here is to find the difference (in days) between the ISO 8601 mondays
    %% of the start and end dates.  This takes care of all the corner cases for us such as:
    %%    - Start date in ISO week of previous year
    %%    - End date in ISO week of previous year
    %%    - Spanning years
    %% All while remaining ISO 8601 compliant.
    DS0 = date_to_gregorian_days(iso_week_to_gregorian_date(iso_week_number({Y0, M0, D0}))),
    DS1 = date_to_gregorian_days(iso_week_to_gregorian_date(iso_week_number({Y1, M1, D1}))),
    trunc( abs( DS0 - DS1 ) / 7 ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Caclulates the gregorian date of a given ISO 8601 week
%% @end
%%--------------------------------------------------------------------
-spec(iso_week_to_gregorian_date/1 :: (Date :: iso_week()) -> date()).
iso_week_to_gregorian_date({Year, Week}) ->
    Jan1 = date_to_gregorian_days(Year, 1, 1),
    Offset = 4 - day_of_the_week(Year, 1, 4),
    Days =
        if
            Offset =:= 0 ->
                Jan1 + ( Week * 7 );
            true ->
                Jan1 + Offset + ( ( Week - 1 ) * 7 )
        end,
    gregorian_days_to_date(Days).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Wrapper for calender:iso_week_number introduced in R14B02 (?) using
%% a local copy on older systems
%% @end
%%--------------------------------------------------------------------
iso_week_number(Date) ->
    case erlang:function_exported(calendar, iso_week_number, 1) of
	true -> calendar:iso_week_number(Date);
	false -> our_iso_week_number(Date)
    end.

%% TAKEN FROM THE R14B02 SOURCE FOR calender.erl
our_iso_week_number({Year,_Month,_Day}=Date) ->
    D = calendar:date_to_gregorian_days(Date),
    W01_1_Year = gregorian_days_of_iso_w01_1(Year),
    W01_1_NextYear = gregorian_days_of_iso_w01_1(Year + 1),
    if W01_1_Year =< D andalso D < W01_1_NextYear ->
	    % Current Year Week 01..52(,53)
	    {Year, (D - W01_1_Year) div 7 + 1};
	D < W01_1_Year ->
	    % Previous Year 52 or 53
	    PWN = case calender:day_of_the_week(Year - 1, 1, 1) of
		4 -> 53;
		_ -> case calendar:day_of_the_week(Year - 1, 12, 31) of
			4 -> 53;
			_ -> 52
		     end
		end,
	    {Year - 1, PWN};
	W01_1_NextYear =< D ->
	    % Next Year, Week 01
	    {Year + 1, 1}
    end.

-spec gregorian_days_of_iso_w01_1(calendar:year()) -> non_neg_integer().
gregorian_days_of_iso_w01_1(Year) ->
    D0101 = calendar:date_to_gregorian_days(Year, 1, 1),
    DOW = calendar:day_of_the_week(Year, 1, 1),
    if DOW =< 4 ->
	D0101 - DOW + 1;
    true ->
	D0101 + 7 - DOW + 1
    end.


-include_lib("eunit/include/eunit.hrl").
-ifdef(TEST).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% RECURRENCE TESTS
%%
%% Tests date predictions for events that recur
%% @end
%%--------------------------------------------------------------------
daily_recurrence_test() ->
    %% basic increment
    ?assertEqual({2011, 1, 2}, event_date("daily", 1, undefined, {2011, 1, 1}, {2011, 1, 1})),     
    ?assertEqual({2011, 6, 2}, event_date("daily", 1, undefined, {2011, 6, 1}, {2011, 6, 1})),
    %%  increment over month boundary
    ?assertEqual({2011, 2, 1}, event_date("daily", 1, undefined, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 7, 1}, event_date("daily", 1, undefined, {2011, 6, 1}, {2011, 6, 30})),
    %% increment over year boundary
    ?assertEqual({2011, 1, 1}, event_date("daily", 1, undefined, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 1, 1}, event_date("daily", 1, undefined, {2010, 6, 1}, {2010, 12, 31})),
    %% leap year (into)
    ?assertEqual({2008, 2, 29}, event_date("daily", 1, undefined, {2008, 1, 1}, {2008, 2, 28})),
    ?assertEqual({2008, 2, 29}, event_date("daily", 1, undefined, {2008, 1, 1}, {2008, 2, 28})),
    %% leap year (over)
    ?assertEqual({2008, 3, 1}, event_date("daily", 1, undefined, {2008, 1, 1}, {2008, 2, 29})),
    ?assertEqual({2008, 3, 1}, event_date("daily", 1, undefined, {2008, 1, 1}, {2008, 2, 29})),
    %% shift start date (no impact)
    ?assertEqual({2011, 1, 2}, event_date("daily", 1, undefined, {2008, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 2}, event_date("daily", 1, undefined, {2009, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 2}, event_date("daily", 1, undefined, {2010, 1, 1}, {2011, 1, 1})),
    %% even step (small)
    ?assertEqual({2011, 1, 5}, event_date("daily", 4, undefined, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 2}, event_date("daily", 4, undefined, {2011, 1, 1}, {2011, 1, 29})),
    ?assertEqual({2011, 1, 4}, event_date("daily", 4, undefined, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 6, 5}, event_date("daily", 4, undefined, {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 7, 3}, event_date("daily", 4, undefined, {2011, 6, 1}, {2011, 6, 29})),
    %% odd step (small)
    ?assertEqual({2011, 1, 8}, event_date("daily", 7, undefined, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 5}, event_date("daily", 7, undefined, {2011, 1, 1}, {2011, 1, 29})),
    ?assertEqual({2011, 1, 7}, event_date("daily", 7, undefined, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 6, 8}, event_date("daily", 7, undefined, {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 7, 6}, event_date("daily", 7, undefined, {2011, 6, 1}, {2011, 6, 29})),
    %% even step (large)
    ?assertEqual({2011, 2, 18}, event_date("daily", 48, undefined, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 20}, event_date("daily", 48, undefined, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 7, 19}, event_date("daily", 48, undefined, {2011, 6, 1}, {2011, 6, 1})),
    %% odd step (large)
    ?assertEqual({2011, 3, 27}, event_date("daily", 85, undefined, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 2}, event_date("daily", 85, undefined, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 8, 25}, event_date("daily", 85, undefined, {2011, 6, 1}, {2011, 6, 1})),
    %% current date on (interval)
    ?assertEqual({2011, 1, 9}, event_date("daily", 4, undefined, {2011, 1, 5}, {2011, 1, 5})),
    %% current date after (interval)
    ?assertEqual({2011, 1, 9}, event_date("daily", 4, undefined, {2011, 1, 5}, {2011, 1, 6})),
    %% shift start date
    ?assertEqual({2011, 2, 5}, event_date("daily", 4, undefined, {2011, 2, 1}, {2011, 2, 3})),
    ?assertEqual({2011, 2, 6}, event_date("daily", 4, undefined, {2011, 2, 2}, {2011, 2, 3})),
    %% long span
    ?assertEqual({2011, 1, 2}, event_date("daily", 4, undefined, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 12}, event_date("daily", 4, undefined, {1983, 4, 11}, {2011, 4, 11})).

weekly_recurrence_test() ->
    %% basic increment
    ?assertEqual({2011, 1, 3}, event_date("weekly", 1, [monday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 4}, event_date("weekly", 1, [tuesday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 5}, event_date("weekly", 1, [wensday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 6}, event_date("weekly", 1, [thursday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 7}, event_date("weekly", 1, [friday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 8}, event_date("weekly", 1, [saturday], {2011, 1, 1}, {2011, 1, 1})), %% 1st is a sat
    ?assertEqual({2011, 1, 2}, event_date("weekly", 1, [sunday], {2011, 1, 1}, {2011, 1, 1})),
    %%  increment over month boundary
    ?assertEqual({2011, 2, 7}, event_date("weekly", 1, [monday], {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 1, [tuesday], {2011, 1, 1}, {2011, 1, 25})),
    ?assertEqual({2011, 2, 2}, event_date("weekly", 1, [wensday], {2011, 1, 1}, {2011, 1, 26})),
    ?assertEqual({2011, 2, 3}, event_date("weekly", 1, [thursday], {2011, 1, 1}, {2011, 1, 27})),
    ?assertEqual({2011, 2, 4}, event_date("weekly", 1, [friday], {2011, 1, 1}, {2011, 1, 28})),
    ?assertEqual({2011, 2, 5}, event_date("weekly", 1, [saturday], {2011, 1, 1}, {2011, 1, 29})),
    ?assertEqual({2011, 2, 6}, event_date("weekly", 1, [sunday], {2011, 1, 1}, {2011, 1, 30})),
    %%  increment over year boundary
    ?assertEqual({2011, 1, 3}, event_date("weekly", 1, [monday], {2010, 1, 1}, {2010, 12, 27})),
    ?assertEqual({2011, 1, 4}, event_date("weekly", 1, [tuesday], {2010, 1, 1}, {2010, 12, 28})),
    ?assertEqual({2011, 1, 5}, event_date("weekly", 1, [wensday], {2010, 1, 1}, {2010, 12, 29})),
    ?assertEqual({2011, 1, 6}, event_date("weekly", 1, [thursday], {2010, 1, 1}, {2010, 12, 30})),
    ?assertEqual({2011, 1, 7}, event_date("weekly", 1, [friday], {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 1, 1}, event_date("weekly", 1, [saturday], {2010, 1, 1}, {2010, 12, 25})),
    ?assertEqual({2011, 1, 2}, event_date("weekly", 1, [sunday], {2010, 1, 1}, {2010, 12, 26})),
    %%  leap year (into)
    ?assertEqual({2008, 2, 29}, event_date("weekly", 1, [friday], {2008, 1, 1}, {2008, 2, 28})),
    %%  leap year (over)
    ?assertEqual({2008, 3, 1}, event_date("weekly", 1, [saturday], {2008, 1, 1}, {2008, 2, 28})),
    ?assertEqual({2008, 3, 7}, event_date("weekly", 1, [friday], {2008, 1, 1}, {2008, 2, 29})),
    %% current date on (simple)
    ?assertEqual({2011, 1, 10}, event_date("weekly", 1, [monday], {2011, 1, 1}, {2011, 1, 3})),
    ?assertEqual({2011, 1, 11}, event_date("weekly", 1, [tuesday], {2011, 1, 1}, {2011, 1, 4})),
    ?assertEqual({2011, 1, 12}, event_date("weekly", 1, [wensday], {2011, 1, 1}, {2011, 1, 5})),
    ?assertEqual({2011, 1, 13}, event_date("weekly", 1, [thursday], {2011, 1, 1}, {2011, 1, 6})),
    ?assertEqual({2011, 1, 14}, event_date("weekly", 1, [friday], {2011, 1, 1}, {2011, 1, 7})),
    ?assertEqual({2011, 1, 8}, event_date("weekly", 1, [saturday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 9}, event_date("weekly", 1, [sunday], {2011, 1, 1}, {2011, 1, 2})),
    %% shift start date (no impact)
    ?assertEqual({2011, 1, 3}, event_date("weekly", 1, [monday], {2008, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 3}, event_date("weekly", 1, [monday], {2009, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 3}, event_date("weekly", 1, [monday], {2010, 1, 2}, {2011, 1, 1})),
    %% multiple DOWs
    ?assertEqual({2011, 1, 2}, event_date("weekly", 1, [monday,tuesday,wensday,thursday,friday,saturday,sunday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 3}, event_date("weekly", 1, [monday,tuesday,wensday,thursday,friday,saturday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 4}, event_date("weekly", 1, [tuesday,wensday,thursday,friday,saturday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 5}, event_date("weekly", 1, [wensday,thursday,friday,saturday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 6}, event_date("weekly", 1, [thursday,friday,saturday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 7}, event_date("weekly", 1, [friday,saturday], {2011, 1, 1}, {2011, 1, 1})),
    %% last DOW of an active week
    ?assertEqual({2011, 1, 10}, event_date("weekly", 1, [monday,tuesday,wensday,thursday,friday], {2011, 1, 1}, {2011, 1, 7})),
    %% even step (small)
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 12}, event_date("weekly", 2, [wensday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 13}, event_date("weekly", 2, [thursday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 14}, event_date("weekly", 2, [friday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 15}, event_date("weekly", 2, [saturday], {2011, 1, 1}, {2011, 1, 1})),
    %%     SIDE NOTE: No event engines seem to agree on this case, so I am doing what makes sense to me
    %%                and google calendar agrees (thunderbird and outlook be damned!)
    ?assertEqual({2011, 1, 2}, event_date("weekly", 2, [sunday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 16}, event_date("weekly", 2, [sunday], {2011, 1, 1}, {2011, 1, 2})),
    %% odd step (small)
    ?assertEqual({2011, 1, 17}, event_date("weekly", 3, [monday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 3, [tuesday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 19}, event_date("weekly", 3, [wensday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 20}, event_date("weekly", 3, [thursday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 21}, event_date("weekly", 3, [friday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 22}, event_date("weekly", 3, [saturday], {2011, 1, 1}, {2011, 1, 1})),
    %%     SIDE NOTE: No event engines seem to agree on this case, so I am doing what makes sense to me
    ?assertEqual({2011, 1, 2}, event_date("weekly", 3, [sunday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 23}, event_date("weekly", 3, [sunday], {2011, 1, 1}, {2011, 1, 2})),
    %% even step (large)
    ?assertEqual({2011, 6, 13}, event_date("weekly", 24, [monday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 6, 14}, event_date("weekly", 24, [tuesday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 6, 15}, event_date("weekly", 24, [wensday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 6, 16}, event_date("weekly", 24, [thursday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 6, 17}, event_date("weekly", 24, [friday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 6, 18}, event_date("weekly", 24, [saturday], {2011, 1, 1}, {2011, 1, 1})),
    %%     SIDE NOTE: No event engines seem to agree on this case, so I am doing what makes sense to me
    ?assertEqual({2011, 1, 2}, event_date("weekly", 24, [sunday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 6, 19}, event_date("weekly", 24, [sunday], {2011, 1, 1}, {2011, 1, 2})),
    %% odd step (large)
    ?assertEqual({2011, 9, 12}, event_date("weekly", 37, [monday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 9, 13}, event_date("weekly", 37, [tuesday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 9, 14}, event_date("weekly", 37, [wensday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 9, 15}, event_date("weekly", 37, [thursday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 9, 16}, event_date("weekly", 37, [friday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 9, 17}, event_date("weekly", 37, [saturday], {2011, 1, 1}, {2011, 1, 1})),
    %%     SIDE NOTE: No event engines seem to agree on this case, so I am doing what makes sense to me
    ?assertEqual({2011, 1, 2}, event_date("weekly", 36, [sunday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 9, 11}, event_date("weekly", 36, [sunday], {2011, 1, 1}, {2011, 1, 2})),
    %% multiple DOWs with step (currently on start)
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 2})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 3})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 4})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 5})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 6})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 7})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 8})),
    %% multiple DOWs with step (start in past)
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 9})),
    ?assertEqual({2011, 1, 12}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 10})),
    ?assertEqual({2011, 1, 12}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 11})),
    ?assertEqual({2011, 1, 14}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 12})),
    ?assertEqual({2011, 1, 14}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 13})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 14})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 15})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 16})),
    %% multiple DOWs over month boundary 
    ?assertEqual({2011, 2, 7}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 28})),
    %% multiple DOWs over year boundary 
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2010, 1, 1}, {2010, 12, 31})),
    %% current date on (interval)
    ?assertEqual({2011, 1, 17}, event_date("weekly", 3, [monday], {2011, 1, 1}, {2011, 1, 3})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 3, [tuesday], {2011, 1, 1}, {2011, 1, 4})),
    ?assertEqual({2011, 1, 19}, event_date("weekly", 3, [wensday], {2011, 1, 1}, {2011, 1, 5})),
    ?assertEqual({2011, 1, 20}, event_date("weekly", 3, [thursday], {2011, 1, 1}, {2011, 1, 6})),
    ?assertEqual({2011, 1, 21}, event_date("weekly", 3, [friday], {2011, 1, 1}, {2011, 1, 7})),
    ?assertEqual({2011, 1, 22}, event_date("weekly", 3, [saturday], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 23}, event_date("weekly", 3, [sunday], {2011, 1, 1}, {2011, 1, 2})),
    %% shift start date
    ?assertEqual({2011, 1, 31}, event_date("weekly", 5, [monday], {2004, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 5, [tuesday], {2005, 2, 8}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 2}, event_date("weekly", 5, [wensday], {2006, 3, 15}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 20}, event_date("weekly", 5, [thursday], {2007, 4, 22}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 4}, event_date("weekly", 5, [friday], {2008, 5, 29}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 22}, event_date("weekly", 5, [saturday], {2009, 6, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 2}, event_date("weekly", 5, [sunday], {2010, 7, 8}, {2011, 1, 1})),
    %% long span
    ?assertEqual({2011, 1, 10}, event_date("weekly", 4, [monday], {1983, 4, 11}, {2011, 1, 1})), 
    ?assertEqual({2011, 5, 2}, event_date("weekly", 4, [monday], {1983, 4, 11}, {2011, 4, 11})).    

every_other_day_weekly_recurrence_test() ->
    %% This is a proof of concept based on (implementation of a random find on the internet)
    %% http://www.outlookbanter.com/outlook-calandaring/80737-set-recurrance-every-other-weekday.html

    %% Blue
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 2})),     
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 3})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 4})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 5})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 6})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 7})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 8})),
    ?assertEqual({2011, 1, 10}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 9})),
    ?assertEqual({2011, 1, 12}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 10})),
    ?assertEqual({2011, 1, 12}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 11})),
    ?assertEqual({2011, 1, 14}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 12})),
    ?assertEqual({2011, 1, 14}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 13})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 14})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 15})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 16})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 17})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 18})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 19})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 20})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 21})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 22})),
    ?assertEqual({2011, 1, 24}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 23})),
    ?assertEqual({2011, 1, 26}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 24})),
    ?assertEqual({2011, 1, 26}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 25})),
    ?assertEqual({2011, 1, 28}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 26})),
    ?assertEqual({2011, 1, 28}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 27})),
    ?assertEqual({2011, 2, 7}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 28})),
    ?assertEqual({2011, 2, 7}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 29})),
    ?assertEqual({2011, 2, 7}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 30})),
    ?assertEqual({2011, 2, 7}, event_date("weekly", 2, [monday, wensday, friday], {2011, 1, 1}, {2011, 1, 31})),

    %% White
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 2})),     
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 3})),     
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 4})),     
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 5})),     
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 6})),     
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 7})),     
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 8})),     
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 9})),     
    ?assertEqual({2011, 1, 11}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 10})),     
    ?assertEqual({2011, 1, 13}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 11})),     
    ?assertEqual({2011, 1, 13}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 12})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 13})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 14})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 15})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 16})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 17})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 18})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 19})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 20})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 21})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 22})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 23})),     
    ?assertEqual({2011, 1, 25}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 24})),
    ?assertEqual({2011, 1, 27}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 25})),
    ?assertEqual({2011, 1, 27}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 26})),
    ?assertEqual({2011, 2, 8}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 27})),
    ?assertEqual({2011, 2, 8}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 28})),
    ?assertEqual({2011, 2, 8}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 29})),
    ?assertEqual({2011, 2, 8}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 30})),
    ?assertEqual({2011, 2, 8}, event_date("weekly", 2, [tuesday, thursday], {2011, 1, 1}, {2011, 1, 31})),

    %% White
    ?assertEqual({2011, 1, 3}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 2})),
    ?assertEqual({2011, 1, 5}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 3})),
    ?assertEqual({2011, 1, 5}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 4})),
    ?assertEqual({2011, 1, 7}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 5})),
    ?assertEqual({2011, 1, 7}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 6})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 7})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 8})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 9})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 10})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 11})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 12})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 13})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 14})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 15})),
    ?assertEqual({2011, 1, 17}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 16})),
    ?assertEqual({2011, 1, 19}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 17})),
    ?assertEqual({2011, 1, 19}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 18})),
    ?assertEqual({2011, 1, 21}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 19})),
    ?assertEqual({2011, 1, 21}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 20})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 21})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 22})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 23})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 24})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 25})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 26})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 27})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 28})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 29})),
    ?assertEqual({2011, 1, 31}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 30})),
    ?assertEqual({2011, 2, 2}, event_date("weekly", 2, [monday, wensday, friday], {2010, 12, 25}, {2011, 1, 31})),

    %% Blue
    ?assertEqual({2011, 1, 4}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 2})),
    ?assertEqual({2011, 1, 4}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 3})),
    ?assertEqual({2011, 1, 6}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 4})),
    ?assertEqual({2011, 1, 6}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 5})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 6})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 7})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 8})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 9})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 10})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 11})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 12})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 13})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 14})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 15})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 16})),
    ?assertEqual({2011, 1, 18}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 17})),
    ?assertEqual({2011, 1, 20}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 18})),
    ?assertEqual({2011, 1, 20}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 19})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 20})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 21})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 22})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 23})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 24})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 25})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 26})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 27})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 28})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 29})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 30})),
    ?assertEqual({2011, 2, 1}, event_date("weekly", 2, [tuesday, thursday], {2010, 12, 25}, {2011, 1, 31})).

monthly_every_recurrence_test() ->
    %% basic increment (also crosses month boundary) 
    ?assertEqual({2011, 1, 3}, event_date("monthly", 1, {every, monday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 10}, event_date("monthly", 1, {every, monday}, {2011, 1, 1}, {2011, 1, 3})),
    ?assertEqual({2011, 1, 17}, event_date("monthly", 1, {every, monday}, {2011, 1, 1}, {2011, 1, 10})),
    ?assertEqual({2011, 1, 24}, event_date("monthly", 1, {every, monday}, {2011, 1, 1}, {2011, 1, 17})),
    ?assertEqual({2011, 1, 31}, event_date("monthly", 1, {every, monday}, {2011, 1, 1}, {2011, 1, 24})),
    ?assertEqual({2011, 1, 4}, event_date("monthly", 1, {every, tuesday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 11}, event_date("monthly", 1, {every, tuesday}, {2011, 1, 1}, {2011, 1, 4})),
    ?assertEqual({2011, 1, 18}, event_date("monthly", 1, {every, tuesday}, {2011, 1, 1}, {2011, 1, 11})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, {every, tuesday}, {2011, 1, 1}, {2011, 1, 18})),
    ?assertEqual({2011, 2, 1}, event_date("monthly", 1, {every, tuesday}, {2011, 1, 1}, {2011, 1, 25})),
    ?assertEqual({2011, 1, 5}, event_date("monthly", 1, {every, wensday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 12}, event_date("monthly", 1, {every, wensday}, {2011, 1, 1}, {2011, 1, 5})),
    ?assertEqual({2011, 1, 19}, event_date("monthly", 1, {every, wensday}, {2011, 1, 1}, {2011, 1, 12})),
    ?assertEqual({2011, 1, 26}, event_date("monthly", 1, {every, wensday}, {2011, 1, 1}, {2011, 1, 19})),
    ?assertEqual({2011, 2, 2}, event_date("monthly", 1, {every, wensday}, {2011, 1, 1}, {2011, 1, 26})),
    ?assertEqual({2011, 1, 6}, event_date("monthly", 1, {every, thursday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 13}, event_date("monthly", 1, {every, thursday}, {2011, 1, 1}, {2011, 1, 6})),
    ?assertEqual({2011, 1, 20}, event_date("monthly", 1, {every, thursday}, {2011, 1, 1}, {2011, 1, 13})),
    ?assertEqual({2011, 1, 27}, event_date("monthly", 1, {every, thursday}, {2011, 1, 1}, {2011, 1, 20})),
    ?assertEqual({2011, 2, 3}, event_date("monthly", 1, {every, thursday}, {2011, 1, 1}, {2011, 1, 27})),
    ?assertEqual({2011, 1, 7}, event_date("monthly", 1, {every, friday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 14}, event_date("monthly", 1, {every, friday}, {2011, 1, 1}, {2011, 1, 7})),
    ?assertEqual({2011, 1, 21}, event_date("monthly", 1, {every, friday}, {2011, 1, 1}, {2011, 1, 14})),
    ?assertEqual({2011, 1, 28}, event_date("monthly", 1, {every, friday}, {2011, 1, 1}, {2011, 1, 21})),
    ?assertEqual({2011, 2, 4}, event_date("monthly", 1, {every, friday}, {2011, 1, 1}, {2011, 1, 28})),
    ?assertEqual({2011, 1, 8}, event_date("monthly", 1, {every, saturday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 15}, event_date("monthly", 1, {every, saturday}, {2011, 1, 1}, {2011, 1, 8})),
    ?assertEqual({2011, 1, 22}, event_date("monthly", 1, {every, saturday}, {2011, 1, 1}, {2011, 1, 15})),
    ?assertEqual({2011, 1, 29}, event_date("monthly", 1, {every, saturday}, {2011, 1, 1}, {2011, 1, 22})),
    ?assertEqual({2011, 2, 5}, event_date("monthly", 1, {every, saturday}, {2011, 1, 1}, {2011, 1, 29})),
    ?assertEqual({2011, 1, 2}, event_date("monthly", 1, {every, sunday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 9}, event_date("monthly", 1, {every, sunday}, {2011, 1, 1}, {2011, 1, 2})),
    ?assertEqual({2011, 1, 16}, event_date("monthly", 1, {every, sunday}, {2011, 1, 1}, {2011, 1, 9})),
    ?assertEqual({2011, 1, 23}, event_date("monthly", 1, {every, sunday}, {2011, 1, 1}, {2011, 1, 16})),
    ?assertEqual({2011, 1, 30}, event_date("monthly", 1, {every, sunday}, {2011, 1, 1}, {2011, 1, 23})),
    ?assertEqual({2011, 2, 6}, event_date("monthly", 1, {every, sunday}, {2011, 1, 1}, {2011, 1, 30})),
    %% increment over year boundary 
    ?assertEqual({2011, 1, 3}, event_date("monthly", 1, {every, monday}, {2010, 1, 1}, {2010, 12, 27})),
    ?assertEqual({2011, 1, 4}, event_date("monthly", 1, {every, tuesday}, {2010, 1, 1}, {2010, 12, 28})),
    ?assertEqual({2011, 1, 5}, event_date("monthly", 1, {every, wensday}, {2010, 1, 1}, {2010, 12, 29})),
    ?assertEqual({2011, 1, 6}, event_date("monthly", 1, {every, thursday}, {2010, 1, 1}, {2010, 12, 30})),
    ?assertEqual({2011, 1, 7}, event_date("monthly", 1, {every, friday}, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 1, 1}, event_date("monthly", 1, {every, saturday}, {2010, 1, 1}, {2010, 12, 25})),
    ?assertEqual({2011, 1, 2}, event_date("monthly", 1, {every, sunday}, {2010, 1, 1}, {2010, 12, 26})),
    %% leap year (into) 
    ?assertEqual({2008, 2, 29}, event_date("monthly", 1, {every, friday}, {2008, 1, 1}, {2008, 2, 28})),
    %% leap year (over)
    ?assertEqual({2008, 3, 1}, event_date("monthly", 1, {every, saturday}, {2008, 1, 1}, {2008, 2, 28})),
    %% current date on (simple)
    ?assertEqual({2011, 1, 10}, event_date("monthly", 1, {every, monday}, {2011, 1, 1}, {2011, 1, 3})),
    ?assertEqual({2011, 1, 18}, event_date("monthly", 1, {every, tuesday}, {2011, 1, 10}, {2011, 1, 11})),
    ?assertEqual({2011, 1, 26}, event_date("monthly", 1, {every, wensday}, {2011, 1, 17}, {2011, 1, 19})),
    %% current date after (simple)
    ?assertEqual({2011, 1, 10}, event_date("monthly", 1, {every, monday}, {2011, 1, 1}, {2011, 1, 5})),
    ?assertEqual({2011, 1, 18}, event_date("monthly", 1, {every, tuesday}, {2011, 1, 10}, {2011, 1, 14})),
    ?assertEqual({2011, 1, 26}, event_date("monthly", 1, {every, wensday}, {2011, 1, 17}, {2011, 1, 21})),
    %% shift start date (no impact)
    ?assertEqual({2011, 1, 3}, event_date("monthly", 1, {every, monday}, {2004, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 11}, event_date("monthly", 1, {every, tuesday}, {2005, 2, 1}, {2011, 1, 4})),
    ?assertEqual({2011, 1, 19}, event_date("monthly", 1, {every, wensday}, {2006, 3, 1}, {2011, 1, 12})),
    ?assertEqual({2011, 1, 27}, event_date("monthly", 1, {every, thursday}, {2007, 4, 1}, {2011, 1, 20})),
    ?assertEqual({2011, 2, 4}, event_date("monthly", 1, {every, friday}, {2008, 5, 1}, {2011, 1, 28})),
    ?assertEqual({2011, 1, 8}, event_date("monthly", 1, {every, saturday}, {2009, 6, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 9}, event_date("monthly", 1, {every, sunday}, {2010, 7, 1}, {2011, 1, 2})),
    %% even step (small)
    ?assertEqual({2011, 3, 7}, event_date("monthly", 2, {every, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 1}, event_date("monthly", 2, {every, tuesday}, {2011, 1, 1}, {2011, 1, 25})),
    ?assertEqual({2011, 3, 2}, event_date("monthly", 2, {every, wensday}, {2011, 1, 1}, {2011, 1, 26})),
    ?assertEqual({2011, 3, 3}, event_date("monthly", 2, {every, thursday}, {2011, 1, 1}, {2011, 1, 27})),
    ?assertEqual({2011, 3, 4}, event_date("monthly", 2, {every, friday}, {2011, 1, 1}, {2011, 1, 28})),
    ?assertEqual({2011, 3, 5}, event_date("monthly", 2, {every, saturday}, {2011, 1, 1}, {2011, 1, 29})),
    ?assertEqual({2011, 3, 6}, event_date("monthly", 2, {every, sunday}, {2011, 1, 1}, {2011, 1, 30})),
    %% odd step (small)
    ?assertEqual({2011, 9, 5}, event_date("monthly", 3, {every, monday}, {2011, 6, 1}, {2011, 6, 27})),
    ?assertEqual({2011, 9, 6}, event_date("monthly", 3, {every, tuesday}, {2011, 6, 1}, {2011, 6, 28})),
    ?assertEqual({2011, 9, 7}, event_date("monthly", 3, {every, wensday}, {2011, 6, 1}, {2011, 6, 29})),
    ?assertEqual({2011, 9, 1}, event_date("monthly", 3, {every, thursday}, {2011, 6, 1}, {2011, 6, 30})),
    ?assertEqual({2011, 9, 2}, event_date("monthly", 3, {every, friday}, {2011, 6, 1}, {2011, 6, 24})),
    ?assertEqual({2011, 9, 3}, event_date("monthly", 3, {every, saturday}, {2011, 6, 1}, {2011, 6, 25})),
    ?assertEqual({2011, 9, 4}, event_date("monthly", 3, {every, sunday}, {2011, 6, 1}, {2011, 6, 26})),
    %% current date on (interval)
    ?assertEqual({2011, 5, 2}, event_date("monthly", 4, {every, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 5, 3}, event_date("monthly", 4, {every, tuesday}, {2011, 1, 10}, {2011, 1, 25})),
    ?assertEqual({2011, 5, 4}, event_date("monthly", 4, {every, wensday}, {2011, 1, 17}, {2011, 1, 26})),
    %% current date after (interval)
    ?assertEqual({2011, 5, 2}, event_date("monthly", 4, {every, monday}, {2011, 1, 1}, {2011, 2, 2})),
    ?assertEqual({2011, 5, 3}, event_date("monthly", 4, {every, tuesday}, {2011, 1, 10}, {2011, 3, 14})),
    ?assertEqual({2011, 5, 4}, event_date("monthly", 4, {every, wensday}, {2011, 1, 17}, {2011, 3, 21})),
    %% shift start date
    ?assertEqual({2011, 2, 7}, event_date("monthly", 5, {every, monday}, {2004, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 5, 3}, event_date("monthly", 5, {every, tuesday}, {2005, 2, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 2}, event_date("monthly", 5, {every, wensday}, {2006, 3, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 6}, event_date("monthly", 5, {every, thursday}, {2007, 4, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 1}, event_date("monthly", 5, {every, friday}, {2008, 5, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 5}, event_date("monthly", 5, {every, saturday}, {2009, 6, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 5, 1}, event_date("monthly", 5, {every, sunday}, {2010, 7, 1}, {2011, 1, 1})),
    %% long span
    ?assertEqual({2011, 3, 7}, event_date("monthly", 5, {every, monday}, {1983, 4, 11}, {2011, 1, 1})).

monthly_last_recurrence_test() ->
    %% basic increment 
    ?assertEqual({2011, 1, 31}, event_date("monthly", 1, {last, monday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, {last, tuesday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 26}, event_date("monthly", 1, {last, wensday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 27}, event_date("monthly", 1, {last, thursday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 28}, event_date("monthly", 1, {last, friday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 29}, event_date("monthly", 1, {last, saturday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 30}, event_date("monthly", 1, {last, sunday} , {2011, 1, 1}, {2011, 1, 1})),    
    %% basic increment (mid year)
    ?assertEqual({2011, 6, 27}, event_date("monthly", 1, {last, monday}, {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 6, 28}, event_date("monthly", 1, {last, tuesday}, {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 6, 29}, event_date("monthly", 1, {last, wensday}, {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 6, 30}, event_date("monthly", 1, {last, thursday}, {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 6, 24}, event_date("monthly", 1, {last, friday}, {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 6, 25}, event_date("monthly", 1, {last, saturday}, {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 6, 26}, event_date("monthly", 1, {last, sunday} , {2011, 6, 1}, {2011, 6, 1})),    
    %% increment over month boundary
    ?assertEqual({2011, 2, 28}, event_date("monthly", 1, {last, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 2, 22}, event_date("monthly", 1, {last, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 2, 23}, event_date("monthly", 1, {last, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 2, 24}, event_date("monthly", 1, {last, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 2, 25}, event_date("monthly", 1, {last, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 2, 26}, event_date("monthly", 1, {last, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 2, 27}, event_date("monthly", 1, {last, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% increment over year boundary
    ?assertEqual({2011, 1, 31}, event_date("monthly", 1, {last, monday}, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, {last, tuesday}, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 1, 26}, event_date("monthly", 1, {last, wensday}, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 1, 27}, event_date("monthly", 1, {last, thursday}, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 1, 28}, event_date("monthly", 1, {last, friday}, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 1, 29}, event_date("monthly", 1, {last, saturday}, {2010, 1, 1}, {2010, 12, 31})),
    ?assertEqual({2011, 1, 30}, event_date("monthly", 1, {last, sunday} , {2010, 1, 1}, {2010, 12, 31})),    
    %% leap year
    ?assertEqual({2008, 2, 25}, event_date("monthly", 1, {last, monday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 26}, event_date("monthly", 1, {last, tuesday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 27}, event_date("monthly", 1, {last, wensday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 28}, event_date("monthly", 1, {last, thursday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 29}, event_date("monthly", 1, {last, friday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 23}, event_date("monthly", 1, {last, saturday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 24}, event_date("monthly", 1, {last, sunday} , {2008, 1, 1}, {2008, 2, 1})),
    %% shift start date (no impact)
    ?assertEqual({2011, 1, 31}, event_date("monthly", 1, {last, monday}, {2004, 12, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, {last, tuesday}, {2005, 10, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 26}, event_date("monthly", 1, {last, wensday}, {2006, 11, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 27}, event_date("monthly", 1, {last, thursday}, {2007, 9, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 28}, event_date("monthly", 1, {last, friday}, {2008, 8, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 29}, event_date("monthly", 1, {last, saturday}, {2009, 7, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 30}, event_date("monthly", 1, {last, sunday} , {2010, 6, 1}, {2011, 1, 1})),
    %% even step (small) 
    ?assertEqual({2011, 3, 28}, event_date("monthly", 2, {last, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 29}, event_date("monthly", 2, {last, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 30}, event_date("monthly", 2, {last, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 31}, event_date("monthly", 2, {last, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 25}, event_date("monthly", 2, {last, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 26}, event_date("monthly", 2, {last, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 27}, event_date("monthly", 2, {last, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% odd step (small) 
    ?assertEqual({2011, 4, 25}, event_date("monthly", 3, {last, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 26}, event_date("monthly", 3, {last, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 27}, event_date("monthly", 3, {last, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 28}, event_date("monthly", 3, {last, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 29}, event_date("monthly", 3, {last, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 30}, event_date("monthly", 3, {last, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 24}, event_date("monthly", 3, {last, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% even step (large) 
    ?assertEqual({2014, 1, 27}, event_date("monthly", 36, {last, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 1, 28}, event_date("monthly", 36, {last, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 1, 29}, event_date("monthly", 36, {last, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 1, 30}, event_date("monthly", 36, {last, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 1, 31}, event_date("monthly", 36, {last, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 1, 25}, event_date("monthly", 36, {last, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 1, 26}, event_date("monthly", 36, {last, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% odd step (large) 
    ?assertEqual({2014, 2, 24}, event_date("monthly", 37, {last, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 2, 25}, event_date("monthly", 37, {last, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 2, 26}, event_date("monthly", 37, {last, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 2, 27}, event_date("monthly", 37, {last, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 2, 28}, event_date("monthly", 37, {last, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 2, 22}, event_date("monthly", 37, {last, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2014, 2, 23}, event_date("monthly", 37, {last, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% shift start date
    ?assertEqual({2011, 3, 28}, event_date("monthly", 3, {last, monday}, {2010, 12, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 3, {last, tuesday}, {2010, 10, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 23}, event_date("monthly", 3, {last, wensday}, {2010, 11, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 31}, event_date("monthly", 3, {last, thursday}, {2010, 9, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 25}, event_date("monthly", 3, {last, friday}, {2010, 8, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 29}, event_date("monthly", 3, {last, saturday}, {2010, 7, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 27}, event_date("monthly", 3, {last, sunday} , {2010, 6, 1}, {2011, 1, 1})),
    %% long span
    ?assertEqual({2011, 3, 28}, event_date("monthly", 5, {last, monday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 29}, event_date("monthly", 5, {last, tuesday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 30}, event_date("monthly", 5, {last, wensday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 31}, event_date("monthly", 5, {last, thursday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 25}, event_date("monthly", 5, {last, friday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 26}, event_date("monthly", 5, {last, saturday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 27}, event_date("monthly", 5, {last, sunday} , {1983, 4, 11}, {2011, 1, 1})).

monthly_every_ordinal_recurrence_test() ->
    %% basic first
    ?assertEqual({2011, 1, 3}, event_date("monthly", 1, {first, monday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 4}, event_date("monthly", 1, {first, tuesday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 5}, event_date("monthly", 1, {first, wensday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 6}, event_date("monthly", 1, {first, thursday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 7}, event_date("monthly", 1, {first, friday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 5}, event_date("monthly", 1, {first, saturday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 2}, event_date("monthly", 1, {first, sunday} , {2011, 1, 1}, {2011, 1, 1})),
    %% basic second
    ?assertEqual({2011, 1, 10}, event_date("monthly", 1, {second, monday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 11}, event_date("monthly", 1, {second, tuesday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 12}, event_date("monthly", 1, {second, wensday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 13}, event_date("monthly", 1, {second, thursday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 14}, event_date("monthly", 1, {second, friday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 8}, event_date("monthly", 1, {second, saturday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 9}, event_date("monthly", 1, {second, sunday} , {2011, 1, 1}, {2011, 1, 1})),   
    %% basic third
    ?assertEqual({2011, 1, 17}, event_date("monthly", 1, {third, monday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 18}, event_date("monthly", 1, {third, tuesday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 19}, event_date("monthly", 1, {third, wensday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 20}, event_date("monthly", 1, {third, thursday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 21}, event_date("monthly", 1, {third, friday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 15}, event_date("monthly", 1, {third, saturday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 16}, event_date("monthly", 1, {third, sunday} , {2011, 1, 1}, {2011, 1, 1})),   
    %% basic fourth
    ?assertEqual({2011, 1, 24}, event_date("monthly", 1, {fourth, monday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, {fourth, tuesday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 26}, event_date("monthly", 1, {fourth, wensday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 27}, event_date("monthly", 1, {fourth, thursday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 28}, event_date("monthly", 1, {fourth, friday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 22}, event_date("monthly", 1, {fourth, saturday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 23}, event_date("monthly", 1, {fourth, sunday} , {2011, 1, 1}, {2011, 1, 1})),
    %% basic fifth
    ?assertEqual({2011, 1, 31}, event_date("monthly", 1, {fifth, monday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 1}, event_date("monthly", 1, {fifth, tuesday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 2}, event_date("monthly", 1, {fifth, wensday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 3}, event_date("monthly", 1, {fifth, thursday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 4}, event_date("monthly", 1, {fifth, friday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 29}, event_date("monthly", 1, {fifth, saturday}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 30}, event_date("monthly", 1, {fifth, sunday} , {2011, 1, 1}, {2011, 1, 1})),
    %% on occurance
    ?assertEqual({2011, 2, 7}, event_date("monthly", 1, {first, monday}, {2011, 1, 1}, {2011, 1, 3})),
    ?assertEqual({2011, 2, 14}, event_date("monthly", 1, {second, monday}, {2011, 1, 1}, {2011, 1, 10})),
    ?assertEqual({2011, 2, 21}, event_date("monthly", 1, {third, monday}, {2011, 1, 1}, {2011, 1, 17})),
    ?assertEqual({2011, 2, 28}, event_date("monthly", 1, {fourth, monday}, {2011, 1, 1}, {2011, 1, 24})),
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 1, {fifth, monday}, {2011, 1, 1}, {2011, 1, 31})),
    %% leap year first
    ?assertEqual({2008, 2, 4}, event_date("monthly", 1, {first, monday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 5}, event_date("monthly", 1, {first, tuesday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 6}, event_date("monthly", 1, {first, wensday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 7}, event_date("monthly", 1, {first, thursday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 3, 7}, event_date("monthly", 1, {first, friday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 2}, event_date("monthly", 1, {first, saturday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 3}, event_date("monthly", 1, {first, sunday} , {2008, 1, 1}, {2008, 2, 1})),
    %% leap year second
    ?assertEqual({2008, 2, 11}, event_date("monthly", 1, {second, monday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 12}, event_date("monthly", 1, {second, tuesday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 13}, event_date("monthly", 1, {second, wensday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 14}, event_date("monthly", 1, {second, thursday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 8}, event_date("monthly", 1, {second, friday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 9}, event_date("monthly", 1, {second, saturday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 10}, event_date("monthly", 1, {second, sunday} , {2008, 1, 1}, {2008, 2, 1})),   
    %% leap year third
    ?assertEqual({2008, 2, 18}, event_date("monthly", 1, {third, monday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 19}, event_date("monthly", 1, {third, tuesday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 20}, event_date("monthly", 1, {third, wensday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 21}, event_date("monthly", 1, {third, thursday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 15}, event_date("monthly", 1, {third, friday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 16}, event_date("monthly", 1, {third, saturday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 17}, event_date("monthly", 1, {third, sunday} , {2008, 1, 1}, {2008, 2, 1})),   
    %% leap year fourth
    ?assertEqual({2008, 2, 25}, event_date("monthly", 1, {fourth, monday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 26}, event_date("monthly", 1, {fourth, tuesday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 27}, event_date("monthly", 1, {fourth, wensday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 28}, event_date("monthly", 1, {fourth, thursday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 22}, event_date("monthly", 1, {fourth, friday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 23}, event_date("monthly", 1, {fourth, saturday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 24}, event_date("monthly", 1, {fourth, sunday} , {2008, 1, 1}, {2008, 2, 1})),
    %% leap year fifth
    ?assertEqual({2008, 3, 3}, event_date("monthly", 1, {fifth, monday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 3, 4}, event_date("monthly", 1, {fifth, tuesday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 3, 5}, event_date("monthly", 1, {fifth, wensday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 3, 6}, event_date("monthly", 1, {fifth, thursday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 2, 29}, event_date("monthly", 1, {fifth, friday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 3, 1}, event_date("monthly", 1, {fifth, saturday}, {2008, 1, 1}, {2008, 2, 1})),
    ?assertEqual({2008, 3, 2}, event_date("monthly", 1, {fifth, sunday} , {2008, 1, 1}, {2008, 2, 1})),    
    %% shift start date (no impact)
    ?assertEqual({2011, 1, 3}, event_date("monthly", 1, {first, monday}, {2004, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 11}, event_date("monthly", 1, {second, tuesday}, {2005, 2, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 19}, event_date("monthly", 1, {third, wensday}, {2006, 3, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 27}, event_date("monthly", 1, {fourth, thursday}, {2007, 4, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 4}, event_date("monthly", 1, {fifth, friday}, {2008, 5, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 5}, event_date("monthly", 1, {first, saturday}, {2009, 6, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 9}, event_date("monthly", 1, {second, sunday} , {2010, 7, 1}, {2011, 1, 1})),
    %% even step first (small)
    ?assertEqual({2011, 3, 7}, event_date("monthly", 2, {first, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 1}, event_date("monthly", 2, {first, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 2}, event_date("monthly", 2, {first, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 3}, event_date("monthly", 2, {first, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 4}, event_date("monthly", 2, {first, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 5}, event_date("monthly", 2, {first, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 6}, event_date("monthly", 2, {first, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% even step second (small)
    ?assertEqual({2011, 3, 14}, event_date("monthly", 2, {second, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 8}, event_date("monthly", 2, {second, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 9}, event_date("monthly", 2, {second, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 10}, event_date("monthly", 2, {second, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 11}, event_date("monthly", 2, {second, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 12}, event_date("monthly", 2, {second, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 13}, event_date("monthly", 2, {second, sunday} , {2011, 1, 1}, {2011, 1, 31})),   
    %% even step third (small)
    ?assertEqual({2011, 3, 21}, event_date("monthly", 2, {third, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 15}, event_date("monthly", 2, {third, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 16}, event_date("monthly", 2, {third, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 17}, event_date("monthly", 2, {third, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 18}, event_date("monthly", 2, {third, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 19}, event_date("monthly", 2, {third, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 20}, event_date("monthly", 2, {third, sunday} , {2011, 1, 1}, {2011, 1, 31})),   
    %% even step fourth (small)
    ?assertEqual({2011, 3, 28}, event_date("monthly", 2, {fourth, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 22}, event_date("monthly", 2, {fourth, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 23}, event_date("monthly", 2, {fourth, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 24}, event_date("monthly", 2, {fourth, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 25}, event_date("monthly", 2, {fourth, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 26}, event_date("monthly", 2, {fourth, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 27}, event_date("monthly", 2, {fourth, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% even step fifth (small)
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 2, {fifth, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 29}, event_date("monthly", 2, {fifth, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 30}, event_date("monthly", 2, {fifth, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 3, 31}, event_date("monthly", 2, {fifth, thursday}, {2011, 1, 1}, {2011, 1, 31})),    
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 2, {fifth, friday}, {2011, 1, 1}, {2011, 1, 31})),
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 2, {fifth, saturday}, {2011, 1, 1}, {2011, 1, 31})),
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 2, {fifth, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% odd step first (small)
    ?assertEqual({2011, 4, 4}, event_date("monthly", 3, {first, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 5}, event_date("monthly", 3, {first, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 6}, event_date("monthly", 3, {first, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 7}, event_date("monthly", 3, {first, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 1}, event_date("monthly", 3, {first, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 2}, event_date("monthly", 3, {first, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 3}, event_date("monthly", 3, {first, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% odd step second (small)
    ?assertEqual({2011, 4, 11}, event_date("monthly", 3, {second, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 12}, event_date("monthly", 3, {second, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 13}, event_date("monthly", 3, {second, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 14}, event_date("monthly", 3, {second, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 8}, event_date("monthly", 3, {second, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 9}, event_date("monthly", 3, {second, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 10}, event_date("monthly", 3, {second, sunday} , {2011, 1, 1}, {2011, 1, 31})),   
    %% odd step third (small)
    ?assertEqual({2011, 4, 18}, event_date("monthly", 3, {third, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 19}, event_date("monthly", 3, {third, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 20}, event_date("monthly", 3, {third, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 21}, event_date("monthly", 3, {third, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 15}, event_date("monthly", 3, {third, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 16}, event_date("monthly", 3, {third, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 17}, event_date("monthly", 3, {third, sunday} , {2011, 1, 1}, {2011, 1, 31})),   
    %% odd step fourth (small)
    ?assertEqual({2011, 4, 25}, event_date("monthly", 3, {fourth, monday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 26}, event_date("monthly", 3, {fourth, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 27}, event_date("monthly", 3, {fourth, wensday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 28}, event_date("monthly", 3, {fourth, thursday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 22}, event_date("monthly", 3, {fourth, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 23}, event_date("monthly", 3, {fourth, saturday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 24}, event_date("monthly", 3, {fourth, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% odd step fifth (small)
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 3, {fifth, monday}, {2011, 1, 1}, {2011, 1, 31})),
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 3, {fifth, tuesday}, {2011, 1, 1}, {2011, 1, 31})),
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 3, {fifth, wensday}, {2011, 1, 1}, {2011, 1, 31})),
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 3, {fifth, thursday}, {2011, 1, 1}, {2011, 1, 31})),    
    ?assertEqual({2011, 4, 29}, event_date("monthly", 3, {fifth, friday}, {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 4, 30}, event_date("monthly", 3, {fifth, saturday}, {2011, 1, 1}, {2011, 1, 31})),
%%!!    ?assertEqual({2011, ?, ??}, event_date("monthly", 3, {fifth, sunday} , {2011, 1, 1}, {2011, 1, 31})),
    %% shift start date
    ?assertEqual({2011, 2, 7}, event_date("monthly", 5, {first, monday}, {2004, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 5, 10}, event_date("monthly", 5, {second, tuesday}, {2005, 2, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 16}, event_date("monthly", 5, {third, wensday}, {2006, 3, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 27}, event_date("monthly", 5, {fourth, thursday}, {2007, 4, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 29}, event_date("monthly", 5, {fifth, friday}, {2008, 5, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 5}, event_date("monthly", 5, {first, saturday}, {2009, 6, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 5, 8}, event_date("monthly", 5, {second, sunday} , {2010, 7, 1}, {2011, 1, 1})),
    %% long span
    ?assertEqual({2011, 3, 28}, event_date("monthly", 5, {fourth, monday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 29}, event_date("monthly", 5, {fifth, tuesday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 2}, event_date("monthly", 5, {first, wensday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 10}, event_date("monthly", 5, {second, thursday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 18}, event_date("monthly", 5, {third, friday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 26}, event_date("monthly", 5, {fourth, saturday}, {1983, 4, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 6}, event_date("monthly", 5, {first, sunday} , {1983, 4, 11}, {2011, 1, 1})).

monthly_date_recurrence_test() ->
    %% basic increment
    lists:foreach(fun(D) ->                          
                          ?assertEqual({2011, 1, D + 1}, event_date("monthly", 1, [D + 1], {2011, 1, 1}, {2011, 1, D}))
                  end, lists:seq(1, 30)),
    lists:foreach(fun(D) ->                          
                          ?assertEqual({2011, 6, D + 1}, event_date("monthly", 1, [D + 1], {2011, 6, 1}, {2011, 6, D}))
                  end, lists:seq(1, 29)),
    %% same day, before
    ?assertEqual({2011, 3, 25}, event_date("monthly", 1, [25], {2011, 1, 1}, {2011, 3, 24})),
    %% increment over month boundary   
    ?assertEqual({2011, 2, 1}, event_date("monthly", 1, [1], {2011, 1, 1}, {2011, 1, 31})),
    ?assertEqual({2011, 7, 1}, event_date("monthly", 1, [1], {2011, 6, 1}, {2011, 6, 30})),
    %% increment over year boundary    
    ?assertEqual({2011, 1, 1}, event_date("monthly", 1, [1], {2010, 1, 1}, {2010, 12, 31})),
    %% leap year (into)
    ?assertEqual({2008, 2, 29}, event_date("monthly", 1, [29], {2008, 1, 1}, {2008, 2, 28})),
    %% leap year (over)
    ?assertEqual({2008, 3, 1}, event_date("monthly", 1, [1], {2008, 1, 1}, {2008, 2, 29})),
    %% shift start date (no impact)
    ?assertEqual({2011, 1, 2}, event_date("monthly", 1, [2], {2008, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 2}, event_date("monthly", 1, [2], {2009, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 2}, event_date("monthly", 1, [2], {2010, 1, 1}, {2011, 1, 1})),
    %% multiple dates
    ?assertEqual({2011, 1, 5}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 5}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 2})),
    ?assertEqual({2011, 1, 5}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 3})),
    ?assertEqual({2011, 1, 5}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 4})),
    ?assertEqual({2011, 1, 10}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 5})),
    ?assertEqual({2011, 1, 10}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 6})),
    ?assertEqual({2011, 1, 10}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 7})),
    ?assertEqual({2011, 1, 10}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 8})),
    ?assertEqual({2011, 1, 10}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 9})),
    ?assertEqual({2011, 1, 15}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 10})),
    ?assertEqual({2011, 1, 15}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 11})),
    ?assertEqual({2011, 1, 15}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 12})),
    ?assertEqual({2011, 1, 15}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 13})),
    ?assertEqual({2011, 1, 15}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 14})),
    ?assertEqual({2011, 1, 20}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 15})),
    ?assertEqual({2011, 1, 20}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 16})),
    ?assertEqual({2011, 1, 20}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 17})),
    ?assertEqual({2011, 1, 20}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 18})),
    ?assertEqual({2011, 1, 20}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 19})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 20})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 21})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 22})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 23})),
    ?assertEqual({2011, 1, 25}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 24})),
    ?assertEqual({2011, 2, 5}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 25})),
    ?assertEqual({2011, 2, 5}, event_date("monthly", 1, [5,10,15,20,25], {2011, 1, 1}, {2011, 1, 26})),
    %% even step (small)
    ?assertEqual({2011, 3, 2}, event_date("monthly", 2, [2], {2011, 1, 1}, {2011, 1, 2})),
    ?assertEqual({2011, 5, 2}, event_date("monthly", 2, [2], {2011, 1, 1}, {2011, 3, 2})),
    ?assertEqual({2011, 7, 2}, event_date("monthly", 2, [2], {2011, 1, 1}, {2011, 5, 2})),
    ?assertEqual({2011, 6, 2}, event_date("monthly", 2, [2], {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 8, 2}, event_date("monthly", 2, [2], {2011, 6, 1}, {2011, 6, 2})),
    %% odd step (small)
    ?assertEqual({2011, 4, 2}, event_date("monthly", 3, [2], {2011, 1, 1}, {2011, 1, 2})),
    ?assertEqual({2011, 7, 2}, event_date("monthly", 3, [2], {2011, 1, 1}, {2011, 4, 2})),
    ?assertEqual({2011, 10, 2}, event_date("monthly", 3, [2], {2011, 1, 1}, {2011, 7, 2})),
    ?assertEqual({2011, 6, 2}, event_date("monthly", 3, [2], {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2011, 9, 2}, event_date("monthly", 3, [2], {2011, 6, 1}, {2011, 6, 2})),
    %% even step (large)
    ?assertEqual({2011, 1, 2}, event_date("monthly", 24, [2], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2013, 1, 2}, event_date("monthly", 24, [2], {2011, 1, 1}, {2011, 1, 2})),
    ?assertEqual({2011, 6, 2}, event_date("monthly", 24, [2], {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2013, 6, 2}, event_date("monthly", 24, [2], {2011, 6, 1}, {2011, 6, 2})),
    %% odd step (large)
    ?assertEqual({2011, 1, 2}, event_date("monthly", 37, [2], {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2014, 2, 2}, event_date("monthly", 37, [2], {2011, 1, 1}, {2011, 4, 2})),
    ?assertEqual({2011, 6, 2}, event_date("monthly", 37, [2], {2011, 6, 1}, {2011, 6, 1})),
    ?assertEqual({2014, 7, 2}, event_date("monthly", 37, [2], {2011, 6, 1}, {2011, 6, 2})),
    %% shift start date
    ?assertEqual({2011, 2, 2}, event_date("monthly", 3, [2], {2007, 5, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 3, 2}, event_date("monthly", 3, [2], {2008, 6, 2}, {2011, 1, 1})),
    ?assertEqual({2011, 1, 2}, event_date("monthly", 3, [2], {2009, 7, 3}, {2011, 1, 1})),
    ?assertEqual({2011, 2, 2}, event_date("monthly", 3, [2], {2010, 8, 4}, {2011, 1, 1})),
    %% long span
    ?assertEqual({2011, 4, 11}, event_date("monthly", 4, [11], {1983, 4, 11}, {2011, 1, 1})).

yearly_date_recurrence_test() ->
    %% basic increment
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {4, 11}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {4, 11}, {2011, 1, 1}, {2011, 2, 1})),
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {4, 11}, {2011, 1, 1}, {2011, 3, 1})),
    %% same month, before
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {4, 11}, {2011, 1, 1}, {2011, 4, 1})),   
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {4, 11}, {2011, 1, 1}, {2011, 4, 10})),
    %% increment over year boundary
    ?assertEqual({2012, 4, 11}, event_date("yearly", 1, {4, 11}, {2011, 1, 1}, {2011, 4, 11})),    
    %% leap year (into)
    ?assertEqual({2008, 2, 29}, event_date("yearly", 1, {2, 29}, {2008, 1, 1}, {2008, 2, 28})),
    %% leap year (over)
    ?assertEqual({2009, 2, 29}, event_date("yearly", 1, {2, 29}, {2008, 1, 1}, {2008, 2, 29})),
    %% shift start date (no impact)
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {4, 11}, {2008, 10, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {4, 11}, {2009, 11, 11}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {4, 11}, {2010, 12, 11}, {2011, 1, 1})),
    %% even step (small)
    ?assertEqual({2013, 4, 11}, event_date("yearly", 2, {4, 11}, {2011, 1, 1}, {2011, 4, 11})),
    ?assertEqual({2015, 4, 11}, event_date("yearly", 2, {4, 11}, {2011, 1, 1}, {2014, 4, 11})),
    %% odd step (small)
    ?assertEqual({2014, 4, 11}, event_date("yearly", 3, {4, 11}, {2011, 1, 1}, {2011, 4, 11})),
    ?assertEqual({2017, 4, 11}, event_date("yearly", 3, {4, 11}, {2011, 1, 1}, {2016, 4, 11})),
    %% shift start dates
    ?assertEqual({2013, 4, 11}, event_date("yearly", 5, {4, 11}, {2008, 10, 11}, {2011, 1, 1})),
    ?assertEqual({2014, 4, 11}, event_date("yearly", 5, {4, 11}, {2009, 11, 11}, {2011, 1, 1})),
    ?assertEqual({2015, 4, 11}, event_date("yearly", 5, {4, 11}, {2010, 12, 11}, {2011, 1, 1})),
    %% long span
    ?assertEqual({2013, 4, 11}, event_date("yearly", 5, {4, 11}, {1983, 4, 11}, {2011, 1, 1})). 

yearly_every_recurrence_test() ->
    ok.

yearly_last_recurrence_test() ->
    ok.

yearly_every_ordinal_recurrence_test() ->
    %% basic first
    ?assertEqual({2011, 4, 4}, event_date("yearly", 1, {first, monday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 5}, event_date("yearly", 1, {first, tuesday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 6}, event_date("yearly", 1, {first, wensday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 7}, event_date("yearly", 1, {first, thursday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 1}, event_date("yearly", 1, {first, friday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 2}, event_date("yearly", 1, {first, saturday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 3}, event_date("yearly", 1, {first, sunday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    %% basic second
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {second, monday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 12}, event_date("yearly", 1, {second, tuesday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 13}, event_date("yearly", 1, {second, wensday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 14}, event_date("yearly", 1, {second, thursday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 8}, event_date("yearly", 1, {second, friday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 9}, event_date("yearly", 1, {second, saturday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 10}, event_date("yearly", 1, {second, sunday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    %% basic third
    ?assertEqual({2011, 4, 18}, event_date("yearly", 1, {third, monday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 19}, event_date("yearly", 1, {third, tuesday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 20}, event_date("yearly", 1, {third, wensday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 21}, event_date("yearly", 1, {third, thursday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 15}, event_date("yearly", 1, {third, friday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 16}, event_date("yearly", 1, {third, saturday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 17}, event_date("yearly", 1, {third, sunday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    %% basic fourth
    ?assertEqual({2011, 4, 25}, event_date("yearly", 1, {fourth, monday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 26}, event_date("yearly", 1, {fourth, tuesday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 27}, event_date("yearly", 1, {fourth, wensday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 28}, event_date("yearly", 1, {fourth, thursday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 22}, event_date("yearly", 1, {fourth, friday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 23}, event_date("yearly", 1, {fourth, saturday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 24}, event_date("yearly", 1, {fourth, sunday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    %% basic fifth
    ?assertEqual({2012, 4, 30}, event_date("yearly", 1, {fifth, monday, 4}, {2011, 1, 1}, {2011, 1, 1})),
%%!!    ?assertEqual({2013, 4, 30}, event_date("yearly", 1, {fifth, tuesday, 4}, {2011, 1, 1}, {2011, 1, 1})),
%%!!    ?assertEqual({2014, 4, 30}, event_date("yearly", 1, {fifth, wensday, 4}, {2011, 1, 1}, {2011, 1, 1})),
%%!!    ?assertEqual({2015, 4, 28}, event_date("yearly", 1, {fifth, thursday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 29}, event_date("yearly", 1, {fifth, friday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 30}, event_date("yearly", 1, {fifth, saturday, 4}, {2011, 1, 1}, {2011, 1, 1})),
%%!!    ?assertEqual({2017, 4, 30}, event_date("yearly", 1, {fifth, sunday, 4}, {2011, 1, 1}, {2011, 1, 1})),
    %% same month, before 
    ?assertEqual({2011, 4, 4}, event_date("yearly", 1, {first, monday, 4}, {2011, 1, 1}, {2011, 4, 1})),
    ?assertEqual({2011, 4, 11}, event_date("yearly", 1, {second, monday, 4}, {2011, 1, 1}, {2011, 4, 10})),
    %% current date on (simple)
    ?assertEqual({2011, 4, 4}, event_date("yearly", 1, {first, monday, 4}, {2011, 1, 1}, {2011, 3, 11})),
    ?assertEqual({2012, 4, 2}, event_date("yearly", 1, {first, monday, 4}, {2011, 1, 1}, {2011, 4, 11})),
    %% current date after (simple)
    ?assertEqual({2012, 4, 2}, event_date("yearly", 1, {first, monday, 4}, {2011, 1, 1}, {2011, 6, 21})),
    %% shift start dates (no impact)
    ?assertEqual({2011, 4, 4}, event_date("yearly", 1, {first, monday, 4}, {2004, 1, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 12}, event_date("yearly", 1, {second, tuesday, 4}, {2005, 2, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 20}, event_date("yearly", 1, {third, wensday, 4}, {2006, 3, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 28}, event_date("yearly", 1, {fourth, thursday, 4}, {2007, 4, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 29}, event_date("yearly", 1, {fifth, friday, 4}, {2008, 5, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 2}, event_date("yearly", 1, {first, saturday, 4}, {2009, 6, 1}, {2011, 1, 1})),
    ?assertEqual({2011, 4, 10}, event_date("yearly", 1, {second, sunday, 4}, {2010, 7, 1}, {2011, 1, 1})),
    %% even step first (small)
    ?assertEqual({2013, 4, 1}, event_date("yearly", 2, {first, monday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 2}, event_date("yearly", 2, {first, tuesday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 3}, event_date("yearly", 2, {first, wensday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 4}, event_date("yearly", 2, {first, thursday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 5}, event_date("yearly", 2, {first, friday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 6}, event_date("yearly", 2, {first, saturday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 7}, event_date("yearly", 2, {first, sunday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    %% even step second (small)
    ?assertEqual({2013, 4, 8}, event_date("yearly", 2, {second, monday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 9}, event_date("yearly", 2, {second, tuesday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 10}, event_date("yearly", 2, {second, wensday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 11}, event_date("yearly", 2, {second, thursday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 12}, event_date("yearly", 2, {second, friday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 13}, event_date("yearly", 2, {second, saturday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 14}, event_date("yearly", 2, {second, sunday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    %% even step third (small)
    ?assertEqual({2013, 4, 15}, event_date("yearly", 2, {third, monday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 16}, event_date("yearly", 2, {third, tuesday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 17}, event_date("yearly", 2, {third, wensday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 18}, event_date("yearly", 2, {third, thursday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 19}, event_date("yearly", 2, {third, friday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 20}, event_date("yearly", 2, {third, saturday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 21}, event_date("yearly", 2, {third, sunday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    %% even step fourth (small)
    ?assertEqual({2013, 4, 22}, event_date("yearly", 2, {fourth, monday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 23}, event_date("yearly", 2, {fourth, tuesday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 24}, event_date("yearly", 2, {fourth, wensday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 25}, event_date("yearly", 2, {fourth, thursday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 26}, event_date("yearly", 2, {fourth, friday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 27}, event_date("yearly", 2, {fourth, saturday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 28}, event_date("yearly", 2, {fourth, sunday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    %% basic fifth (small)
    ?assertEqual({2013, 4, 29}, event_date("yearly", 2, {fifth, monday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ?assertEqual({2013, 4, 30}, event_date("yearly", 2, {fifth, tuesday, 4}, {2011, 1, 1}, {2011, 5, 1})),
%%!!    ?assertEqual({2014, 4, 30}, event_date("yearly", 2, {fifth, wensday, 4}, {2011, 1, 1}, {2011, 5, 1})),
%%!!    ?assertEqual({2015, 4, 28}, event_date("yearly", 2, {fifth, thursday, 4}, {2011, 1, 1}, {2011, 5, 1})),
%%!!    ?assertEqual({2013, 4, 29}, event_date("yearly", 2, {fifth, friday, 4}, {2011, 1, 1}, {2011, 5, 1})),
%%!!    ?assertEqual({2013, 4, 30}, event_date("yearly", 2, {fifth, saturday, 4}, {2011, 1, 1}, {2011, 5, 1})),
%%!!    ?assertEqual({2017, 4, 30}, event_date("yearly", 2, {fifth, sunday, 4}, {2011, 1, 1}, {2011, 5, 1})),
    ok. 

-endif.