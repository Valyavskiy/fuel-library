$ntp_server = '0.centos.pool.ntp.org'

#stage {'clocksync': before => Stage['main']}

class openstack::clocksync ($ntp_server)
{
  include ntpd

  package {'ntpdate': ensure => present}
  exec {'clocksync':
    unless  => "pidof ntpd",
    before  => [Service[$::ntpd::service_name]],
    require => Package['ntpdate'],
    command => "ntpdate $ntp_server",
    path    => ['/usr/bin', '/usr/sbin', '/sbin', '/bin'],
  }
}

class {'openstack::clocksync': ntp_server=>$ntp_server}

Exec['clocksync']->Nova::Generic_service<| |>
Exec['clocksync']->Exec<| title == 'keystone-manage db_sync' |>
Exec['clocksync']->Exec<| title == 'glance-manage db_sync' |>
Exec['clocksync']->Exec<| title == 'nova-manage db sync' |>
Exec['clocksync']->Exec<| title == 'initial-db-sync' |>
Exec['clocksync']->Exec<| title == 'post-nova_config' |>


define haproxy_service($order, $balancers, $virtual_ips, $port, $define_cookies = false, $master_host = undef) {

  case $name {
    "mysqld": {
      $haproxy_config_options = { 'option' => ['mysql-check user cluster_watcher', 'tcplog','clitcpka','srvtcpka'], 'balance' => 'roundrobin', 'mode' => 'tcp', 'timeout server' => '28801s', 'timeout client' => '28801s' }
      $balancermember_options = 'check inter 15s fastinter 2s downinter 1s rise 5 fall 3'
      $balancer_port = 3307
    }

    "horizon": {
      $haproxy_config_options = {
        'option'  => ['forwardfor', 'httpchk', 'httpclose', 'httplog'],
        'rspidel' => '^Set-cookie:\ IP=',
        # 'stick'   => 'on src table horizon-ssl',
        'balance' => 'roundrobin',
        'cookie'  => 'SERVERID insert indirect nocache',
        'capture' => 'cookie vgnvisitor= len 32'
      }
      $balancermember_options = 'check inter 2000 fall 3'
      $balancer_port = 80
    }

    "horizon-ssl": {
      $haproxy_config_options = {
        'option'      => ['ssl-hello-chk', 'tcpka'],
        'stick-table' => 'type ip size 200k expire 30m',
        'stick'       => 'on src',
        'balance'     => 'source',
        'timeout'     => ['client 3h', 'server 3h'],
        'mode'        => 'tcp'
      }
      $balancermember_options = 'weight 1 check'
      $balancer_port = 443
    }

    "rabbitmq-epmd": {
      $haproxy_config_options = { 'option' => ['clitcpka','srvtcpka'], 'balance' => 'roundrobin', 'mode' => 'tcp'}
      $balancermember_options = 'check inter 5000 rise 2 fall 3'
      $balancer_port = 4369
    }
    "rabbitmq-openstack": {
      $haproxy_config_options = { 'option' => ['clitcpka','srvtcpka'], 'balance' => 'roundrobin', 'mode' => 'tcp'}
      $balancermember_options = 'check inter 5000 rise 2 fall 3'
      $balancer_port = 5673
    }
    
    default: {
      $haproxy_config_options = { 'option' => ['httplog'], 'balance' => 'roundrobin' }
      $balancermember_options = 'check'
      $balancer_port = $port
    }
  }

  haproxy::listen { $name:
    order            => $order - 1,
    ipaddress        => $virtual_ips,
    ports            => $port,
    options          => $haproxy_config_options,
    collect_exported => false
  }
  @haproxy::balancermember { "${name}":
    order                  => $order,
    listening_service      => $name,
    balancers              => $balancers,
    balancer_port          => $balancer_port,
    balancermember_options => $balancermember_options,
    define_cookies         => $define_cookies,
    master_host            => $master_host
  }

}

define keepalived_dhcp_hook($interface)
{
    $down_hook="ip addr show dev $interface | grep -w $interface:ka | awk '{print \$2}' > /tmp/keepalived_${interface}_ip\n"
    $up_hook="cat /tmp/keepalived_${interface}_ip |  while read ip; do  ip addr add \$ip dev $interface label $interface:ka; done\n"
    file {"/etc/dhcp/dhclient-${interface}-down-hooks": content=>$down_hook, mode => 744 }
    file {"/etc/dhcp/dhclient-${interface}-up-hooks": content=>$up_hook, mode => 744 }
}



