class Room
  struct Video
    getter platform
    getter id
    property offset

    def initialize(@platform : String, @id : String, @offset = 0.0)
    end

    def args
      {platform, id, offset}
    end
  end

  class WS
    property? authed

    def initialize(@ws : HTTP::WebSocket, @is_host = false)
      @authed = false
      @channel = Channel(String).new(5)
      @ws.on_message(&->handle_message(String))
      @ws.on_close(&->handle_close(HTTP::WebSocket::CloseCode, String))
      @last_heartbeat = Time.monotonic
      spawn_loop
    end

    def spawn_loop
      spawn do
        while message = @channel.receive?
          @ws.send message
        end
      end
    end

    def heartbeat
      @last_heartbeat = Time.monotonic
    end

    def on_message(&@on_message : String ->) # set on message handler
    end

    def handle_message(message : String)
      case message
      when "heartbeat"
        heartbeat
        send "heartbeat"
      else
        @on_message.try &.call(message)
      end
    end

    def handle_close(code : HTTP::WebSocket::CloseCode, reason : String)
      @channel.close
    end

    def send(cmd, *args)
      @channel.send("#{cmd},#{args.join(',')}") unless closed?
    end

    def host?
      @is_host
    end

    def client?
      !@is_host
    end

    def purge?
      return true if closed?
      if timeout?
        close "timeout"
        return true
      end
      return false
    end

    def timeout?
      if host? && !authed? # host should auth within 15s
        Time.monotonic - @last_heartbeat > 15.seconds
      else
        Time.monotonic - @last_heartbeat > 1.minute
      end
    end

    def closed?
      @channel.closed?
    end

    def close(message : String?)
      @ws.close(message: message) unless @ws.closed?
      @channel.close unless @channel.closed?
    end
  end

  getter id # party id
  getter key # host key
  getter? persist

  getter video : Video?
  getter? video_paused : Bool
  getter stream : Video?

  getter? closed

  @host : WS?

  def initialize(@id : String, @key : String, @persist = false)
    @clients = [] of WS
    @closed = false
    @last_update = Time.monotonic
    @video_paused = false
  end

  def update_key(key)
    @key = key if persist? # only persist room's key is changable
  end

  def status
    {!@host.nil?, @clients.size}
  end

  def mark_update
    @last_update = Time.monotonic
  end

  def timeout_check
    @clients.reject! do |ws|
      ws.purge?
    end
    @host.try do |host|
      @host = nil if host.purge?
    end
    if !persist? && Time.monotonic - @last_update > 1.hour
      close
    end
  end

  def close
    @closed = true
    @clients.each do |ws|
      ws.close "room close"
    end
    @host.try &.close "room close"
  end

  def client_join(raw_ws : HTTP::WebSocket)
    return if closed?
    ws = WS.new(raw_ws)
    if @stream
      ws.send "stream", *@stream.not_nil!.args
    end
    if @video
      ws.send "video", *@video.not_nil!.args
      if video_paused?
        ws.send "pause"
      else
        ws.send "play"
      end
    end
    @clients << ws
  end

  def host_join(raw_ws : HTTP::WebSocket)
    return if closed?
    @host.try &.close "another host joined"
    @host = host = WS.new(raw_ws, true)
    host.on_message(&->handle_host_message(String))
  end

  def handle_host_message(message : String)
    host = @host.not_nil!
    args = message.split(',')
    cmd = args.shift
    if host.authed?
      mark_update
      case cmd
      when "sync"
        if @video
          @video.not_nil!.offset = time = args.first.to_f
          client_streamfix_send "sync", time
        end
      when "pause"
        if @video
          @video_paused = true
          client_streamfix_send "pause"
        end
      when "play"
        if @video
          @video_paused = false
          client_streamfix_send "play"
        end
      when "stream_sync"
        if @stream
          @stream.not_nil!.offset = time = args.first.to_f
        end
      when "stream"
        if args.size >= 3
          platform, id, offset = args
          if platform.empty? || id.empty?
            @stream = nil
            client_send "stream", "", "", 0.0
          else
            @stream = stream = Video.new(platform, id, offset.to_f)
            client_send "stream", *stream.args
          end
        end
      when "video"
        if args.size >= 3
          platform, id, offset = args
          if platform.empty? || id.empty?
            @video = nil
            client_streamfix_send "video", "", "", 0.0
          else
            @video = video = Video.new(platform, id, offset.to_f)
            client_streamfix_send "video", *video.args
          end
        end
      when "close"
        if persist? # clear video and stream for persist room
          @video = nil
          client_streamfix_send "video", "", "", 0.0
          @stream = nil
          client_send "stream", "", "", 0.0
        else # otherwise, just close it
          close
        end
      end
    else
      if cmd == "auth" && !args.empty? && @key == args.first
        host.authed = true
        host.send "authed"
      else
        host.close "auth failed"
      end
    end
  end

  def client_send(cmd, *args)
    @clients.each do |ws|
      ws.send(cmd, *args)
    end
  end

  def client_streamfix_send(cmd, *args)
    if @stream
      client_send("stream_fix##{@stream.not_nil!.offset}##{cmd}", *args)
    else
      client_send(cmd, *args)
    end
  end
end

