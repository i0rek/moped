module Moped

  # @api private
  #
  # The internal class wrapping a socket connection.
  class Socket

    # Thread-safe atomic integer.
    class RequestId
      def initialize
        @mutex = Mutex.new
        @id = 0
      end

      def next
        @mutex.synchronize { @id += 1 }
      end
    end

    attr_reader :connection

    attr_reader :host
    attr_reader :port

    def initialize(host, port)
      @host = host
      @port = port

      @mutex = Mutex.new
      @request_id = RequestId.new
    end

    # @return [true, false] whether the connection was successful
    # @note The connection timeout is currently just 0.5 seconds, which should
    #   be sufficient, but may need to be raised or made configurable for
    #   high-latency situations. That said, if connecting to the remote server
    #   takes that long, we may not want to use the node any way.
    def connect
      return true if connection

      socket = ::Socket.new ::Socket::AF_INET, ::Socket::SOCK_STREAM, 0
      sockaddr = ::Socket.pack_sockaddr_in(port, host)

      begin
        socket.connect_nonblock sockaddr
      rescue IO::WaitWritable, Errno::EINPROGRESS
        IO.select nil, [socket], nil, 0.5

        begin
          socket.connect_nonblock sockaddr
        rescue Errno::EISCONN # we're connected
        rescue
          socket.close rescue nil # jruby raises EBADF
          return false
        end
      end

      @connection = socket
    end

    # @return [true, false] whether this socket connection is alive
    def alive?
      if connection
        return false if connection.closed?

        readable, = IO.select([connection], [connection], [])

        if readable[0]
          begin
            !connection.eof?
          rescue Errno::ECONNRESET
            false
          rescue
            true
          end
        else
          true
        end
      else
        false
      end
    end

    if RUBY_PLATFORM == "java"
      def alive?
        if connection
          return false if connection.closed?

          begin
            connection.ungetc connection.read_nonblock(1)
          rescue EOFError
            false
          rescue Errno::ECONNRESET
            false
          rescue
            true
          end
        else
          false
        end
      end
    end

    # Execute the operations on the connection.
    def execute(*ops)
      instrument(ops) do
        buf = ""

        last = ops.each do |op|
          op.request_id = @request_id.next
          op.serialize buf
        end.last

        if Protocol::Query === last || Protocol::GetMore === last
          length = nil

          @mutex.synchronize do
            connection.write buf

            length, = connection.read(4).unpack('l<')

            # Re-use the already allocated buffer used for writing the command.
            connection.read(length - 4, buf)
          end

          parse_reply length, buf
        else
          @mutex.synchronize do
            connection.write buf
          end

          nil
        end
      end
    end

    def parse_reply(length, data)
      buffer = StringIO.new data

      reply = Protocol::Reply.allocate

      reply.length = length

      reply.request_id,
        reply.response_to,
        reply.op_code,
        reply.flags,
        reply.cursor_id,
        reply.offset,
        reply.count = buffer.read(32).unpack('l4<q<l2<')

      reply.documents = reply.count.times.map do
        BSON::Document.deserialize(buffer)
      end

      reply
    end

    # Executes a simple (one result) query and returns the first document.
    #
    # @return [Hash] the first document in a result set.
    def simple_query(query)
      query = query.dup
      query.limit = -1

      execute(query).documents.first
    end

    # Manually closes the connection
    def close
      @mutex.synchronize do
        connection.close if connection && !connection.closed?
        @connection = nil
      end
    end

    def instrument(ops)
      instrument_start = (logger = Moped.logger) && logger.debug? && Time.now
      yield
    ensure
      log_operations(logger, ops, Time.now - instrument_start) if instrument_start && !$!
    end

    def log_operations(logger, ops, duration)
      prefix  = "  MOPED: #{host}:#{port} "
      indent  = " "*prefix.length
      runtime = (" (%.1fms)" % duration)

      if ops.length == 1
        logger.debug prefix + ops.first.log_inspect + runtime
      else
        first, *middle, last = ops

        logger.debug prefix + first.log_inspect
        middle.each { |m| logger.debug indent + m.log_inspect }
        logger.debug indent + last.log_inspect + runtime
      end
    end

  end
end
