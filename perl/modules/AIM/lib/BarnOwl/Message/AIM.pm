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
    return shift->{sender_alias};
}

sub long_sender {
    my $m = shift;
    if ($m->{direction} eq 'out') { # this is a kludge to get the recipient alias to display on outgoing messages
        return $m->{recipient_alias};
    }
    return $m->{sender_alias};
}

1;
