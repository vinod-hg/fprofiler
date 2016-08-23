%#!/usr/bin/env escript
%% @author vinod
%% @doc Web based reporting for fprof


-module(fprofiler).

-export([main/1]).
-export([parse/0,
         parse/1]).

%% ====================================================================
%% API functions
%% ====================================================================
main([]) ->
    parse();
main([M, F, A]) ->
    {ok, Tracer} = fprof:profile(start),
    fprof:trace([start, {tracer, Tracer}]),
    apply(M, F, A),
    fprof:trace(stop),
    fprof:analyse(dest, []),
    parse();
main([Name]) ->
    parse(Name).

parse() ->
    parse("fprof.analysis").

parse(FileName) ->
    {ok, Terms} = file:consult(FileName),
    NewTerms = parse_initial(Terms, []),
    write_html(FileName, NewTerms),
    NewTerms.


%% ====================================================================
%% Internal functions
%% ====================================================================

parse_initial([{analysis_options, _Opt} | Rest], State) ->
    parse_initial(Rest, State);
parse_initial([[{totals, _Cnt, _Acc, _Own}] | Rest], State) ->
    parse_initial(Rest, State);
parse_initial([[{Pid, _Cnt, _Acc, _Own} | _T] | Rest], State) when is_list(Pid) ->
    parse_terms(Rest, State).

parse_terms([], State) ->
    merge(lists:reverse(State), true);
parse_terms([{[{undefined, _, _, _} | _], _, _} | Rest], State) ->
    parse_terms(Rest, State);
parse_terms([{_CallingList, {Func, Cnt, _Acc, _Own} = Entry, []} | Rest], State) ->
    parse_terms(Rest, [{get_func(Func), Cnt, actual_time(Entry), []} | State]);
parse_terms([{_CallingList, {Func, Cnt, _Acc, _Own} = Entry, CalledList} | Rest], State) ->
    {Fun, Count, Time} = get_val(Entry),
    FlatCalledList = [begin {CalledF, CalledC, CalledT} = get_val(Called),
                            {CalledF, CalledC, CalledT, []} end || Called <- CalledList],
    parse_terms(Rest, [{Fun, Count, Time, [{{self, get_func(Func)}, Cnt, actual_time(Entry), []}
                        | FlatCalledList]} | State]).

actual_time({suspend, _Cnt, Acc, _Own}) ->
    trunc(Acc * 1000);
actual_time({_Func, _Cnt, _Acc, Own}) ->
    trunc(Own * 1000).

get_val({Fun, Count, _,_}) ->
    {get_func(Fun), Count, 0};
get_val({Fun, Count, Time}) ->
    {Fun, Count, Time}.

get_func({M, F, A}) ->
    list_to_atom(lists:concat([M, ":", F, "/", A]));
get_func(Func) ->
    Func.

-define(DEBUG(Format, Args), io:format(Format, Args)).

merge([Head | Data], true) ->
    {NewData, NewMergedFlag} =
        lists:foldl(fun(Entry, {Acc0, MergedFlag}) ->
    case merge([Entry], Acc0, false) of
        {_, false} ->
    {Acc0 ++[Entry], MergedFlag or false};
        {Acc1, true} ->
            {Acc1, true}
    end
                    end, {[Head], false}, Data),
merge(NewData, NewMergedFlag);
merge(Data, false) ->
    Data.

merge(_Entry, [], false) ->
    {[], false};
merge([], Data, Match) ->
    {Data, Match};
merge([{Key, Cnt, Time, Childs}], [{Key, DataCnt, DataTime, DataChilds} | Rest], _) ->
    case merge(Childs, DataChilds, false) of
        {_, false} ->
    {[{Key, max(Cnt, DataCnt), max(Time, DataTime), DataChilds ++ Childs} | Rest], true};
        {NewData, true} ->
            {[{Key, max(Cnt, DataCnt), max(Time, DataTime), NewData} | Rest], true}
    end;
merge(Entry, [{Key, DataCnt, DataTime, DataChilds} | Rest], false) ->
    case merge(Entry, DataChilds, false) of
        {_, false} ->
            {NewData, Match} = merge(Entry, Rest, false),
            {[{Key, DataCnt, DataTime, DataChilds} | NewData], true};
        {NewData, true} ->
            {[{Key, DataCnt, DataTime, NewData} | Rest], true}
    end;
merge(Entry, Data, true) ->
    {Data ++ Entry, true}.

log(FileTo, Parent, Children, Map) ->
    lists:foldl(fun(Child, AccMap) ->
                        log2(FileTo, Parent, Child, AccMap)
                end, Map, Children).

log2(FileTo, Parent, {Node, Count, Time, Children}, Map) ->
    case maps:find(Node, Map) of
        error ->
            write(FileTo, Parent, Node, Count, Time, Children),
            log(FileTo, Node, Children, maps:put(Node, 1, Map));
        {ok, Value} ->
            NewNode = {Node, {call, Value + 1}},
            write(FileTo, Parent, NewNode, Count, Time, Children),
            log(FileTo, NewNode, Children, maps:put(Node, Value + 1, Map))
    end.

