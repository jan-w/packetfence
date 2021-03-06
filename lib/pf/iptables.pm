package pf::iptables;

=head1 NAME

pf::iptables - module for iptables rules management.

=cut

=head1 DESCRIPTION

pf::iptables contains the functions necessary to manipulate the
iptables rules used when using PacketFence in ARP or DHCP mode.

=head1 CONFIGURATION AND ENVIRONMENT

F<pf.conf> configuration file and iptables template F<iptables.conf>.

=cut

use strict;
use warnings;

use IPTables::ChainMgr;
use IPTables::Interface;
use Log::Log4perl;
use Readonly;

BEGIN {
    use Exporter ();
    our ( @ISA, @EXPORT );
    @ISA = qw(Exporter);
    @EXPORT = qw(
        iptables_generate iptables_save iptables_restore
        iptables_mark_node iptables_unmark_node get_mangle_mark_for_mac update_mark
    );
}

use pf::class qw(class_view_all class_trappable);
use pf::config;
use pf::node qw(nodes_registered_not_violators);
use pf::util;
use pf::violation qw(violation_view_open_uniq violation_count);

Readonly my $FW_TABLE_FILTER => 'filter';
Readonly my $FW_TABLE_MANGLE => 'mangle';
Readonly my $FW_TABLE_NAT => 'nat';
Readonly my $FW_FILTER_INPUT_INT_VLAN => 'input-internal-vlan-if';
Readonly my $FW_FILTER_INPUT_INT_INLINE => 'input-internal-inline-if';
Readonly my $FW_FILTER_INPUT_MGMT => 'input-management-if';
Readonly my $FW_FILTER_INPUT_INT_HA => 'input-highavailability-if';
Readonly my $FW_FILTER_FORWARD_INT_INLINE => 'forward-internal-inline-if';
Readonly my $FW_FILTER_FORWARD_INT_VLAN => 'forward-internal-vlan-if';
Readonly my $FW_PREROUTING_INT_INLINE => 'prerouting-int-inline-if';
Readonly my $FW_POSTROUTING_INT_INLINE => 'postrouting-int-inline-if';

=head1 SUBROUTINES

TODO: This list is incomplete

=over

=cut

=item new

Constructor

=cut

sub new {
   my $logger = Log::Log4perl::get_logger("pf::iptables");
   $logger->debug("instantiating new pf::iptables object");
   my ( $class, %argv ) = @_;
   my $self = bless {}, $class;
   return $self;
}


sub iptables_generate {
    my ($self) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');

    my %tags = ( 
        'filter_if_src_to_chain' => '', 'filter_forward_inline' => '',
        'filter_forward_vlan' => '', 
        'mangle_if_src_to_chain' => '', 'mangle_prerouting_inline' => '', 
        'nat_if_src_to_chain' => '', 'nat_prerouting_inline' => '', 
        'nat_postrouting_vlan' => '', 'nat_postrouting_inline' => '' 
    );

    # global substitution variables
    $tags{'web_admin_port'} = $Config{'ports'}{'admin'};

    # FILTER
    # per interface-type pointers to pre-defined chains
    $tags{'filter_if_src_to_chain'} .= $self->generate_filter_if_src_to_chain();

    if (is_inline_enforcement_enabled()) {
        # Note: I'm giving references to this guy here so he can directly mess with the tables
        $self->generate_inline_rules(
            \$tags{'filter_forward_inline'}, \$tags{'nat_prerouting_inline'}, \$tags{'nat_postrouting_inline'}
        );
    
        # MANGLE
        $tags{'mangle_if_src_to_chain'} .= $self->generate_inline_if_src_to_chain($FW_TABLE_MANGLE);
        $tags{'mangle_prerouting_inline'} .= $self->generate_mangle_rules();
    
        # NAT chain targets and redirections (other rules injected by generate_inline_rules)
        $tags{'nat_if_src_to_chain'} .= $self->generate_inline_if_src_to_chain($FW_TABLE_NAT);
        $tags{'nat_prerouting_inline'} .= $self->generate_nat_redirect_rules();
    }

    # OAuth
    my $google_enabled = $guest_self_registration{$SELFREG_MODE_GOOGLE};
    my $facebook_enabled = $guest_self_registration{$SELFREG_MODE_FACEBOOK};
    my $github_enabled = $guest_self_registration{$SELFREG_MODE_GITHUB};

    if ($google_enabled || $facebook_enabled || $github_enabled) {
        generate_oauth_rules(
            $google_enabled,$facebook_enabled,$github_enabled,\$tags{'filter_forward_vlan'},\$tags{'nat_postrouting_vlan'}
        );
    }

    # per-feature firewall rules
    # self-registered guest by email or sponsored
    my $guests_enabled = $guest_self_registration{'enabled'};
    my $email_enabled = $guest_self_registration{$SELFREG_MODE_EMAIL};
    my $sponsor_enabled = $guest_self_registration{$SELFREG_MODE_SPONSOR};
    if ($guests_enabled && ($email_enabled || $sponsor_enabled)) {
        $tags{'input_mgmt_guest_rules'} =
            "-A $FW_FILTER_INPUT_MGMT --protocol tcp --match tcp --dport 443 --jump ACCEPT"
        ;
    }
    else {
        $tags{'input_mgmt_guest_rules'} = '';
    }

    chomp(
        $tags{'filter_if_src_to_chain'}, $tags{'filter_forward_inline'},
        $tags{'mangle_if_src_to_chain'}, $tags{'mangle_prerouting_inline'},
        $tags{'nat_if_src_to_chain'}, $tags{'nat_prerouting_inline'},
    );

    parse_template( \%tags, "$conf_dir/iptables.conf", "$generated_conf_dir/iptables.conf" );
    $self->iptables_restore("$generated_conf_dir/iptables.conf");
}


