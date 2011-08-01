use strict;
use warnings;

package BarnOwl::Complete::AIM;

use BarnOwl::Completion::Util qw(complete_flags);

our %_users;

sub complete_user { keys %_users }

sub on_user_login {
    my $who = _canonicalize_aim(shift);
    $_users{$who} ||= 'login';
}

sub on_user_logout {
    my $who = _canonicalize_aim(shift);
    delete $_users{$who} if $_users{$who} && $_users{$who} eq 'login';
}

sub add_user {
    my $who = _canonicalize_aim(shift);
    $_users{$who} = 1;
}

sub _canonicalize_aim {
    my $who = shift;
    $who =~ s{ }{}g;
    return lc $who;
}

sub _new_complete_account($) {
    my $oscars_ref = shift;
    my $complete_account = sub {
        return map { _canonicalize_aim($_->screenname) } (values %$oscars_ref);
    };
    return $complete_account;
}

sub _new_complete_aimwrite($) {
    my $oscar_ref = shift;
    my $complete_account = _new_complete_account($oscar_ref);
    my $complete_aimwrite = sub {
        my $ctx = shift;
        return complete_flags($ctx,
                              [qw(-a)],
                              {
                                  "-a"        => $complete_account
                              },
                              \&complete_user
            );
    };
    return $complete_aimwrite;
}

sub register_completer($) {
    my $oscar_ref = shift;
    my $complete_aimwrite = _new_complete_aimwrite($oscar_ref);
    BarnOwl::Completion::register_completer(aimwrite => $complete_aimwrite);
}

1;
