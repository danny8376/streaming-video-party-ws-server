require "kemal"

require "./room"
require "./config"
require "./jwt"

struct Config
  @@conf = Config.from_yaml(File.read("./config.yml.example"))
  def self.load(yaml = File.read("./config.yml"))
    @@conf = Config.from_yaml yaml
  end
  def self.conf
    @@conf
  end
end
Config.load

rooms = Hash(String, Room).new

def masterauth?(env, room_id, command)
  conf = Config.conf.masterauth
  return false if conf.passphrase.empty?
  return false if env.request.headers["X-Master-PassPhrase"]? != conf.passphrase
  token_nil = env.request.headers["X-Master-Token"]?
  return false if token_nil.nil?
  token, header = MasterToken.from_jwt token_nil.not_nil!, conf.keys
  return false if token.iat.nil? || token.exp.nil?
  return false if token.exp.not_nil! - token.iat.not_nil! > 10.minute
  return {room_id, command} == {token.room_id, token.command}
rescue JWT::Error
  return false
end

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

get "/rooms" do |env|
  unless masterauth?(env, "__LIST__", "get")
    halt env, 404
  end
  env.response.content_type = "application/json"
  JSON.build do |json|
    json.object do
      json.field "rooms" do
        json.array do
          rooms.each do |id, room|
            json.object do
              json.field "id", room.id
              json.field "persist", room.persist?
              has_host, client_count = room.status
              json.field "has_host", has_host
              json.field "client_count", client_count
              room.video.try do |v|
                json.field "video" do
                  json.object do
                    platform, id, offset = v.args
                    json.field "platform", platform
                    json.field "id", id
                    json.field "offset", offset
                    json.field "paused", room.video_paused?
                  end
                end
              end
              room.stream.try do |s|
                json.field "stream" do
                  json.object do
                    platform, id, offset = s.args
                    json.field "platform", platform
                    json.field "id", id
                    json.field "offset", offset
                  end
                end
              end
            end
          end
        end
      end
    end
  end
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
  persist = env.params.query.has_key? "persist"

  if room_key.nil? || room_key.not_nil!.empty?
    halt env, 400, "key (room key) is required"
  end
  if rooms.has_key?(room_id)
    halt env, 400, "id exists"
  end

  persist = masterauth?(env, room_id, "post") if persist
  rooms[room_id] = Room.new(room_id, room_key, persist)

  env.response.status_code = 201
  "Room #{room_id} created"
end

patch "/room/:id" do |env| # for updating room key
  room_id = env.params.url["id"]
  room_key = env.params.body["key"]? || env.request.headers["X-Room-Key"]?
  unless masterauth?(env, room_id, "patch")
    halt env, 403, "wrong key"
  end
  room_key = env.params.body["key"]? || env.request.headers["X-Room-Key"]?
  if room_key.nil? || room_key.not_nil!.empty?
    halt env, 400, "key (room key) is required"
  end
  unless rooms.has_key?(room_id)
    halt env, 404, "room not found"
  end

  room = rooms[room_id]
  unless room.persist?
    halt env, 403, "key is only updatable for persist room"
  end
  rooms[room_id].update_key room_key.not_nil!

  env.response.status_code = 200
  "Key of room #{room_id} updated"
end

delete "/room/:id" do |env| # force close party room
  room_id = env.params.url["id"]
  room_key = env.params.body["key"]? || env.request.headers["X-Room-Key"]?
  master = masterauth?(env, room_id, "delete")

  if !master && (room_key.nil? || room_key.not_nil!.empty?)
    halt env, 400, "key (room key) is required"
  end

  if rooms.has_key?(room_id)
    if master || rooms[room_id].key == room_key
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

Signal::HUP.trap do
  puts "Recived HUP, reloading config (only affect master auth part)"
  Config.load
end

Kemal.run do |config|
  bind = Config.conf.bind
  server = config.server.not_nil!

  if bind.unix.empty?
    server.bind_tcp bind.host, bind.port
  else
    server.bind_unix bind.unix
    File.chmod(bind.unix, bind.perm)
  end
end