=item generate_filter_if_src_to_chain

Creating proper source interface matches to jump to the right chains for proper enforcement method.

=cut
sub generate_filter_if_src_to_chain {
    my ($self) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $rules = '';

    my $google_enabled = $guest_self_registration{$SELFREG_MODE_GOOGLE};
    my $facebook_enabled = $guest_self_registration{$SELFREG_MODE_FACEBOOK};
    my $github_enabled = $guest_self_registration{$SELFREG_MODE_GITHUB};

    # internal interfaces handling
    foreach my $interface (@internal_nets) {
        my $dev = $interface->tag("int");
        my $ip = $interface->tag("ip");
        my $enforcement_type = $Config{"interface $dev"}{'enforcement'};

        # VLAN enforcement
        if ($enforcement_type eq $IF_ENFORCEMENT_VLAN) {
            $rules .= "-A INPUT --in-interface $dev -d $ip --jump $FW_FILTER_INPUT_INT_VLAN\n";
            $rules .= "-A INPUT --in-interface $dev -d 255.255.255.255 --jump $FW_FILTER_INPUT_INT_VLAN\n";
            
            if ($google_enabled || $facebook_enabled || $github_enabled) {
                $rules .= "-A FORWARD --in-interface $dev --jump $FW_FILTER_FORWARD_INT_VLAN\n";
                $rules .= "-A FORWARD --out-interface $dev --jump $FW_FILTER_FORWARD_INT_VLAN\n";
            }

        # inline enforcement
        } elsif ($enforcement_type eq $IF_ENFORCEMENT_INLINE) {
            my $mgmt_ip = $management_network->tag("ip");
            $rules .= "-A INPUT --in-interface $dev -d $ip --jump $FW_FILTER_INPUT_INT_INLINE\n";
            $rules .= "-A INPUT --in-interface $dev -d 255.255.255.255 --jump $FW_FILTER_INPUT_INT_INLINE\n";
            $rules .= "-A INPUT --in-interface $dev -d $mgmt_ip --protocol tcp --match tcp --dport 443 --jump ACCEPT\n";
            $rules .= "-A FORWARD --in-interface $dev --jump $FW_FILTER_FORWARD_INT_INLINE\n";

        # nothing? something is wrong
        } else {
            $logger->warn("Didn't assign any firewall rules to interface $dev.");
        }
    }

    # management interface handling
    my $mgmt_int = $management_network->tag("int");
    $rules .= "-A INPUT --in-interface $mgmt_int --jump $FW_FILTER_INPUT_MGMT\n";

    # high-availability interfaces handling
    foreach my $interface (@ha_ints) {
        $rules .= "-A INPUT --in-interface $interface --jump $FW_FILTER_INPUT_INT_HA\n";
    }

    # Allow the NAT back inside through the forwarding table if inline is enabled
    if (is_inline_enforcement_enabled()) {
        $rules .= "-A FORWARD --in-interface $mgmt_int --match state --state ESTABLISHED,RELATED --jump ACCEPT\n";
    }

    return $rules;
}


=item generate_inline_rules

Handling both FILTER and NAT tables at the same time.

=cut
sub generate_inline_rules {
    my ($self, $filter_rules_ref, $nat_prerouting_ref, $nat_postrouting_ref) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');

    $logger->info("Adding DNS DNAT rules for unregistered and isolated inline clients.");
    foreach my $network ( keys %ConfigNetworks ) {
        # skip non-inline interfaces
        next if ( !pf::config::is_network_type_inline($network) );

        my $rule = "--protocol udp --destination-port 53";
        $$nat_prerouting_ref .= "-A $FW_PREROUTING_INT_INLINE $rule --match mark --mark 0x$IPTABLES_MARK_UNREG "
                . "--jump REDIRECT\n";
        $$nat_prerouting_ref .= "-A $FW_PREROUTING_INT_INLINE $rule --match mark --mark 0x$IPTABLES_MARK_ISOLATION "
                . "--jump REDIRECT\n";
        last;
    }
    
    $logger->info("Adding NAT Masquarade statement (PAT)");
    $$nat_postrouting_ref .= "-A $FW_POSTROUTING_INT_INLINE --jump MASQUERADE\n";
    

    $logger->info("building firewall to accept registered users through inline interface");
    my $google_enabled = $guest_self_registration{$SELFREG_MODE_GOOGLE};
    my $facebook_enabled = $guest_self_registration{$SELFREG_MODE_FACEBOOK};
    my $github_enabled = $guest_self_registration{$SELFREG_MODE_GITHUB};

    if ($google_enabled) {
        foreach my $ip ( split( /\s*,\s*/, $ConfigOAuth{'google'}{'ips'} ) ) {
            $$filter_rules_ref .= "-A $FW_FILTER_FORWARD_INT_INLINE --match mark --mark 0x$IPTABLES_MARK_UNREG -d $ip --jump ACCEPT\n";
        }
    }

    if ($facebook_enabled) {
        foreach my $ip ( split( /\s*,\s*/, $ConfigOAuth{'facebook'}{'ips'} ) ) {
            $$filter_rules_ref .= "-A $FW_FILTER_FORWARD_INT_INLINE --match mark --mark 0x$IPTABLES_MARK_UNREG -d $ip --jump ACCEPT\n";
        }
    }

    if ($github_enabled) {
        foreach my $ip ( split( /\s*,\s*/, $ConfigOAuth{'github'}{'ips'} ) ) {
            $$filter_rules_ref .= "-A $FW_FILTER_FORWARD_INT_INLINE --match mark --mark 0x$IPTABLES_MARK_UNREG -d $ip --jump ACCEPT\n";
        }
    }

    $$filter_rules_ref .= "-A $FW_FILTER_FORWARD_INT_INLINE --match mark --mark 0x$IPTABLES_MARK_REG --jump ACCEPT\n";
    if (!isenabled($Config{'trapping'}{'registration'})) {
        $logger->info(
            "trapping.registration is disabled, adding rule so we accept unregistered users through inline interface"
        );
        $$filter_rules_ref .=
            "-A $FW_FILTER_FORWARD_INT_INLINE "
            . "--match mark --mark 0x$IPTABLES_MARK_UNREG --jump ACCEPT\n"
        ;
    }
}

=item generate_oauth_rules

Creating the proper firewall rules to allow Google/Facebook OAuth2

=cut
sub generate_oauth_rules {
    my ($google,$facebook,$github,$forward_rules_ref,$nat_rules_ref) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');

    $logger->info("Adding Forward rules to allow connections to the OAuth2 Providers.");
    my $reg_int = "";

    if ($google) {
        foreach my $ip ( split( /\s*,\s*/, $ConfigOAuth{'google'}{'ips'} ) ) {
            $$forward_rules_ref .= "-A $FW_FILTER_FORWARD_INT_VLAN -d $ip --jump ACCEPT\n";
            $$forward_rules_ref .= "-A $FW_FILTER_FORWARD_INT_VLAN -s $ip --jump ACCEPT\n"
        }
    }

    if ($facebook) {
        foreach my $ip ( split( /\s*,\s*/, $ConfigOAuth{'facebook'}{'ips'} ) ) {
            $$forward_rules_ref .= "-A $FW_FILTER_FORWARD_INT_VLAN -d $ip --jump ACCEPT\n";
            $$forward_rules_ref .= "-A $FW_FILTER_FORWARD_INT_VLAN -s $ip --jump ACCEPT\n"
        }
    }

    if ($github) {
        foreach my $ip ( split( /\s*,\s*/, $ConfigOAuth{'github'}{'ips'} ) ) {
            $$forward_rules_ref .= "-A $FW_FILTER_FORWARD_INT_VLAN -d $ip --jump ACCEPT\n";
            $$forward_rules_ref .= "-A $FW_FILTER_FORWARD_INT_VLAN -s $ip --jump ACCEPT\n"
        }
    }

    $logger->info("Adding NAT Masquerade statement.");
    my $mgmt_int = $management_network->tag("int");
    $$nat_rules_ref .= "-A POSTROUTING -o $mgmt_int --jump MASQUERADE";

}

=item generate_inline_if_src_to_chain

Creating proper source interface matches to jump to the right chains for inline enforcement method.

=cut
sub generate_inline_if_src_to_chain {
    my ($self, $table) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $rules = '';

    # internal interfaces handling
    foreach my $interface (@internal_nets) {
        my $dev = $interface->tag("int");
        my $enforcement_type = $Config{"interface $dev"}{'enforcement'};

        # inline enforcement
        if ($enforcement_type eq $IF_ENFORCEMENT_INLINE) {
            # send everything from inline interfaces to the inline chain
            $rules .= "-A PREROUTING --in-interface $dev --jump $FW_PREROUTING_INT_INLINE\n";
        }
    }

    # NAT POSTROUTING
    if ($table eq $FW_TABLE_NAT) {
        my $mgmt_int = $management_network->tag("int");

        # Every marked packet should be NATed
        # Note that here we don't wonder if they should be allowed or not. This is a filtering step done in FORWARD.
        foreach ($IPTABLES_MARK_UNREG, $IPTABLES_MARK_REG, $IPTABLES_MARK_ISOLATION) {
            $rules .= "-A POSTROUTING --out-interface $mgmt_int ";
            $rules .= "--match mark --mark 0x$_ ";
            $rules .= "--jump $FW_POSTROUTING_INT_INLINE";
            $rules .= "\n";
        }
    }

    return $rules;
}

=item generate_mangle_rules

Packet marking will traverse all the rules so the order in which packets are marked is rather important.
The last mark will be the one having an effect.

=cut
sub generate_mangle_rules {
    my ($self) =@_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $mangle_rules = '';

    # pfdhcplistener in most cases will be enforcing access
    # however we insert these marks on startup in case PacketFence is restarted

    # default catch all: mark unreg
    $mangle_rules .= "-A $FW_PREROUTING_INT_INLINE --jump MARK --set-mark 0x$IPTABLES_MARK_UNREG\n";

    # mark registered nodes that should not be isolated
    # TODO performance: mark all *inline* registered users only
    my @registered = nodes_registered_not_violators();
    foreach my $row (@registered) {
        my $mac = $row->{'mac'};
        $mangle_rules .=
            "-A $FW_PREROUTING_INT_INLINE --match mac --mac-source $mac " .
            "--jump MARK --set-mark 0x$IPTABLES_MARK_REG\n"
        ;
    }

    # mark all open violations
    # TODO performance: only those whose's last connection_type is inline?
    my @macarray = violation_view_open_uniq();
    if ( $macarray[0] ) {
        foreach my $row (@macarray) {
            my $mac = $row->{'mac'};
            $mangle_rules .=
                "-A $FW_PREROUTING_INT_INLINE --match mac --mac-source $mac " .
                "--jump MARK --set-mark 0x$IPTABLES_MARK_ISOLATION\n"
            ;
        }
    }

    # mark whitelisted users
    # TODO whitelist concept on it's way to the graveyard
    foreach my $mac ( split( /\s*,\s*/, $Config{'trapping'}{'whitelist'} ) ) {
        $mangle_rules .=
            "-A $FW_PREROUTING_INT_INLINE --match mac --mac-source $mac --jump MARK --set-mark 0x$IPTABLES_MARK_REG\n"
        ;
    }

    # mark blacklisted users
    # TODO blacklist concept on it's way to the graveyard
    foreach my $mac ( split( /\s*,\s*/, $Config{'trapping'}{'blacklist'} ) ) {
        $mangle_rules .=
            "-A $FW_PREROUTING_INT_INLINE --match mac --mac-source $mac --jump MARK --set-mark $IPTABLES_MARK_ISOLATION\n"
        ;
    }

    return $mangle_rules;
}

