class quantum::agents::metadata (
  $auth_password,
  $shared_secret,
  $package_ensure               = 'present',
  $enabled                      = true,
  $debug                        = false,
  $auth_tenant                  = 'services',
  $auth_user                    = 'quantum',
  $auth_url                     = 'http://localhost:35357/v2.0',
  $auth_region                  = 'RegionOne',
  $metadata_ip                  = '127.0.0.1',
  $metadata_port                = '8775'
  ) {

  $cib_name = "quantum-metadata-agent"
  $res_name = "p_$cib_name"

  if $enabled {
    $ensure = 'running'
  } else {
    $ensure = 'stopped'
  }

  include 'quantum::params'

  anchor {'quantum-metadata-agent': }

  Anchor['quantum-l3-done'] -> Anchor['quantum-metadata-agent']

  # OCF script for pacemaker
  # and his dependences
  file {'quantum-metadata-agent-ocf':
    path=>'/usr/lib/ocf/resource.d/mirantis/quantum-metadata-agent', 
    mode => 744,
    owner => root,
    group => root,
    source => "puppet:///modules/quantum/ocf/quantum-metadata-agent",
  }
  Package['pacemaker'] -> File['quantum-metadata-agent-ocf']

  # add instructions to nova.conf
  nova_config { 
    'service_quantum_metadata_proxy':       value => true; 
    'quantum_metadata_proxy_shared_secret': value => $shared_secret; 
  } -> Nova::Generic_service<| title=='api' |>

  quantum_metadata_agent_config {
    'DEFAULT/debug':                          value => $debug;
    'DEFAULT/auth_url':                       value => $auth_url;
    'DEFAULT/auth_region':                    value => $auth_region;
    'DEFAULT/admin_tenant_name':              value => $auth_tenant;
    'DEFAULT/admin_user':                     value => $auth_user;
    'DEFAULT/admin_password':                 value => $auth_password;
    'DEFAULT/nova_metadata_ip':               value => $metadata_ip;
    'DEFAULT/nova_metadata_port':             value => $metadata_port;
    'DEFAULT/metadata_proxy_shared_secret':   value => $shared_secret;
  }

  if $::quantum::params::metadata_agent_package {
    package { 'quantum-metadata-agent':
      name    => $::quantum::params::metadata_agent_package,
      ensure  => $package_ensure,
    }
    # do not move it to outside this IF
    Anchor['quantum-metadata-agent'] -> 
      Package['quantum-metadata-agent'] -> 
        Quantum_metadata_agent_config<||>
  }

  service { 'quantum-metadata-agent__disabled':
    name    => $::quantum::params::metadata_agent_service,
    enable  => false,
    ensure  => stopped,
  }
  
  cs_shadow { $res_name: cib => $cib_name }
  cs_commit { $res_name: cib => $cib_name }

  cs_resource { $res_name:
    ensure          => present,
    cib             => $cib_name,
    primitive_class => 'ocf',
    provided_by     => 'mirantis',
    primitive_type  => 'quantum-metadata-agent',
    parameters => {
      #'nic'     => $vip[nic],
      #'ip'      => $vip[ip],
      #'iflabel' => $vip[iflabel] ? { undef => 'ka', default => $vip[iflabel] },
    },
    operations => {
      'monitor' => {
        'interval' => '60',
        'timeout'  => '30'
      },
      'start' => {
        'timeout' => '30'
      },
      'stop' => {
        'timeout' => '30'
      },
    },
  }
  Cs_commit <| title == 'l3' |> -> Cs_shadow <| title == "$res_name" |>

  cs_colocation { 'quantum-metadata-agent__with__quantum-l3-agent':
    ensure     => present,
    cib        => $cib_name,
    primitives => [
        "p_${::quantum::params::l3_agent_service}", 
        "$res_name"
    ],
    score      => 'INFINITY',
  }
  cs_order { 'quantum-metadata-agent__after__quantum-l3-agent':
    ensure => present,
    cib    => $cib_name,
    first  => "p_${::quantum::params::l3_agent_service}",
    second => "$res_name",
    score  => 'INFINITY',
  }
  Cs_resource["$res_name"] -> 
    Cs_colocation['quantum-metadata-agent__with__quantum-l3-agent'] ->
      Cs_order['quantum-metadata-agent__after__quantum-l3-agent'] ->
        Cs_commit["$res_name"] -> 
          Service["$res_name"]

  service {"$res_name":
    name       => $res_name,
    enable     => $enabled,
    ensure     => $ensure,
    hasstatus  => true,
    hasrestart => true,
    provider   => "pacemaker"
  }

  Anchor['quantum-metadata-agent'] ->
    Quantum_metadata_agent_config<||> ->
      File['quantum-metadata-agent-ocf'] ->
        Service['quantum-metadata-agent__disabled'] ->
          Cs_resource["$res_name"] ->
            Service["$res_name"] ->
              Anchor['quantum-metadata-agent-done']

  anchor {'quantum-metadata-agent-done': }
}
#
###