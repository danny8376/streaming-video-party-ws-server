require "kemal"

require "./room"

rooms = Hash(String, Room).new

before_all do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
end

options "/*" do |env|
  env.response.headers["Allow"] = "HEAD,GET,PUT,POST,DELETE,OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "X-Requested-With, X-HTTP-Method-Override, Content-Type, Cache-Control, Accept, X-Room-Key"
  env.response.headers["Access-Control-Allow-Origin"] = "*"

  halt env, 204
end

get "/" do |env|
  "Streaming Video Party WS Server!"
end

get "/room/:id" do |env| # check room existence
  room_id = env.params.url["id"]
  room_key = env.request.headers["X-Room-Key"]?
  if rooms.has_key?(room_id)
    if room_key.nil? || rooms[room_id].key == room_key
      env.response.status_code = 302
      "Room #{room_id} exist"
    else
      env.response.status_code = 403
      "Room #{room_id} exist, but given key isn't corrent"
    end
  else
    env.response.status_code = 404
    "room not found"
  end
end

# TODO: rate limit ? should be fine now ?
post "/room/:id" do |env| # create party room
  room_id = env.params.url["id"]
  room_key = env.params.body["key"]? || env.request.headers["X-Room-Key"]?

  if room_key.nil? || room_key.not_nil!.empty?
    halt env, 400, "key (room key) is required"
  end
  if rooms.has_key?(room_id)
    halt env, 400, "id exists"
  end

  rooms[room_id] = Room.new(room_id, room_key)

  env.response.status_code = 201
  "Room #{room_id} created"
end

delete "/room/:id" do |env| # force close party room
  room_id = env.params.url["id"]
  room_key = env.params.body["key"]? || env.request.headers["X-Room-Key"]?

  if room_key.nil? || room_key.not_nil!.empty?
    halt env, 400, "key (room key) is required"
  end

  if rooms.has_key?(room_id)
    if rooms[room_id].key == room_key
      rooms[room_id].close

      env.response.status_code = 200
      "Room #{room_id} closed"
    else
      env.response.status_code = 403
      "Room #{room_id} exist, but given key isn't corrent"
    end
  else
    env.response.status_code = 404
    "room not found"
  end
end

ws "/ws/room/:id" do |ws, env| # client
  room_id = env.ws_route_lookup.params["id"]
  room = rooms[room_id]?
  unless room
    halt env, 404, "room not found"
  end
  room.not_nil!.client_join ws
end

ws "/ws/party-host/:id" do |ws, env| # host
  room_id = env.ws_route_lookup.params["id"]
  room = rooms[room_id]?
  unless room
    halt env, 404, "room not found"
  end
  room.not_nil!.host_join ws
end

spawn do # timeout checking fiber
  loop do
    rooms.reject! do |id, room|
      if room.closed?
        true
      else
        room.timeout_check
        Fiber.yield # give time to run other things
        room.closed?
      end
    end

    sleep 5.seconds # check every 5s
  end
end

# TODO: move this to config
Kemal.run do |config|
  config.server.not_nil!.bind_unix "socket.sock"
  File.chmod("socket.sock", 0o777)
end
