use strict;
use warnings;

package BarnOwl::Message::Admin;

use base qw( BarnOwl::Message );

sub header       { return shift->{"header"}; }

sub log_header {
    my ($m) = @_;
    return "Admin Message: " . $m->header . "\nTime: " . $m->time;
}

sub log_filenames { return ('admin'); }

sub should_log { return BarnOwl::getvar('logadmin') eq 'on'; }

1;