class openstack::controller_ha (
   $master_hostname,
   $controller_public_addresses, $public_interface, $private_interface, $controller_internal_addresses,
   $internal_virtual_ip, $public_virtual_ip, $internal_interface, $internal_address,
   $floating_range, $fixed_range, $multi_host, $network_manager, $verbose, $network_config = {}, $num_networks = 1, $network_size = 255,
   $auto_assign_floating_ip, $mysql_root_password, $admin_email, $admin_password,
   $keystone_db_password, $keystone_admin_token, $glance_db_password, $glance_user_password,
   $nova_db_password, $nova_user_password, $rabbit_password, $rabbit_user,
   $rabbit_nodes, $memcached_servers, $export_resources, $glance_backend='file', $swift_proxies=undef,
   $quantum = false, $quantum_user_password, $quantum_db_password, $quantum_db_user = 'quantum',
   $quantum_db_dbname  = 'quantum', $cinder = false, $cinder_iscsi_bind_iface = false, $tenant_network_type = 'gre', $segment_range = '1:4094',
   $nv_physical_volume = undef, $manage_volumes = false,$galera_nodes, $use_syslog = false,
   $cinder_rate_limits = undef, $nova_rate_limits = undef, 
   $rabbit_node_ip_address  = $internal_address, $horizon_use_ssl = false,
   $quantum_network_node    = false,
   $quantum_netnode_on_cnt  = false,
   $quantum_gre_bind_addr   = $internal_address,
   $quantum_external_ipinfo = {},
 ) {

   # $which = $::hostname ? { $master_hostname => 0, default => 1 }
    if ($::hostname == $master_hostname) or ($::fqdn == $master_hostname) {
      $which = 0
    }
    else {
      $which = 1
    }
    

    #    $vip = $virtual_ip
    #    $hosts = $controller_hostnames
    #    $ips = $controller_internal_addresses


    # haproxy
    include haproxy::params

    Haproxy_service {
#      virtual_ip => $vip,
#      hostnames => $controller_hostnames,
      balancers => $controller_internal_addresses
    }

    file { '/etc/rsyslog.d/haproxy.conf':
      ensure => present,
      content => '$ModLoad imudp
$UDPServerRun 514
local0.* -/var/log/haproxy.log'
    }
    Class['keepalived'] -> Class ['nova::rabbitmq']
    haproxy_service { 'horizon':    order => 15, port => 80, virtual_ips => [$public_virtual_ip], define_cookies => true  }

    if $horizon_use_ssl {
      haproxy_service { 'horizon-ssl': order => 17, port => 443, virtual_ips => [$public_virtual_ip] }
    }

    haproxy_service { 'keystone-1': order => 20, port => 5000, virtual_ips => [$public_virtual_ip, $internal_virtual_ip]  }
    haproxy_service { 'keystone-2': order => 30, port => 35357, virtual_ips => [$public_virtual_ip, $internal_virtual_ip]  }
    haproxy_service { 'nova-api-1': order => 40, port => 8773, virtual_ips => [$public_virtual_ip, $internal_virtual_ip]  }
    haproxy_service { 'nova-api-2': order => 50, port => 8774, virtual_ips => [$public_virtual_ip, $internal_virtual_ip]  }

    if ! $multi_host {
      haproxy_service { 'nova-api-3': order => 60, port => 8775, virtual_ips => [$public_virtual_ip, $internal_virtual_ip]  }
    }

    haproxy_service { 'nova-api-4': order => 70, port => 8776, virtual_ips => [$public_virtual_ip, $internal_virtual_ip]  }
    haproxy_service { 'glance-api': order => 80, port => 9292, virtual_ips => [$public_virtual_ip, $internal_virtual_ip]  }

    if $quantum {
      haproxy_service { 'quantum': order => 85, port => 9696, virtual_ips => [$public_virtual_ip, $internal_virtual_ip]  }
    }

    haproxy_service { 'glance-reg': order => 90, port => 9191, virtual_ips => [$internal_virtual_ip]  }
#    haproxy_service { 'rabbitmq-epmd':    order => 91, port => 4369, virtual_ips => [$internal_virtual_ip], master_host => $master_hostname  }
    haproxy_service { 'rabbitmq-openstack':    order => 92, port => 5672, virtual_ips => [$internal_virtual_ip], master_host => $master_hostname  }
    haproxy_service { 'mysqld':     order => 95, port => 3306, virtual_ips => [$internal_virtual_ip], master_host => $master_hostname }
          if $glance_backend == 'swift'
        {
                        haproxy_service { 'swift':    order => 96, port => 8080, virtual_ips => [$public_virtual_ip,$internal_virtual_ip], balancers => $swift_proxies }
        }


    exec { 'up-public-interface':
      command => "ifconfig ${public_interface} up",
      path    => ['/usr/bin', '/usr/sbin', '/sbin', '/bin'],
    }
    exec { 'up-internal-interface':
      command => "ifconfig ${internal_interface} up",
      path    => ['/usr/bin', '/usr/sbin', '/sbin', '/bin'],
    }
    exec { 'up-private-interface':
      command => "ifconfig ${private_interface} up",
      path    => ['/usr/bin', '/usr/sbin', '/sbin', '/bin'],
    }

    if $which == 0 { 
      exec { 'create-public-virtual-ip':
        command => "ip addr add ${public_virtual_ip} dev ${public_interface} label ${public_interface}:ka",
        unless  => "ip addr show dev ${public_interface} | grep -w ${public_virtual_ip}",
        path    => ['/usr/bin', '/usr/sbin', '/sbin', '/bin'],
        before  => Service['keepalived'],
        require => Exec['up-public-interface'],
      }   
    }   

    keepalived_dhcp_hook {$public_interface:interface=>$public_interface}
    if $internal_interface != $public_interface {
      keepalived_dhcp_hook {$internal_interface:interface=>$internal_interface}
    }

    Keepalived_dhcp_hook<| |> {before =>Service['keepalived']} 

    if $which == 0 { 
      exec { 'create-internal-virtual-ip':
        command => "ip addr add ${internal_virtual_ip} dev ${internal_interface} label ${internal_interface}:ka",
        unless  => "ip addr show dev ${internal_interface} | grep -w ${internal_virtual_ip}",
        path    => ['/usr/bin', '/usr/sbin', '/sbin', '/bin'],
        before  => Service['keepalived'],
        require => Exec['up-internal-interface'],
      }   
    }   
    sysctl::value { 'net.ipv4.ip_nonlocal_bind': value => '1' }

        package {'socat': ensure => present}
        exec { 'wait-for-haproxy-mysql-backend':
                command => "echo show stat | socat unix-connect:///var/lib/haproxy/stats stdio | grep 'mysqld,BACKEND' | awk -F ',' '{print \$18}' | grep -q 'UP'",
                path => ['/usr/bin', '/usr/sbin', '/sbin', '/bin'],
                require => [Service['haproxy'],Package['socat']],
                try_sleep   => 5,
                tries       => 60,
                }
        Exec<| title == 'wait-for-synced-state' |> -> Exec['wait-for-haproxy-mysql-backend']
        Exec['wait-for-haproxy-mysql-backend'] -> Exec<| title == 'initial-db-sync' |>
        Exec['wait-for-haproxy-mysql-backend'] -> Exec<| title == 'keystone-manage db_sync' |>
        Exec['wait-for-haproxy-mysql-backend'] -> Exec<| title == 'glance-manage db_sync' |>
        Exec['wait-for-haproxy-mysql-backend'] -> Exec<| title == 'cinder-manage db_sync' |>
        Exec['wait-for-haproxy-mysql-backend'] -> Exec<| title == 'nova-db-sync' |>
        Exec['wait-for-haproxy-mysql-backend'] -> Service <| title == 'cinder-volume' |>
        Exec['wait-for-haproxy-mysql-backend'] -> Service <| title == 'cinder-api' |>

    class { 'haproxy':
      enable => true, 
      global_options   => merge($::haproxy::params::global_options, {'log' => "${internal_address} local0"}),
      defaults_options => merge($::haproxy::params::defaults_options, {'mode' => 'http'}),
      require => Sysctl::Value['net.ipv4.ip_nonlocal_bind'],
    }

#    exec { 'create-keepalived-rules':
#        command => "iptables -I INPUT -m pkttype --pkt-type multicast -d 224.0.0.18 -j ACCEPT && /etc/init.d/iptables save ", 
#        unless => "iptables-save  | grep '\-A INPUT -d 224.0.0.18/32 -m pkttype --pkt-type multicast -j ACCEPT' -q",
#        path => ['/usr/bin', '/usr/sbin', '/sbin', '/bin'],
#        before => Service['keepalived'],
#        require => Class['::openstack::firewall']
#    }

    # keepalived
    $public_vrid   = $::deployment_id
    $internal_vrid = $::deployment_id + 1

    class { 'keepalived': require => [Class['haproxy'],Class['::openstack::firewall']] }

    keepalived::instance { $public_vrid:
      interface => $public_interface,
      virtual_ips => [$public_virtual_ip],
      state    => $which ? { 0 => 'MASTER', default => 'BACKUP' },
      priority => $which ? { 0 => 101,      default => 100      },
    }
    keepalived::instance { $internal_vrid:
      interface => $internal_interface,
      virtual_ips => [$internal_virtual_ip],
      state    => $which ? { 0 => 'MASTER', default => 'BACKUP' },
      priority => $which ? { 0 => 101,      default => 100      },
    }

#    class { 'galera':
#   require => Class['haproxy'],
#      cluster_name => 'openstack',
#      master_ip => $which ? { 0 => false, default => $controller_internal_addresses[0] },
#      node_address => $controller_internal_addresses[$which],
#    }

    class { '::openstack::firewall':
      before => Class['galera']
    }
    Class['haproxy'] -> Class['galera']
#    Class['openstack::controller']->Class['galera']
    
    class { '::openstack::controller':
      public_address          => $public_virtual_ip,
      public_interface        => $public_interface,
      private_interface       => $private_interface,
      internal_address        => $internal_virtual_ip,
      admin_address           => $internal_virtual_ip,
      floating_range          => $floating_range,
      fixed_range             => $fixed_range,
      multi_host              => $multi_host,
      network_config          => $network_config,
      num_networks            => $num_networks,
      network_size            => $network_size,
      network_manager         => $network_manager,
      verbose                 => $verbose,
      auto_assign_floating_ip => $auto_assign_floating_ip,
      mysql_root_password     => $mysql_root_password,
      custom_mysql_setup_class=> 'galera',
      galera_cluster_name     => 'openstack',
      galera_master_ip        => $which ? { 0 => false, default => $controller_internal_addresses[$master_hostname] },
      galera_node_address     => $internal_address,
      galera_nodes            => $galera_nodes,
      admin_email             => $admin_email,
      admin_password          => $admin_password,
      keystone_db_password    => $keystone_db_password,
      keystone_admin_token    => $keystone_admin_token,
      glance_db_password      => $glance_db_password,
      glance_user_password    => $glance_user_password,
      nova_db_password        => $nova_db_password,
      nova_user_password      => $nova_user_password,
      rabbit_password         => $rabbit_password,
      rabbit_user             => $rabbit_user,
      rabbit_cluster          => true,
      rabbit_nodes            => $controller_hostnames,
      rabbit_port             => '5673',
      rabbit_node_ip_address  => $rabbit_node_ip_address,
      rabbit_ha_virtual_ip    => $internal_virtual_ip,
      cache_server_ip         => $memcached_servers,
      export_resources        => false,
      api_bind_address        => $internal_address,
      db_host                 => $internal_virtual_ip,
      service_endpoint        => $internal_virtual_ip,
      glance_backend          => $glance_backend,
      require                 => Service['keepalived'],
      quantum                 => $quantum,
      quantum_user_password   => $quantum_user_password,
      quantum_db_password     => $quantum_db_password,
     #quantum_l3_enable       => $which ? { 0 => true, 1 => false },
      quantum_gre_bind_addr   => $quantum_gre_bind_addr,
      quantum_external_ipinfo => $quantum_external_ipinfo,
      quantum_network_node    => $quantum_network_node,
      quantum_netnode_on_cnt  => $quantum_netnode_on_cnt,
      segment_range           => $segment_range,
      tenant_network_type     => $tenant_network_type,
      cinder                  => $cinder,
      cinder_iscsi_bind_iface => $cinder_iscsi_bind_iface,
      manage_volumes          => $manage_volumes,
      nv_physical_volume      => $nv_physical_volume,
      # turn on SWIFT_ENABLED option for Horizon dashboard
      swift                   => $glance_backend ? { 'swift' => true, default => false },
      use_syslog              => $use_syslog,
      cinder_rate_limits      => $cinder_rate_limits,
      nova_rate_limits        => $nova_rate_limits,
      horizon_use_ssl         => $horizon_use_ssl,
    }

    class { 'openstack::auth_file':
      admin_password          => $admin_password,
      keystone_admin_token    => $keystone_admin_token,
      controller_node         => $internal_virtual_ip,
    }
}

