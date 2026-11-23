require 'json'
require 'net/http'
require 'securerandom'
require 'socket'
require 'uri'

module KeaIntegrationTests
  extend self

  IMAGE = 'ghcr.io/lzap/smart-proxy-ext-test-kea:latest'.freeze
  CONTAINER_PORT = 18_123
  CONTAINER_ENGINE = ENV.fetch('CONTAINER_ENGINE', 'podman')

  def run
    image = ENV.fetch('KEA_INTEGRATION_IMAGE', IMAGE)
    container_name = "smart-proxy-kea-integration-#{Process.pid}-#{SecureRandom.hex(4)}"
    host_port = available_port
    control_agent_url = "http://127.0.0.1:#{host_port}/"
    previous_url = ENV['KEA_CONTROL_AGENT_URL']
    started = false

    begin
      puts "Pulling #{image}"
      container!('pull', image)
      puts "Starting #{container_name} on #{control_agent_url}"
      container!('run', '--detach', '--rm', '--name', container_name,
                 '--publish', "127.0.0.1:#{host_port}:#{CONTAINER_PORT}/tcp", image)
      started = true

      ENV['KEA_CONTROL_AGENT_URL'] = control_agent_url
      wait_for_kea(control_agent_url)
      Rake::Task['test:integration:kea:run'].invoke
    ensure
      stop_container(container_name) if started
      restore_control_agent_url(previous_url)
    end
  end

  private

  def container!(*arguments)
    return if system(CONTAINER_ENGINE, *arguments)

    raise "#{CONTAINER_ENGINE} #{arguments.first} failed"
  end

  def stop_container(name)
    return if system(CONTAINER_ENGINE, 'stop', '--time', '10', name)

    warn "Unable to stop #{name}; attempting forced cleanup"
    warn "Unable to remove #{name}" unless system(CONTAINER_ENGINE, 'rm', '--force', name)
  end

  def available_port
    socket = TCPServer.new('127.0.0.1', 0)
    socket.addr[1]
  ensure
    socket&.close
  end

  def wait_for_kea(url)
    timeout = Integer(ENV.fetch('KEA_STARTUP_TIMEOUT', '60'))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    last_error = 'no response'

    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        response = api_request(url)
        result = JSON.parse(response.body).first&.fetch('result', nil)
        return if response.is_a?(Net::HTTPSuccess) && [0, 3].include?(result)

        last_error = "unexpected HTTP #{response.code} or Kea result #{result.inspect}"
      rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError => e
        last_error = e.message
      end

      sleep 1
    end

    raise "Kea Control Agent did not become ready at #{url} within #{timeout}s: #{last_error}"
  end

  def api_request(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 1
    http.read_timeout = 2

    request = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
    request.basic_auth(ENV.fetch('KEA_CONTROL_AGENT_USERNAME', 'kea'), ENV.fetch('KEA_CONTROL_AGENT_PASSWORD', 'kea'))
    request.body = {'command' => 'reservation-get-page',
                    'arguments' => {'subnet-id' => 1, 'limit' => 1},
                    'service' => ['dhcp4']}.to_json
    http.request(request)
  end

  def restore_control_agent_url(previous_url)
    if previous_url
      ENV['KEA_CONTROL_AGENT_URL'] = previous_url
    else
      ENV.delete('KEA_CONTROL_AGENT_URL')
    end
  end
end

desc 'Run all integration test suites.'
task 'test:integration' => 'test:integration:kea'

desc 'Run the Kea integration tests in a temporary container.'
task 'test:integration:kea' do
  KeaIntegrationTests.run
end

Rake::TestTask.new('test:integration:kea:run') do |t|
  t.libs.concat([PROJECT_ROOT,
                 File.join(PROJECT_ROOT, 'lib'),
                 File.join(PROJECT_ROOT, 'modules'),
                 File.join(PROJECT_ROOT, 'test')])
  t.test_files = FileList[File.join(EXT_TEST_ROOT, 'test/dhcp_kea/kea_server_integration_test.rb')]
  t.options = '--verbose'
  t.ruby_opts = ['-W1']
end
