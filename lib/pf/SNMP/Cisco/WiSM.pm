package pf::SNMP::Cisco::WiSM;

=head1 NAME

pf::SNMP::Cisco::WiSM - Object oriented module to parse SNMP traps and manage 
Cisco Wireless Services Module (WiSM)

=head1 STATUS

It should work on all 6500 WiSM modules and maybe 7500.

=cut

use strict;
use warnings;
use Log::Log4perl;
use Net::SNMP;
use base ('pf::SNMP::Cisco::WLC_4400');

=head1 BUGS AND LIMITATIONS

=over

=item Version specific issues

Controller issue with Windows 7: It only works with IOS > 6.x in 802.1x+WPA2. It's not a PacketFence issue.

With IOS 6.0.182.0 we had intermittent issues with DHCP. Disabling DHCP Proxy resolved it. Not a PacketFence issue.

With IOS 7.0.116 and 7.0.220, the SNMP deassociation is not working if using WPA2.  It only works if using an
Open SSID.

=item flexconnect (H-REAP) limitations

Access Points in Hybrid Remote Edge Access Point (H-REAP) mode, now known as 
flexconnect, don't support RADIUS dynamic VLAN assignments (AAA override).

Customer specific work-arounds are possible. For example: per-SSID registration, auto-registration, etc.

=back

=head1 AUTHOR

Olivier Bilodeau <obilodeau@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2010, 2012 Inverse inc.

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

# vim: set shiftwidth=4:
# vim: set expandtab:
# vim: set backspace=indent,eol,start: