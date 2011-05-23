use strict;
use warnings;

package BarnOwl::Message::Meta;

use base qw( BarnOwl::Message );

sub is_ping     { return (lc(shift->opcode) eq "ping"); }
sub opcode      { return shift->{"opcode"}; }
sub is_meta     { return 1; }

1;
