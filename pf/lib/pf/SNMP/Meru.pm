package pf::SNMP::Meru;

=head1 NAME

pf::SNMP::Meru - Object oriented module to manage Meru controllers

=cut

use strict;
use warnings;
use diagnostics;

use base ('pf::SNMP');
use POSIX;
use Log::Log4perl;
use Net::Appliance::Session;

use pf::config;
# importing switch constants
use pf::SNMP::constants;
use pf::util;

=head1 STATUS

Tested against MeruOS version 3.6.1-6.7

=head1 BUGS AND LIMITATIONS

Based on CLI access.
 
=head1 SUBROUTINES

=over

=item deauthenticateMac

deauthenticate a MAC address from wireless network

Right now te only way to do it is from the CLi (through Telnet or SSH).

=cut
sub deauthenticateMac {
    my ( $this, $mac ) = @_;
    my $logger = Log::Log4perl::get_logger( ref($this) );

    if ( !$this->isProductionMode() ) {
        $logger->info("not in production mode ... we won't deauthenticate $mac");
        return 1;
    }

    if ( length($mac) != 17 ) {
        $logger->error("MAC format is incorrect ($mac). Should be xx:xx:xx:xx:xx:xx");
        return 1;
    }

    my $session;
    eval {
        $session = Net::Appliance::Session->new(
            Host      => $this->{_ip},
            Timeout   => 5,
            Transport => $this->{_cliTransport},
            Platform => 'MeruOS',
            Source   => $lib_dir.'/pf/SNMP/Meru/nas-pb.yml'
        );
        $session->connect(
            Name     => $this->{_cliUser},
            Password => $this->{_cliPwd}
        );
    };

    if ($@) {
        $logger->error("Unable to connect to ".$this->{'_ip'}." using ".$this->{_cliTransport}.". Failed with $@");
        return;
    }

    #if (!$session->in_privileged_mode()) {
    #    if (!$session->enable($this->{_cliEnablePwd})) {
    #        $logger->error("Cannot get into privileged mode on ".$this->{'ip'}.
    #                       ". Are you sure you provided enable password in configuration?");
    #        $session->close();
    #        return;
    #    }
    #}

    # if $session->begin_configure() does not work, use the following command:
    # my $command = "configure terminal\nno station $mac\n";
    my $command = "no station $mac";

    $logger->info("Deauthenticating mac $mac");
    $logger->trace("sending CLI command '$command'");
    my @output;
    $session->in_privileged_mode(1);
    eval { 
        $session->begin_configure();
        @output = $session->cmd(String => $command, Timeout => '10');
    };
    $session->in_privileged_mode(0);
    if ($@) {
        $logger->error("Unable to deauthenticate $mac: $@");        
        $session->close();
        return;
    }
    $session->close();
    return 1;
}

=back

=head1 AUTHOR

Francois Gaudreault <fgaudreault@inverse.ca>

Regis Balzard <rbalzard@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2010 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;