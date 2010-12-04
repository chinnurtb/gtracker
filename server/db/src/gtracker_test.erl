-module(gtracker_test).

-include_lib("eunit/include/eunit.hrl").

-include("common_recs.hrl").

start_test() ->
   application:start(gtracker_db).

device_get_all_devices_test() ->
   ?assertEqual([], gtracker_db_pub:get_all_devices()).

device_register_device_test() ->
   Device = gtracker_db_pub:register(),
   ?assertEqual(true, Device#device.online),
   ?assertEqual(self(), Device#device.links#links.owner),
   ?assertEqual(Device, gtracker_db_pub:register(Device#device.name)),
   Device1 = gtracker_db_pub:unregister(Device#device.name),
   ?assertEqual(false, Device1#device.online),
   ?assertEqual(undef, Device1#device.links#links.owner),
   ?assertEqual(no_such_device, gtracker_db_pub:register("QWERTYASDFQW")).

device_get_all_devices2_test() ->
   Devices = gtracker_db_pub:get_all_devices(),
   ?assertEqual(true, is_list(Devices)),
   ?assertEqual(1, length(Devices)),
   ?assertEqual(true, is_record(hd(Devices), device)).

get_device_test() ->
   [Device = #device{name = Name, online = O}] = gtracker_db_pub:get_all_devices(),
   Device1 = gtracker_db_pub:get_device(Name),
   ?assertEqual(Device, Device1),
   ?assertEqual(false, O),
   ?assertMatch(#device{online = true}, gtracker_db_pub:register(Name)),
   ?assertMatch(#device{online = false}, gtracker_db_pub:unregister(Name)).

update_device_test() ->
   [#device{name = Name}] = gtracker_db_pub:get_all_devices(),
   Device = gtracker_db_pub:get_device(Name),
   gtracker_db_pub:update_device(Device#device{alias = "TEST_ALIAS"}).

device_user_test() ->
   User = gtracker_db_pub:new_user("dmitryme@gmail.com", "123"),
   ?assertMatch(#user{name = "dmitryme@gmail.com", online = false, map_type = 0, is_admin = false, devices = []}, User),
   ?assertEqual(already_exists, gtracker_db_pub:new_user("dmitryme@gmail.com", "321")),
   User1 = gtracker_db_pub:update_user(User#user{is_admin = true, map_type = 1, devices = ["DMITRYME_!@#"]}),
   ?assertMatch(#user{name = "dmitryme@gmail.com", map_type = 1, is_admin = true, devices = ["DMITRYME_!@#"]}, User1),
   ?assertEqual(User1, gtracker_db_pub:get_user("dmitryme@gmail.com")),
   ?assertEqual(not_found, gtracker_db_pub:get_user("dmitryme")),
   ?assertMatch(#user{name = "dmitryme@gmail.com", online = true}, gtracker_db_pub:authenticate("dmitryme@gmail.com", "123")),
   ?assertEqual(rejected, gtracker_db_pub:authenticate("dmitryme", "123")),
   ?assertEqual(rejected, gtracker_db_pub:authenticate("dmitryme@gmail.com", "1234")),
   ok.

stop_test() ->
   application:stop(gtracker_db).