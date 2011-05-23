use strict;
use warnings;

package BarnOwl::Message::Meta;

use base qw( BarnOwl::Message );

sub is_ping     { return (lc(shift->opcode) eq "ping"); }
sub opcode      { return shift->{"opcode"}; }
sub is_meta     { return 1; }
sub is_personal { return 0; } # Kludge to not boldify in the default style.  This is perhaps the wrong way to do things.

1;
