proc { |p| $:.unshift(p) unless $:.any? { |lp| File.expand_path(lp) == p } }.call(File.expand_path('.', File.dirname(__FILE__)))
require 'helper'
require 'logger'
require 'stringio'

describe ApiHammer::RequestLogger do
  let(:logio) { StringIO.new }
  let(:logger) { Logger.new(logio) }

  it 'logs' do
    app = ApiHammer::RequestLogger.new(proc { |env| [200, {}, []] }, logger)
    app.call(Rack::MockRequest.env_for('/')).last.close
    assert_match(/200/, logio.string)
  end

  it 'colors by status' do
    {200 => :intense_green, 400 => :intense_yellow, 500 => :intense_red, 300 => :white}.each do |status, color|
      app = ApiHammer::RequestLogger.new(proc { |env| [status, {}, []] }, logger)
      app.call(Rack::MockRequest.env_for('/')).last.close
      assert(logio.string.include?(Term::ANSIColor.send(color, status.to_s)))
    end
  end

  it 'logs id and uuid' do
    body = %q({"uuid": "theuuid", "foo_uuid": "thefoouuid", "id": "theid", "id_for_x": "theidforx", "bar.id": "thebarid"})
    app = ApiHammer::RequestLogger.new(proc { |env| [200, {"Content-Type" => 'application/json; charset=UTF8'}, [body]] }, logger)
    app.call(Rack::MockRequest.env_for('/')).last.close
    assert_match(%q("body_ids":{"uuid":"theuuid","foo_uuid":"thefoouuid","id":"theid","id_for_x":"theidforx","bar.id":"thebarid"}), logio.string)
  end
end
