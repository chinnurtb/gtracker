-module(gtracker_mnesia).

-behaviour(mds_gen_server).

-export([start/1, stop/0, on_start/1, on_stop/2, on_msg/3, on_amsg/2, on_info/2]).

-import(mds_utils, [get_param/2, get_param/3]).
-import(gtracker_common, [gen_dev_name/0, binary_to_hex/1, get_best_process/1]).

-include("common_defs.hrl").

-define(mod, {global, gtracker_db}).
-define(log_error(MethodName), log(error, "~s failed: ~p. Msg = ~p, State = ~p, Stack trace = ~p", [MethodName, Err,
         Msg, dump_state(State), erlang:get_stacktrace()])).
-define(def_triggers, {global, gtracker_triggers}).
-define(def_track_nodes, gt_tracks).
-record(state, {triggers = undef, track_nodes = undef}).

%=======================================================================================================================
%  public exports
%=======================================================================================================================
start(Opts) ->
   mds_gen_server:start(?mod, ?MODULE, Opts).

stop() ->
   mds_gen_server:stop(?mod).

%=======================================================================================================================
%  callbacks
%=======================================================================================================================
on_start(Opts) ->
   SelfOpts = get_param(self, Opts),
   Triggers = get_param(triggers, SelfOpts, ?def_triggers),
   TrackNodes = get_param(track_nodes, SelfOpts, ?def_track_nodes),
   crypto:start(),
   mnesia_start(),
   log(info, "Mnesia started."),
   {ok, #state{triggers = Triggers, track_nodes = TrackNodes}}.

on_stop(Reason, _State) ->
   crypto:stop(),
   mnesia:stop(),
   log(info, "Mnesia stopped."),
   log(info, "Stopped <~p>.", [Reason]),
   ok.

on_msg(stop, _From, State) ->
   {stop, normal, stopped, State};

on_msg(Msg = register, {Pid, _}, State) ->
   log(debug, "register. State: ~p", [dump_state(State)]),
   F = fun(Fun) ->
         DevName = gen_dev_name(),
         log(debug, "Device generated ~p.", [DevName]),
         case mnesia:dirty_read(device, DevName) of
            [] ->
               log(debug, "Store device ~p", [DevName]),
               Ref = binary_to_hex(erlang:md5(erlang:list_to_binary(DevName))),
               Device = #device
               {
                  name = DevName,
                  alias = DevName,
                  reference = Ref,
                  online = true,
                  links = #links{owner = Pid}
               },
               mnesia:dirty_write(Device),
               Device;
            [#device{name = DevName}] ->
               Fun(Fun)
         end
      end,
   try F(F) of
      Device ->
         {reply, Device, State}
   catch
      _:Err ->
         ?log_error("register/0"),
         {reply, error, State}
   end;

on_msg(Msg = {register, DevName}, {Pid, _}, State = #state{triggers = Triggers}) ->
   log(debug, "register(~p). State: ~p", [DevName, dump_state(State)]),
   F = fun() ->
      case mnesia:dirty_read(device, DevName) of
         [] ->
            {reply, no_such_device, State};
         [Device = #device{links = #links{owner = undef}, online = false}] ->
            NewDevice = activate_device(Device, Pid, Triggers),
            mnesia:dirty_write(NewDevice),
            {reply, NewDevice, State};
         [Device = #device{links = #links{owner = Owner}}] when is_pid(Owner) andalso (Pid == Owner) ->
            {reply, Device, State};
         [Device = #device{links = #links{owner = Owner}}] ->
            case rpc:call(erlang, is_process_alive, [node(Owner), Owner]) of
               true ->
                  {reply, already_registered, State};
               False ->
                  log(debug, "is_process_alive(~p): ~p", [Owner, False]),
                  NewDevice = activate_device(Device, Pid, Triggers),
                  mnesia:dirty_write(NewDevice),
                  {reply, NewDevice, State}
            end
      end
   end,
   try F()
   catch
      _:Err ->
        ?log_error("register/1"),
        {reply, error, State}
   end;

on_msg(Msg = {unregister, DevName}, {Pid, _}, State) ->
   log(debug, "unregister(~p). State: ~p", [DevName, dump_state(State)]),
   F = fun() ->
      case mnesia:dirty_read(device, DevName) of
         [] ->
            {reply, no_such_device, State};
         [#device{links = #links{owner = undef}, online = false}] ->
            {reply, unregistered, State};
         [Device = #device{links = #links{owner = Owner}}] when is_pid(Owner) andalso (Pid == Owner) ->
            mnesia:dirty_write(Device#device{links = #links{}, online = false}),
            {reply, unregistered, State};
         [Device = #device{links = #links{owner = Owner}}] ->
            case rpc:call(erlang, is_process_alive, [node(Owner), Owner]) of
               true ->
                  {reply, wrong_owner, State};
               False ->
                  log(debug, "is_process_alive(~p): ~p", [Owner, False]),
                  mnesia:dirty_write(Device#device{links = #links{}, online = false}),
                  {reply, unregistered, State}
            end
         end
      end,
   try F()
   catch
      _:Err ->
         ?log_error("unregister/1"),
         {reply, error, State}
   end;

on_msg(Msg = {new_user, UserName, Password}, _From, State) ->
   log(debug, "new_user(~p, ~p). State: ~p", [UserName, Password, dump_state(State)]),
   F = fun() ->
      case mnesia:dirty_read(user, UserName) of
         [] ->
            User = #user{name = UserName, password = erlang:md5(Password)},
            mnesia:dirty_write(User),
            {reply, User, State};
         _User ->
            {reply, already_exists, State}
         end
      end,
   try F()
   catch
      _:Err ->
         ?log_error("new_user/2"),
         {reply, error, State}
   end;

on_msg(Msg = {update_user, UserName, Cfg = {Password, MapType, IsAdmin}}, _From, State) ->
   log(debug, "update_user(~p, ~p). State: ~p", [UserName, Cfg, dump_state(State)]),
   F = fun() ->
      case mnesia:dirty_read(user, UserName) of
         [] ->
            {reply, no_such_user, State};
         [User] ->
            NewUser = User#user{password = erlang:md5(Password), map_type = MapType, is_admin = IsAdmin},
            mnesia:dirty_write(NewUser),
            {reply, NewUser, State}
         end
      end,
   try F()
   catch
      _:Err ->
         ?log_error("new_user/2"),
         {reply, error, State}
   end;

on_msg(Msg = {login, UserName, Password}, _From, State) ->
   log(debug, "login(~p, ~p). State: ~p", [UserName, Password, dump_state(State)]),
   F = fun() ->
      case mnesia:dirty_read(user, UserName) of
         [] ->
            {reply, rejected, State};
         [User = #user{name = U, password = P}] ->
            case (U == UserName) andalso (P == erlang:md5(Password)) of
               true ->
                  OnlineUser = User#user{online = true},
                  mnesia:dirty_write(OnlineUser),
                  {reply, OnlineUser, State};
               false ->
                  {reply, rejected, State}
            end
      end
   end,
   try F()
   catch
      _:Err ->
         ?log_error("login/2"),
         {reply, error, State}
   end;
on_msg(Msg = {logout, UserName}, _From, State) ->
   log(debug, "logout(~p). State: ~p", [UserName, dump_state(State)]),
   F = fun() ->
      case mnesia:dirty_read(user, UserName) of
         [] ->
            {reply, rejected, State};
         [User = #user{name = UserName}] ->
            mnesia:dirty_write(User#user{online = false}),
            {reply, ok, State}
      end
   end,
   try F()
   catch
      _:Err ->
         ?log_error("logout/2"),
         {reply, error, State}
   end;

on_msg(Msg = get_all_devices, _From, State) ->
   log(debug, "get_all_devices. State: ~p", [dump_state(State)]),
   try mnesia:dirty_select(device, [{'_', [], ['$_']}]) of
      Devices ->
         {reply, Devices, State}
   catch
      _:Err ->
         ?log_error("get_all_devices"),
         {reply, error, State}
   end;

on_msg(Msg = {get_device, DevName}, _From, State) ->
   log(debug, "get_all_devices. State: ~p", [dump_state(State)]),
   try mnesia:dirty_read(device, DevName) of
      [] ->
         {reply, no_such_device, State};
      [Device] ->
         {reply, Device, State}
   catch
      _:Err ->
         ?log_error("get_all_devices"),
         {reply, error, State}
   end;

on_msg(Msg = {update_device, DevName, Cfg = {Alias, Timezone, Color, Weight, Pixmap, TwitterAuth}}, _From, State) ->
   log(debug, "update_device(~p, ~p). State: ~p", [DevName, Cfg, dump_state(State)]),
   try mnesia:dirty_read(device, DevName) of
      [] ->
         {reply, no_such_device, State};
      [Device] ->
         NewDevice = Device#device{alias = Alias, timezone = Timezone, color = Color, weight = Weight, pixmap =
               Pixmap, twitter_auth = TwitterAuth},
         mnesia:dirty_write(NewDevice),
         {reply, NewDevice, State}
   catch
      _:Err ->
         ?log_error("update_device/2"),
         {reply, error, State}
   end;

on_msg(Msg = {get_tracks, DevName}, _From, State) ->
   log(debug, "get_tracks(~p). State: ~p", [DevName, dump_state(State)]),
   try mnesia:dirty_read(tracks, DevName) of
      Tracks ->
         {reply, Tracks, State}
   catch
      _:Err ->
         ?log_error("get_tracks/1"),
         {reply, error, State}
   end;

on_msg(Msg = {get_triggers, DevName}, _From, State) ->
  try mnesia:dirty_read(triggers, DevName) of
      Triggers ->
        {reply, Triggers, State}
   catch
      _:Err ->
         ?log_error("get_triggers/1"),
         {reply, error, State}
  end;

on_msg(Msg = {get_news, UpToDate}, _From, State) ->
   log(debug, "get_news(~p). State: ~p", [UpToDate, dump_state(State)]),
   F = fun() ->
         Date = if (UpToDate == undef) -> {2100, 1, 1}; true -> UpToDate end,
         case calendar:valid_date(Date) of
            true ->
               mnesia:dirty_select(news, [{#news{date = '$1', _='_'}, [{'=<', '$1', {Date}}], ['$_']}]);
            false ->
               invalid_date
         end
      end,
   try F() of
      Result ->
         {reply, Result, State}
   catch
      _:Err ->
         ?log_error("get_news/1"),
         {reply, error, State}
   end;

on_msg(Msg = {insert_news, Date, Text}, _From, State) ->
   log(debug, "insert_news(~p, ~p). State: ~p", [Date, Text, dump_state(State)]),
   NewsRef = erlang:make_ref(),
   try mnesia:dirty_write(#news{id = NewsRef, date = Date, text = Text}) of
      ok ->
         {reply, NewsRef, State}
   catch
      _:Err ->
         ?log_error("insert_news/2"),
         {reply, error, State}
   end;

on_msg(Msg = {delete_news, NewsRef}, _From, State) ->
   log(debug, "delete_news(~p). State: ~p", [NewsRef, dump_state(State)]),
   try mnesia:dirty_delete(news, NewsRef) of
      ok ->
         {reply, ok, State}
   catch
      _:Err ->
         ?log_error("delete_news/1"),
         {reply, error, State}
   end;

%on_msg(Msg = {new_track, DevName}, _From, State = #state{track_nodes = TN}) ->
%   log(debug, "new_track(~p). State: ~p", [DevName, dump_state(State)]),
%   F = fun() ->
%         case mnesia:dirty_read(devices, DevName) of
%            [] ->
%               {reply, no_such_device, State};
%            [Device = #device{links = #links{track = TrackPid}}] when is_pid(TrackPid) ->
%               case is_process_alive(node(TrackPid), TrackPid) of
%                  true ->
%                     {reply, TrackPid, State};
%                  false ->
%                     TrackPid = create_track(Device, TN),
%                     % create new track here
%                     {reply, TrackPid, State}
%               end;
%            [Device = #device{links = #links{track = undef}}] ->
%               % create new track here
%               TrackPid = create_track(Device, TN),
%               {reply, TrackPid, State}
%         end
%      end,
%   try F()
%   catch
%      _:err ->
%         ?log_error("new_track/1"),
%         {reply, error, State}
%   end.

on_msg(Msg, _From, State) ->
   log(error, "Unknown sync message ~p.", [Msg]),
   {noreply, State}.

on_amsg(Msg, State) ->
   log(error, "Unknown async message ~p.", [Msg]),
   {noreply, State}.

on_info(Msg, State) ->
   log(error, "Unknown info message ~p.", [Msg]),
   {noreply, State}.

%=======================================================================================================================
%  log helpers
%=======================================================================================================================
log(LogLevel, Format, Data) ->
   mds_gen_server:log(?MODULE, LogLevel, Format, Data).

log(LogLevel, Text) ->
   mds_gen_server:log(?MODULE, LogLevel, Text).

%=======================================================================================================================
%  tools
%=======================================================================================================================
-define(create_table(Table),
   case (catch mnesia:table_info(Table, version)) of
      {'EXIT', {aborted, {no_exists, Table, _}}} ->
         mnesia:create_table(
            Table, [{disc_copies, [node()]}, {type, ordered_set}, {attributes, record_info(fields, Table)}]);
      _ ->
         ok
   end).

mnesia_start() ->
   mnesia:create_schema([]),
   mnesia:start(),
   ?create_table(device),
   ?create_table(trigger),
   ?create_table(user),
   ?create_table(news).

dump_state(State) ->
   State.

get_trigger_process(DevName, Triggers) ->
   case mnesia:dirty_read(trigger, DevName) of
      [] ->
         undef;
      _ ->
         get_best_process(Triggers)
   end.

activate_device(Device = #device{name = DevName, links = Links}, Owner, Triggers) ->
   Device#device
   {
      links = Links#links{owner = Owner, trigger = get_trigger_process(DevName, Triggers)},
      online = true,
      registered_at = now()
   }.

%create_track(Device = #device{name = DevName, owner = Owner, links = L}, TrackNodes) ->
%   BestNode = bn, % get best node,
%   Count = length(mnesia:dirty_read(tracks, DevName))
%   TrackName = lists:flatten(io_lib:format("~s_~p", [DevName, Count])),
%   TrackPid = gtracker_track:start(BestNode, TrackName, Owner, ?track_path),
%   mnesia:dirty_write(#track{})
%   mnesia:dirty_write(Device#device{links = L#links{track = TrackPid}}),

%=======================================================================================================================
%  unit testing facilities
%=======================================================================================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

get_device_test() ->
   ok.
   %Pid = gtracker_edb:start([]),
   %timer:sleep(100),
   %{DevName, _} = gen_server:call(?mod, get_device),
   %Device = gen_server:call(?mod, {get_device, DevName}),
   %?assertEqual(DevName, Device#device.name).

-endif.