write(FileTo, Parent, Node, Count, Time, Children) ->
    io:format(FileTo, "['~s', ]" ++ get_parent(Parent) ++ ", ~p, ~p, [", [thing_to_list(Node), Count, Time]),
    [io:format(FileTo, "['~s', ~p, ~p],", [thing_to_list(CNode), CCount, CTime]) || {CNode, CCount, CTime, _} <- Children],
    io:format(FileTo, "]],~n", []).

get_parent(null) ->
    "null";
get_parent(Parent) ->
    "'" ++ thing_to_list(Parent) ++ "'".

aggregate([]) ->
    {[], 0};
aggregate([ {Node, Count, Time, Children} | Data]) ->
    {NewChildren, AccTime} = aggregate(Children),
    {NewData, NewTime} = aggregate(Data),
    {[{Node, Count, Time + AccTime, NewChildren} | NewData], Time + AccTime + NewTime}.

thing_to_list(X) when is_integer(X) -> integer_to_list(X);
thing_to_list(X) when is_float(X) -> float_to_list(X);
thing_to_list(X) when is_atom(X) -> atom_to_list(X);
thing_to_list(X) when is_list(X) -> X;      % Assumed to be a string
thing_to_list(X) when is_tuple(X) -> lists:flatten(io_lib:format("~p", [list_to_tuple([thing_to_list(T) || T <- tuple_to_list(X)])])).

write_html(FileNameIn, Terms0) ->
    {Terms, _} = aggregate([{total, 1, 0, Terms0}]),
    Output = string:substr(FileNameIn, 1, string:rchr(FileNameIn, $.)) ++ "html",
{ok, FileTo} = file:open(Output, [write]),
    io:format(FileTo, "~s~n", [html_begin()]),
    log(FileTo, null, Terms, #{}),
    io:format(FileTo, "~s~n", [html_end()]),
    file:close(FileTo).

html_begin() ->
"<html>
  <head>
    <script type =\"text/javascript\" src=\"https://www.gstatic.com/charts/loader.js\"></script>
    <script type =\"text/javascript\">
      google.charts.load('current', {'package':['treemap']});
      google.charts.seetOnLoadCallback(drawChart);
      function drawChart() {
        var tree_data = [
          ['Function', 'Parent', 'Time Spent (Microseconds)', 'Time inrease/decrease (Color)']];
        var raw_data = [".

html_end() ->
   "];

    var i = 0;
    var len = raw_data.length;
    for (i = 0; i < len; i++) {
        tree_data.push([raw_data[i][0], raw_data[i][1], raw_data[i][3], raw_data[i][3]])
    }
    var data = google.visualization.arrayToDataTable(tree_data);
    tree = new google.visualization.TreeMap(document.getElementById('chart_div'));

    var options = {
      highlightOnMouseOver: true,
      maxDept: 1,
      maxPosDept: 2,
      //minHighlightColor: '#8c6bb1',
      //maxhighlightColor: '#9ebcda',
      //minColor: '#009688',
      //midColor: 'f7f7f7',
      //maxColor: '#ee8100',
      headerHeight: 20,
      showScale: false,
      height: 500,
      useWeightedAverageForAggregation: true,
      generateTooltip: showFullTooltip
    };
    tree.draw(data, options);
    google.visualization.events.addListener(tree, 'select', onRowSelect');
    google.visualization.events.addListener(tree, 'rollup', treeRollup);
    select(0);

    function showFullTooltip(row, siz, value) {
      return '<div stype=\"bacground:#fd9; padding:10px; border-style:solid\">
                <span style=\"font-family:Courier\">' +
                data.getColumnLabel(0) + ': ' + '<b>' + data.getValue(row, 0) + '</b><br>' +
                data.getColumnLabel(2) + ': ' + '<b>' + size + '</b></span></div>';
            //'<br>' + data.getColumnLabel(3) + ':' + value + ' </div>';
    }
    function treeRollup(row) {
      onRowSelect();
    }
    function OnRowSelect() {
      var selection = tree.getSelection();
      select([selection[0].row]);
    }
    function select(row) {
      var elem = raw_data[raw];
      var message =
        '<table style=\"width:100%\"><caption><b>Call Details</b></caption>' + 
          '<tr><th width=63%>Function</th><th width=12%>Count</th><th width=25%>Time Pent (MilliSeconds)</th></tr>' + 
          '<tr><td><b>' + elem[0] + '</b></td><td><b>' + elem[2] + '</b></td><td><b>' + elem[3]/1000 + '</b></td></tr>';
        for(var i=0; i <  elem[4].length; i++) {
          message += get_td(elem[4][i][0], elem[4][i][1], elem[4][i][2]/1000);
        }
        message += '</table>';
        document.getElementById('data_div').innerHTML = message; 
    }
    function get_td(func, count, time) {
        return '<tr><td>' + func + '</td><td>' + count + '</td><td>' + time + '</td></tr>';
    }
    </script>
    <style>
       table {
          table-layout: fixed;
          word-wrap: break-word;}
       table, th, td {
           font-size: 11pt;
           border: 1px solid black;
       }
       th, td {
           padding: 5px;
           text-align: left;
       }
       </style>
    </head>
    <body>
      <div id=\"data_div\" style=\"float:left; width: 35%; height: auto; min-height: 96%; background:#fd9; padding:1% border-style:solid; \"></div>
      <div id= \"chart_div\" style=\"float:right; width: 61%; height: auto; \"></div>
    </body>
</html>".