=item generate_nat_redirect_rules

=cut
sub generate_nat_redirect_rules {
    my ($self) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $rules = '';

    # Exclude the OAuth from the DNAT
    my $google_enabled = $guest_self_registration{$SELFREG_MODE_GOOGLE};
    my $facebook_enabled = $guest_self_registration{$SELFREG_MODE_FACEBOOK};
    my $github_enabled = $guest_self_registration{$SELFREG_MODE_GITHUB};

    if ($google_enabled) {
         foreach my $ip ( split( /\s*,\s*/, $ConfigOAuth{'google'}{'ips'} ) ) {
             $rules .= "-A $FW_PREROUTING_INT_INLINE --protocol tcp -d $ip --destination-port 443 ".
                   "--match mark --mark 0x$IPTABLES_MARK_UNREG --jump ACCEPT\n";
         }
    }

    if ($facebook_enabled) {
        foreach my $ip ( split( /\s*,\s*/, $ConfigOAuth{'facebook'}{'ips'} ) ) {
             $rules .= "-A $FW_PREROUTING_INT_INLINE --protocol tcp -d $ip --destination-port 443 ".
                       "--match mark --mark 0x$IPTABLES_MARK_UNREG --jump ACCEPT\n";
        } 
    }

    if ($github_enabled) {
         foreach my $ip ( split( /\s*,\s*/, $ConfigOAuth{'github'}{'ips'} ) ) {
             $rules .= "-A $FW_PREROUTING_INT_INLINE --protocol tcp -d $ip --destination-port 443 ".
                   "--match mark --mark 0x$IPTABLES_MARK_UNREG --jump ACCEPT\n";
         }
    }
    
    # Now, do your magic
    foreach my $redirectport ( split( /\s*,\s*/, $Config{'inline'}{'ports_redirect'} ) ) {
        my ( $port, $protocol ) = split( "/", $redirectport );

        # Destination NAT to the portal on the UNREG mark if trapping.registration is enabled
        if ( isenabled( $Config{'trapping'}{'registration'} ) ) {
            $rules .=
                "-A $FW_PREROUTING_INT_INLINE --protocol $protocol --destination-port $port " .
                "--match mark --mark 0x$IPTABLES_MARK_UNREG --jump REDIRECT\n"
            ;
        }

        # Destination NAT to the portal on the ISOLATION mark
        $rules .=
            "-A $FW_PREROUTING_INT_INLINE --protocol $protocol --destination-port $port " .
            "--match mark --mark 0x$IPTABLES_MARK_ISOLATION --jump REDIRECT\n"
        ;
    }
    return $rules;
}

