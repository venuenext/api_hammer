require 'faraday'
require 'rack'
require 'term/ansicolor'
require 'json'
require 'strscan'

if Faraday.respond_to?(:register_middleware)
  Faraday.register_middleware(:request, :api_hammer_request_logger => proc { ApiHammer::Faraday::RequestLogger })
end
if Faraday::Request.respond_to?(:register_middleware)
  Faraday::Request.register_middleware(:api_hammer_request_logger => proc { ApiHammer::Faraday::RequestLogger })
end

module ApiHammer
  class Faraday
    # Faraday middleware for logging.
    #
    # two lines:
    #
    # - an info line, colored prettily to show a brief summary of the request and response
    # - a debug line of json to record all relevant info. this is a lot of stuff jammed into one line, not 
    #   pretty, but informative.
    class RequestLogger < ::Faraday::Middleware
      include Term::ANSIColor

      def initialize(app, logger, options={})
        @app = app
        @logger = logger
        @options = options
      end

      # deal with the vagaries of getting the response body in a form which JSON 
      # gem will not cry about dumping 
      def response_body(response_env)
        # first try to change the string's encoding per the Content-Type header 
        content_type = response_env.response_headers['Content-Type']
        response_body = response_env.body.dup
        unless response_body.valid_encoding?
          # I think this always comes in as ASCII-8BIT anyway so may never get here. hopefully.
          response_body.force_encoding('ASCII-8BIT')
        end

        if content_type
          # TODO refactor this parsing somewhere better? 
          parsed = false
          attributes = Hash.new { |h,k| h[k] = [] }
          catch(:unparseable) do
            uri_parser = URI.const_defined?(:Parser) ? URI::Parser.new : URI
            scanner = StringScanner.new(content_type)
            scanner.scan(/.*;\s*/) || throw(:unparseable)
            while match = scanner.scan(/(\w+)=("?)([^"]*)("?)\s*(,?)\s*/)
              key = scanner[1]
              quote1 = scanner[2]
              value = scanner[3]
              quote2 = scanner[4]
              comma_follows = !scanner[5].empty?
              throw(:unparseable) unless quote1 == quote2
              throw(:unparseable) if !comma_follows && !scanner.eos?
              attributes[uri_parser.unescape(key)] << uri_parser.unescape(value)
            end
            throw(:unparseable) unless scanner.eos?
            parsed = true
          end
          if parsed
            charset = attributes['charset'].first
            if charset && Encoding.list.any? { |enc| enc.to_s.downcase == charset.downcase }
              if response_body.dup.force_encoding(charset).valid_encoding?
                response_body.force_encoding(charset)
              else
                # I guess just ignore the specified encoding if the result is not valid. fall back to 
                # something else below.
              end
            end
          end
        end
        begin
          JSON.dump([response_body])
        rescue Encoding::UndefinedConversionError
          # if updating by content-type didn't do it, try UTF8 since JSON wants that - but only 
          # if it seems to be valid utf8. 
          # don't try utf8 if the response content-type indicated something else. 
          try_utf8 = !(parsed && attributes['charset'].any?)
          if try_utf8 && response_body.dup.force_encoding('UTF-8').valid_encoding?
            response_body.force_encoding('UTF-8')
          else
            # I'm not sure if there is a way in this situation to get JSON gem to dump the 
            # string correctly. fall back to an array of codepoints I guess? this is a weird 
            # solution but the best I've got for now. 
            response_body = response_body.codepoints.to_a
          end
        end
        response_body
      end

      def call(request_env)
        began_at = Time.now

        log_tags = Thread.current[:activesupport_tagged_logging_tags]
        saved_log_tags = log_tags.dup if log_tags && log_tags.any?

        request_body = request_env[:body].dup if request_env[:body]

        @app.call(request_env).on_complete do |response_env|
          now = Time.now

          status_color = case response_env.status.to_i
          when 200..299
            :intense_green
          when 400..499
            :intense_yellow
          when 500..599
            :intense_red
          else
            :white
          end
          status_s = bold(send(status_color, response_env.status.to_s))
          data = {
            'request' => {
              'method' => request_env[:method],
              'uri' => request_env[:url].normalize.to_s,
              'headers' => request_env.request_headers,
              'body' => request_body,
            }.reject{|k,v| v.nil? },
            'response' => {
              'status' => response_env.status,
              'headers' => response_env.response_headers,
              'body' => response_body(response_env),
            }.reject{|k,v| v.nil? },
            'processing' => {
              'began_at' => began_at.utc.to_i,
              'duration' => now - began_at,
              'activesupport_tagged_logging_tags' => @log_tags,
            }.reject{|k,v| v.nil? },
          }

          json_data = JSON.dump(data)
          dolog = proc do
            now_s = now.strftime('%Y-%m-%d %H:%M:%S %Z')
            @logger.info "#{bold(intense_magenta('>'))} #{status_s} : #{bold(intense_magenta(request_env[:method].to_s.upcase))} #{intense_magenta(request_env[:url].normalize.to_s)} @ #{intense_magenta(now_s)}"
            @logger.info json_data
          end

          # reapply log tags from the request if they are not applied 
          if @logger.respond_to?(:tagged) && saved_log_tags && Thread.current[:activesupport_tagged_logging_tags] != saved_log_tags
            @logger.tagged(saved_log_tags, &dolog)
          else
            dolog.call
          end
        end
      end
    end
  end
end