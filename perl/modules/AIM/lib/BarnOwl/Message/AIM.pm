use strict;
use warnings;

package BarnOwl::Message::AIM;

use base qw( BarnOwl::Message );

# all non-loginout AIM messages are private for now...
sub is_private {
    return !(shift->is_loginout);
}

sub replycmd {
    my $self = shift;
    if ($self->is_incoming) {
        return BarnOwl::quote('aimwrite', '-a', $self->recipient, $self->sender);
    } else {
        return BarnOwl::quote('aimwrite', '-a', $self->sender, $self->recipient);
    }
}

sub replysendercmd {
    return shift->replycmd;
}

sub login_extra {
    my $alias = shift->{sender_alias};
    return (defined $alias ? $alias : '');
}

sub long_sender {
    my $m = shift;
    my $alias;
    if ($m->{direction} eq 'out') { # this is a kludge to get the recipient alias to display on outgoing messages
        $alias = $m->{recipient_alias};
    } else {
        $alias = $m->{sender_alias};
    }
    return (defined $alias ? $alias : '');
}

1;
