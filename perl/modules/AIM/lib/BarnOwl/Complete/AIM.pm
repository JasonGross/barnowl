use strict;
use warnings;

package BarnOwl::Complete::AIM;

use Getopt::Long;
Getopt::Long::Configure(qw(no_getopt_compat prefix_pattern=-|--));
use List::MoreUtils qw(uniq);

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
    $who =~ s{\s}{}g;
    return lc $who;
}

sub _new_complete_account($) {
    my $oscars_ref = shift;
    return sub {
        use Data::Dumper;
        BarnOwl::admin_message('aim', Dumper($oscars_ref));
        return map { _canonicalize_aim($_->screenname) } (values %$oscars_ref);
    };
}

sub _new_complete_group($) {
    my $oscars_ref = shift;
    return sub {
        my $ctx = shift;
        my $account;
        Getopt::Long::Configure('pass_through', 'no_getopt_compat');
        Getopt::Long::GetOptionsFromArray($ctx->words,
            'account=s' => \$account
        );
        my $account_oscar = $oscars_ref->{$account};
        my @oscars = (defined $account_oscar ? ($account_oscar) : (values %$oscars_ref));
        my @groups;
        foreach my $oscar (@oscars) {
            push @groups, $oscar->groups;
        }
        @groups = uniq sort @groups;
        return @groups;
    };
}

sub _new_complete_aimwrite($) {
    my $oscars_ref = shift;
    my $complete_account = _new_complete_account($oscars_ref);
    return sub {
        my $ctx = shift;
        return complete_flags(
            $ctx,
            [],
            {
                "-a"        => $complete_account
            },
            \&complete_user
        );
    };
}

sub _new_complete_only_account($) {
    my $oscars_ref = shift;
    my $complete_account = _new_complete_account($oscars_ref);
    return sub {
        my $ctx = shift;
        return complete_flags(
            $ctx,
            [],
            {},
            \&complete_account
        );
    };
}

sub _new_complete_adddelbuddy($) {
    my $oscars_ref = shift;
    my $complete_account = _new_complete_account($oscars_ref);
    my $complete_group = _new_complete_group($oscars_ref);
    return sub {
        my $ctx = shift;
        return complete_flags(
            $ctx,
            [],
            {
                "-a"        => $complete_account,
                "-g"        => $complete_group
            },
            \&complete_user
        );
    };
}

sub register_completers($) {
    my $oscars_ref = shift;
    my $complete_aimwrite = _new_complete_aimwrite($oscars_ref);
    BarnOwl::Completion::register_completer(aimwrite => $complete_aimwrite);

    my $complete_only_account = _new_complete_only_account($oscars_ref);
    BarnOwl::Completion::register_completer(aimlogout => $complete_only_account);
    BarnOwl::Completion::register_completer(alist => $complete_only_account);

    my $complete_adddelbuddy = _new_complete_adddelbuddy($oscars_ref);
    BarnOwl::Completion::register_completer('aim:addbuddy' => $complete_adddelbuddy);
    BarnOwl::Completion::register_completer('aim:delbuddy' => $complete_adddelbuddy);
}

1;