sub iptables_mark_node {
    my ( $self, $mac, $mark ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $iptables = IPTables::Interface::new('mangle')
        || logger->logcroak("unable to create IPTables::Interface object");

    $logger->debug("marking node $mac with mark 0x$mark");
    my $success = $iptables->iptables_do_command(
        "-A $FW_PREROUTING_INT_INLINE", "--match mac --mac-source $mac", "--jump MARK --set-mark 0x$mark"
    );

    if (!$success) {
        $logger->error("Unable to mark mac $mac: $!");
        return;
    }
    $iptables->commit();
    return (1);
}

sub iptables_unmark_node {
    my ( $self, $mac, $mark ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $iptables = IPTables::Interface::new('mangle')
        || logger->logcroak("unable to create IPTables::Interface object");

    $logger->debug("removing mark 0x$mark on node $mac");
    my $success = $iptables->iptables_do_command(
        "-D $FW_PREROUTING_INT_INLINE", "--match mac --mac-source $mac", "--jump MARK --set-mark 0x$mark"
    );

    if (!$success) {
        $logger->error("Unable to unmark mac $mac: $!");
        return;
    }
    $iptables->commit();
    return (1);
}

=item get_mangle_mark_for_mac

Fetches the current mangle mark for a given mark.
Useful to re-evaluate what to do with a given node who's state changed.

Returns IPTABLES MARK constant ($IPTABLES_MARK_...) or undef on failure.

=cut
# TODO migrate to IPTables::Interface (to get rid of IPTables::ChainMgr) once it supports fetching iptables info
sub get_mangle_mark_for_mac {
    my ( $self, $mac ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $iptables = new IPTables::ChainMgr('ipt_exec_style' => 'system')
        || logger->logcroak("unable to create IPTables::ChainMgr object");
    my $iptables_cmd = $iptables->{'_iptables'};

    # list mangle rules
    my ($rv, $out_ar, $errs_ar) = $iptables->run_ipt_cmd("$iptables_cmd -t mangle -L -v -n");
    if ($rv) {
        # MAC in iptables -L -nv are uppercase
        $mac = uc($mac);
        foreach my $ipt_line (@$out_ar) {
            chomp($ipt_line);
            # matching with end of line ($) for performance
            # saw some instances were a space was present at the end of the line
            if ($ipt_line =~ /MAC $mac MARK set 0x(\d+)\s*$/) {
                return $1;
            }
        }
    } else {
        if (@$errs_ar) {
            $logger->error("Unable to list iptables mangle table: $!");
            return;
        }
    }
    # if we didn't find him it means it's the catch all which is
    return $IPTABLES_MARK_UNREG;
}

=item update_mark

This sub lives under the guarantee that there is a change, that if old_mark == new_mark it won't be called

=cut
# TODO wrap this into the commit transaction system of IPTables::Interface
# TODO once updated, we should re-validate that the marks are ok and re-try otherwise (maybe in a loop)
sub update_mark {
    my ($self , $mac, $old_mark, $new_mark) = @_;

    $self->iptables_unmark_node($mac, $old_mark);
    $self->iptables_mark_node($mac, $new_mark);
    return 1;
}

sub iptables_save {
    my ($self, $save_file) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    $logger->info( "saving existing iptables to " . $save_file );
    pf_run("/sbin/iptables-save -t nat > $save_file");
    pf_run("/sbin/iptables-save -t mangle >> $save_file");
    pf_run("/sbin/iptables-save -t filter >> $save_file");
}

sub iptables_restore {
    my ($self, $restore_file) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    if ( -r $restore_file ) {
        $logger->info( "restoring iptables from " . $restore_file );
        pf_run("/sbin/iptables-restore < $restore_file");
    }
}

sub iptables_restore_noflush {
    my ($self, $restore_file) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    if ( -r $restore_file ) {
        $logger->info(
            "restoring iptables (no flush) from " . $restore_file );
        pf_run("/sbin/iptables-restore -n < $restore_file");
    }
}

=back

=head1 NOT REIMPLEMENTED

These were features of the previous arp | dhcp modes that were not re-implemented for the reintroduction
of the inline mode because of time constraints.

=over

=item generate_filter_input_listeners

=cut
sub generate_filter_input_listeners {
    my ($self) = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $rules = '';

    # TODO to integrate and might need to adjust other tables too (NAT's dnat)
    my @listeners = split( /\s*,\s*/, $Config{'ports'}{'listeners'} );
    foreach my $listener (@listeners) {
        my $port = getservbyname( $listener, "tcp" );
        $rules .= "--protocol tcp --destination-port $port --jump ACCEPT\n";
    }

    return $rules;
}


=item generate_filter_forward_scanhost

=cut
sub generate_filter_forward_scanhost {
    my @self = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $filter_rules = '';

    # TODO don't forget to also add statements to the PREROUTING nat table as in generate_inline_rules
    my $scan_server = $Config{'scan'}{'host'};
    if ( $scan_server !~ /^127\.0\.0\.1$/ && $scan_server !~ /^localhost$/i ) {
        $filter_rules .= "-A FORWARD --destination $scan_server --jump ACCEPT";
        $filter_rules .= "-A FORWARD --source $scan_server --jump ACCEPT";
        $logger->info("adding Nessus FILTER passthrough for $scan_server");
    }

    return $filter_rules;
}


=item generate_passthrough

=cut
# TODO don't forget to also add statements to the PREROUTING nat table as in generate_inline_rules
#
# I also took that piece of out of generate_nat_redirect_rules() that is probably required
#
#my @trapvids = class_trappable();
#foreach my $row (@trapvids) {
# my $vid = $row->{'vid'};
# $rules .=
# "-A $FW_PREROUTING_INT_INLINE --protocol $protocol --destination-port $port " .
# "--match mark --mark 0x$vid --jump REDIRECT\n"
# ;
#}
#

sub generate_passthrough {
    my @self = @_;
    my $logger = Log::Log4perl::get_logger('pf::iptables');
    my $filter_rules = '';

    # poke passthroughs
    my %passthroughs;
    %passthroughs = %{ $Config{'passthroughs'} } if ( $Config{'trapping'}{'passthrough'} =~ /^iptables$/i );
    $passthroughs{'trapping.redirecturl'} = $Config{'trapping'}{'redirecturl'} if ($Config{'trapping'}{'redirecturl'});
    foreach my $passthrough ( keys %passthroughs ) {
        if ( $passthroughs{$passthrough} =~ /^(http|https):\/\// ) {
            my $destination;
            my ($service, $host, $port, $path) =
                $passthroughs{$passthrough} =~ /^(\w+):\/\/(.+?)(:\d+){0,1}(\/.*){0,1}$/;
            $port =~ s/:// if $port;

            $port = 80 if ( !$port && $service =~ /^http$/i );
            $port = 443 if ( !$port && $service =~ /^https$/i );

            my ( $name, $aliases, $addrtype, $length, @addrs ) = gethostbyname($host);
            if ( !@addrs ) {
                $logger->error("unable to resolve $host for passthrough");
                next;
            }
            foreach my $addr (@addrs) {
                $destination = join( ".", unpack( 'C4', $addr ) );
                $filter_rules
                    .= internal_append_entry(
                    "-A FORWARD --protocol tcp --destination $destination --destination-port $port --jump ACCEPT"
                    );
                $logger->info("adding FILTER passthrough for $passthrough");
            }
        } elsif ( $passthroughs{$passthrough} =~ /^(\d{1,3}.){3}\d{1,3}(\/\d+){0,1}$/ ) {
            $logger->info("adding FILTER passthrough for $passthrough");
            $filter_rules .= internal_append_entry(
                "-A FORWARD --destination " . $passthroughs{$passthrough} . " --jump ACCEPT"
            );
        } else {
            $logger->error("unrecognized passthrough $passthrough");
        }
    }

    # poke holes for content URLs
    # can we collapse with above?
    if ( $Config{'trapping'}{'passthrough'} eq "iptables" ) {
        my @contents = class_view_all();
        foreach my $content (@contents) {
            my $vid = $content->{'vid'};
            my $url = $content->{'url'};
            my $max_enable_url = $content->{'max_enable_url'};
            my $redirect_url = $content->{'redirect_url'};

            foreach my $u ( $url, $max_enable_url, $redirect_url ) {

                # local content or null URLs
                next if ( !$u || $u =~ /^\// );
                if ( $u !~ /^(http|https):\/\// ) {
                    $logger->error("vid $vid: unrecognized content URL: $u");
                    next;
                }

                my $destination;
                my ( $service, $host, $port, $path ) = $u =~ /^(\w+):\/\/(.+?)(:\d+){0,1}(\/.*){0,1}$/;

                $port =~ s/:// if $port;

                $port = 80 if ( !$port && $service =~ /^http$/i );
                $port = 443 if ( !$port && $service =~ /^https$/i );

                my ( $name, $aliases, $addrtype, $length, @addrs ) = gethostbyname($host);
                if ( !@addrs ) {
                    $logger->error("unable to resolve $host for content passthrough");
                    next;
                }
                foreach my $addr (@addrs) {
                    $destination = join( ".", unpack( 'C4', $addr ) );
                    $filter_rules .= internal_append_entry(
                        "-A FORWARD --protocol tcp --destination $destination --destination-port $port --match mark --mark 0x$vid --jump ACCEPT"
                    );
                    $logger->info("adding FILTER passthrough for $destination:$port");
                }
            }
        }
    }

    my @trapvids = class_trappable();
    foreach my $row (@trapvids) {
        my $vid = $row->{'vid'};
        $filter_rules .= internal_append_entry("-A FORWARD --match mark --mark 0x$vid --jump DROP");
    }

    # allowed established sessions from pf box
    $filter_rules .= "-A INPUT --match state --state RELATED,ESTABLISHED --jump ACCEPT\n";

    return $filter_rules;
}

=item update_node

Update session when the ip address change

=cut

sub update_node {
    #Just to have an iptables method
}

=back

=head1 AUTHOR

Olivier Bilodeau <obilodeau@inverse.ca>

David LaPorte <david@davidlaporte.org>

Kevin Amorin <kev@amorin.org>

=head1 COPYRIGHT

Copyright (C) 2005 David LaPorte

Copyright (C) 2005 Kevin Amorin

Copyright (C) 2011 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301,
USA.

=cut

1;
