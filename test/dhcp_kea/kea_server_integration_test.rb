require 'test_helper'
require 'ipaddr'
require 'securerandom'
require 'socket'
require 'dhcp/dhcp'
require 'dhcp/dependency_injection'
require 'dhcp/dhcp_api'
require 'dhcp_common/dhcp_common'
require 'dhcp_common/free_ips'
require 'dhcp_kea/kea_api_client'
require 'dhcp_kea/dhcp_kea_main'

# Run via `bin/test-integration`. Set KEA_TEST_SUBNET if the image uses a
# different subnet, or override the Control Agent credentials if they change.
class DhcpKeaServerIntegrationTest < Test::Unit::TestCase
  include Rack::Test::Methods

  def app
    api = Proxy::DhcpApi.new
    api.helpers.server = @provider
    Rack::Builder.new do
      map '/dhcp' do
        run api
      end
    end
  end

  def setup
    WebMock.allow_net_connect!

    @created_leases = []
    @created_reservations = []
    @client = Proxy::DHCP::Kea::KeaApiClient.new(
      ENV.fetch('KEA_CONTROL_AGENT_URL', 'http://127.0.0.1:18123/'),
      ENV.fetch('KEA_CONTROL_AGENT_USERNAME', 'kea'),
      ENV.fetch('KEA_CONTROL_AGENT_PASSWORD', 'kea'),
      timeout: 10
    )

    network = ENV.fetch('KEA_TEST_SUBNET', '192.168.122.0')
    @subnet_config = @client.subnets.find { |subnet| subnet['subnet'].split('/').first == network }
    assert_not_nil @subnet_config, "Kea does not have the test subnet #{network}; set KEA_TEST_SUBNET to a configured subnet"

    @network = network
    @subnet_id = @subnet_config.fetch('id')
    @provider = Proxy::DHCP::Kea::Provider.new(@client, nil, Proxy::DHCP::FreeIps.new)
    Proxy::DhcpPlugin.settings.stubs(:ping_free_ip).returns(false)
  end

  def teardown
    @created_leases&.reverse_each { |ip| @client.delete_lease(ip) }
    @created_reservations&.reverse_each { |mac| @client.delete_reservation(@subnet_id, mac) }
  ensure
    WebMock.disable_net_connect!
  end

  def test_discovers_subnet_and_options
    subnet = @provider.find_subnet(@network)

    assert_not_nil subnet
    assert_include @provider.subnets.map(&:network), @network
    assert_equal pool_bounds(@subnet_config['pools'].first['pool']).map { |ip| ipv4(ip) }, subnet.options[:range]
  end

  def test_foreman_dhcp_api_workflow
    get '/dhcp'

    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"
    subnet = JSON.parse(last_response.body).find { |item| item['network'] == @network }
    assert_not_nil subnet

    from, to = pool_bounds(@subnet_config['pools'].first['pool']).map { |address| ipv4(address) }
    assert_equal [from, to], subnet.fetch('options').fetch('range')

    get "/dhcp/#{@network}/unused_ip"
    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"
    address_without_range = JSON.parse(last_response.body).fetch('ip')
    assert IPAddr.new(@subnet_config['subnet']).include?(address_without_range)

    mac = random_mac
    hostname = "kea-foreman-#{SecureRandom.hex(4)}.example.test"
    get "/dhcp/#{@network}/unused_ip", :mac => mac, :from => from, :to => to

    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"
    ip = JSON.parse(last_response.body).fetch('ip')
    assert_operator IPAddr.new(ip).to_i, :>=, IPAddr.new(from).to_i
    assert_operator IPAddr.new(ip).to_i, :<=, IPAddr.new(to).to_i

    record_params = {
      :name => hostname,
      :hostname => hostname,
      :ip => ip,
      :mac => mac,
      :network => @network,
      :nextServer => '192.168.122.1',
      :filename => 'pxelinux.0',
    }
    @created_reservations << mac
    post "/dhcp/#{@network}", record_params

    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"

    post "/dhcp/#{@network}", record_params
    assert last_response.ok?, 'Creating the same Foreman DHCP record again should be a successful no-op'

    conflict_params = record_params.merge(:hostname => "conflict-#{hostname}", :name => "conflict-#{hostname}", :mac => random_mac)
    post "/dhcp/#{@network}", conflict_params
    assert_equal 409, last_response.status

    get "/dhcp/#{@network}/mac/#{conflict_params[:mac]}"
    assert_equal 404, last_response.status

    get "/dhcp/#{@network}/ip/#{ip}"
    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"
    conflicting_records = JSON.parse(last_response.body).map { |record| record.values_at('hostname', 'ip', 'mac') }
    assert_equal [[hostname, ip, mac]], conflicting_records

    get "/dhcp/#{@network}/mac/#{mac}"
    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"
    assert_equal ['reservation', hostname, ip, mac], JSON.parse(last_response.body).values_at('type', 'hostname', 'ip', 'mac')

    get "/dhcp/#{@network}/ip/#{ip}"
    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"
    records = JSON.parse(last_response.body).map { |record| record.values_at('type', 'hostname', 'ip', 'mac') }
    assert_equal [['reservation', hostname, ip, mac]], records

    get "/dhcp/#{@network}/unused_ip", :mac => mac, :from => from, :to => to
    assert_equal ip, JSON.parse(last_response.body).fetch('ip')

    delete "/dhcp/#{@network}/mac/#{mac}"
    assert_equal 200, last_response.status
    assert_empty last_response.body

    get "/dhcp/#{@network}/mac/#{mac}"
    assert_equal 404, last_response.status
    @created_reservations.delete(mac)
  end

  def test_reservation_crud_and_free_ip_reuse
    ip = available_address(static_ranges)
    mac = random_mac
    hostname = "kea-integration-#{SecureRandom.hex(4)}.example.test"

    record = @provider.add_record(
      'hostname' => hostname,
      'ip' => ip,
      'mac' => mac,
      'network' => @network,
      'nextServer' => '192.168.122.1',
      'filename' => 'pxelinux.0'
    )
    @created_reservations << mac

    by_ip = @provider.find_records_by_ip(@network, ip).first
    by_mac = @provider.find_record_by_mac(@network, mac)
    listed = @provider.all_hosts(@network).find { |host| host.mac == mac }

    [record, by_ip, by_mac, listed].each do |host|
      assert_equal [hostname, ip, mac, '192.168.122.1', 'pxelinux.0'],
                   [host.name, host.ip, host.mac, host.nextServer, host.filename]
    end
    assert_equal ip, @provider.unused_ip(@network, mac, ip, ip)
    assert_nil @provider.unused_ip(@network, random_mac, ip, ip)

    @provider.del_record(by_ip)
    @created_reservations.delete(mac)

    assert_empty @provider.find_records_by_ip(@network, ip)
  end

  def test_lease_lookup_delete_and_free_ip
    ip = available_address(pool_ranges)
    mac = random_mac
    @client.send_command('lease4-add', 'ip-address' => ip, 'hw-address' => mac, 'subnet-id' => @subnet_id)
    @created_leases << ip

    by_ip = @provider.find_records_by_ip(@network, ip).first
    by_mac = @provider.find_record_by_mac(@network, mac)
    listed = @provider.all_leases(@network).find { |lease| lease.ip == ip }

    [by_ip, by_mac, listed].each do |lease|
      assert_kind_of Proxy::DHCP::Lease, lease
      assert_equal [ip, mac], [lease.ip, lease.mac]
    end

    get "/dhcp/#{@network}/mac/#{mac}"
    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"
    assert_equal ['lease', ip, mac], JSON.parse(last_response.body).values_at('type', 'ip', 'mac')

    get "/dhcp/#{@network}/ip/#{ip}"
    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"
    records = JSON.parse(last_response.body).map { |record| record.values_at('type', 'ip', 'mac') }
    assert_equal [['lease', ip, mac]], records

    assert_nil @provider.unused_ip(@network, nil, ip, ip)
    get "/dhcp/#{@network}/unused_ip", :mac => mac, :from => ip, :to => ip
    assert last_response.ok?, "Last response was not ok: #{last_response.status} #{last_response.body}"
    assert_equal ip, JSON.parse(last_response.body).fetch('ip')

    delete "/dhcp/#{@network}/mac/#{mac}"
    assert_equal 200, last_response.status
    assert_empty last_response.body
    @created_leases.delete(ip)

    assert_nil @client.lease_by_ip(ip)
  end

  def test_free_ip_returns_an_available_address_once
    ip = available_address(pool_ranges)

    assert_equal ip, @provider.unused_ip(@network, nil, ip, ip)
    assert_nil @provider.unused_ip(@network, nil, ip, ip)
  end

  private

  def random_mac
    ([0x02] + SecureRandom.random_bytes(5).bytes).map { |octet| format('%02x', octet) }.join(':')
  end

  def pool_bounds(pool)
    return pool.split('-', 2).map { |address| IPAddr.new(address.strip).to_i } if pool.include?('-')

    range = IPAddr.new(pool).to_range
    [range.first.to_i, range.last.to_i]
  end

  def pool_ranges
    @pool_ranges ||= (@subnet_config['pools'] || []).map { |pool| pool_bounds(pool['pool']) }
  end

  def static_ranges
    subnet_range = IPAddr.new(@subnet_config['subnet']).to_range
    ranges = [[subnet_range.first.to_i + 1, subnet_range.last.to_i - 1]]

    pool_ranges.each do |pool_start, pool_end|
      ranges = ranges.flat_map do |range_start, range_end|
        if pool_end < range_start || pool_start > range_end
          [[range_start, range_end]]
        else
          outside = []
          outside << [range_start, pool_start - 1] if pool_start > range_start
          outside << [pool_end + 1, range_end] if pool_end < range_end
          outside
        end
      end
    end

    ranges.select { |range_start, range_end| range_start <= range_end }
  end

  def available_address(ranges)
    raise 'The Kea test subnet has no suitable address range' if ranges.empty?

    100.times do
      range_start, range_end = ranges.sample
      ip = ipv4(rand(range_start..range_end))
      return ip unless address_in_use?(ip)
    end

    raise "Unable to find an unused test IP in #{ranges.inspect}"
  end

  def address_in_use?(ip)
    reservation = @client.reservation_by_ip(@subnet_id, ip)
    return true if reservation.is_a?(Hash) && reservation['ip-address'] == ip

    lease = @client.lease_by_ip(ip)
    lease.is_a?(Hash) && lease['ip-address'] == ip
  end

  def ipv4(value)
    IPAddr.new(value, Socket::AF_INET).to_s
  end
end
