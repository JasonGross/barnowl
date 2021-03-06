use strict;
use warnings;

package BarnOwl::Message::Zephyr;

use constant WEBZEPHYR_PRINCIPAL => "daemon/webzephyr.mit.edu";
use constant WEBZEPHYR_CLASS     => "webzephyr";
use constant WEBZEPHYR_OPCODE    => "webzephyr";

use base qw( BarnOwl::Message );

sub strip_realm {
    my $sender = shift;
    my $realm = BarnOwl::zephyr_getrealm();
    $sender =~ s/\@\Q$realm\E$//;
    return $sender;
}

sub principal_realm {
    my $principal = shift;
    my ($user, $realm) = split(/@/,$principal);
    return $realm;
}

sub casefold_principal {
    my $principal = shift;
    # split the principal right after the final @, without eating any
    # characters; this way, we always get at least '@' in $user
    my ($user, $realm) = split(/(?<=@)(?=[^@]+$)/, $principal);
    $user = '' if !defined $user;
    $user = lc($user);
    $user = $user . uc($realm) if defined $realm;
    return $user;
}

sub login_type {
    return (shift->zsig eq "") ? "(PSEUDO)" : "";
}

sub login_extra {
    my $m = shift;
    return undef if (!$m->is_loginout);
    my $s = lc($m->host);
    $s .= " " . $m->login_tty if defined $m->login_tty;
    return $s;
}

sub long_sender {
    my $m = shift;
    return $m->zsig;
}

sub context {
    return shift->class;
}

sub subcontext {
    return shift->instance;
}

sub login_tty {
    my ($m) = @_;
    return undef if (!$m->is_loginout);
    return undef if (!defined($m->fields));
    return $m->fields->[2];
}

sub login_host {
    my ($m) = @_;
    return undef if (!$m->is_loginout);
    return undef if (!defined($m->fields));
    return $m->fields->[0];
}

sub zwriteline  { return shift->{"zwriteline"}; }

sub is_ping     { return (lc(shift->opcode) eq "ping"); }

sub is_mail {
    my ($m) = @_;
    return ((lc($m->class) eq "mail") && $m->is_private);
}

sub pretty_sender {
    my ($m) = @_;
    return strip_realm($m->sender);
}

sub pretty_recipient {
    my ($m) = @_;
    return strip_realm($m->recipient);
}

# Portion of the reply command that preserves the context
sub context_reply_cmd {
    my $mclass = shift;
    my $minstance = shift;
    my @class;
    if (lc($mclass) ne "message") {
        @class = ('-c', $mclass);
    }
    my @instance;
    if (lc($minstance) ne "personal") {
        @instance = ('-i', $minstance);
    }
    return (@class, @instance);
}

sub personal_context {
    my ($m) = @_;
    return BarnOwl::quote(context_reply_cmd($m->class, $m->instance));
}

sub short_personal_context {
    my ($m) = @_;
    if(lc($m->class) eq 'message')
    {
        if(lc($m->instance) eq 'personal')
        {
            return '';
        } else {
            return $m->instance;
        }
    } else {
        return $m->class;
    }
}

# These are arguably zephyr-specific
sub class       { return shift->{"class"}; }
sub instance    { return shift->{"instance"}; }
sub realm       { return shift->{"realm"}; }
sub opcode      { return shift->{"opcode"}; }
sub host        { return shift->{"hostname"}; }
sub hostname    { return shift->{"hostname"}; }
sub header      { return shift->{"header"}; }
sub auth        { return shift->{"auth"}; }
sub fields      { return shift->{"fields"}; }
sub zsig        { return shift->{"zsig"}; }

sub zephyr_cc {
    my $self = shift;
    return $1 if $self->body =~ /^\s*cc:\s+([^\n]+)/i;
    return undef;
}

# Note: This is the cc-line without the recipient; it does not include
# the sender.
sub zephyr_cc_without_recipient {
    my $self = shift;
    my $recipient = lc(strip_realm($self->recipient));
    my $cc = $self->zephyr_cc;
    return grep { lc(strip_realm($_)) ne $recipient } split(/\s+/, $cc) if defined $cc;
    return ();
}

sub replycmd {
    my $self = shift;
    my $sender = shift;
    $sender = 0 unless defined $sender;
    my ($class, $instance, $to, $cc);
    if($self->is_outgoing) {
        return $self->{zwriteline};
    }

    if($sender && $self->opcode eq WEBZEPHYR_OPCODE) {
        $class = WEBZEPHYR_CLASS;
        $instance = $self->pretty_sender;
        $instance =~ s/-webzephyr$//;
        $to = WEBZEPHYR_PRINCIPAL;
    } elsif($self->class eq WEBZEPHYR_CLASS
            && $self->is_loginout) {
        $class = WEBZEPHYR_CLASS;
        $instance = $self->instance;
        $to = WEBZEPHYR_PRINCIPAL;
    } elsif($self->is_loginout) {
        $class = 'MESSAGE';
        $instance = 'PERSONAL';
        $to = $self->sender;
    } elsif($sender && !$self->is_private) {
        # Possible future feature: (Optionally?) include the class and/or
        # instance of the message being replied to in the instance of the 
        # outgoing personal reply
        $class = 'MESSAGE';
        $instance = 'PERSONAL';
        $to = $self->sender;
    } else {
        $class = $self->class;
        $instance = $self->instance;
        if ($self->recipient eq '' || $self->recipient =~ /^@/) {
            $to = $self->recipient;
        } else {
            $to = $self->sender;
            $cc = $self->zephyr_cc();
        }
    }

    my @cmd;
    if(lc $self->opcode eq 'crypt' and ( not $sender or $self->is_private)) {
        # Responses to zcrypted messages should be zcrypted, so long as we
        # aren't switching to personals
        @cmd = ('zcrypt');
    } else {
        @cmd = ('zwrite');
    }

    push @cmd, context_reply_cmd($class, $instance);

    if ($to ne '') {
        $to = strip_realm($to);
        if (defined $cc and not $sender) {
            my @cc = grep /^[^-]/, ($to, split /\s+/, $cc);
            my %cc = map {$_ => 1} @cc;
            # this isn't quite right - it doesn't strip off the
            # user if the message was addressed to them by fully qualified
            # name
            delete $cc{strip_realm(BarnOwl::zephyr_getsender())};
            @cc = keys %cc;

            my $sender_realm = principal_realm($self->sender);
            if (BarnOwl::zephyr_getrealm() ne $sender_realm) {
                @cc = map {
                    if($_ !~ /@/) {
                       "${_}\@${sender_realm}";
                    } else {
                        $_;
                    }
                } @cc;
            }
            push @cmd, '-C', @cc;
        } else {
            if(BarnOwl::getvar('smartstrip') eq 'on') {
                $to = BarnOwl::zephyr_smartstrip_user($to);
            }
            push @cmd, $to;
        }
    }
    return BarnOwl::quote(@cmd);
}

sub replysendercmd {
    my $self = shift;
    return $self->replycmd(1);
}

# Logging
sub log_header {
    my ($m) = @_;
    my $class = $m->class;
    my $instance = $m->instance;
    my $opcode = $m->opcode;
    my $timestr = $m->time;
    my $host = $m->host;
    my $sender = $m->pretty_sender;
    my $zsig = $m->zsig;
    my $rtn = "Class: $class Instance: $instance";
    $rtn .= " Opcode: $opcode" unless !defined $opcode || $opcode eq '';
    $rtn .= "\nTime: $timestr Host: $host"
          . "\nFrom: $zsig <$sender>";
    return $rtn;
}

sub log_filenames {
    my ($m) = @_;
    my @filenames = ();
    if ($m->is_personal) {
        # If this has CC's, add all but the "recipient" which we'll add below
        @filenames = $m->zephyr_cc_without_recipient;
    }
    if ($m->is_incoming) {
        if ($m->is_personal) {
            push @filenames, $m->sender;
        } else {
            my $realm = '';
            $realm .= '@' . $m->realm if $m->realm ne BarnOwl::zephyr_getrealm();
            return (BarnOwl::compat_casefold($m->class) . uc($realm));
        }
    } else {
        push @filenames, $m->recipient;
    }
    return map { casefold_principal(BarnOwl::zephyr_smartstrip_user(strip_realm($_))) } @filenames;
}

sub log_to_class_file {
    my ($m) = @_;
    return !$m->is_personal;
}

sub log_path {
    my ($m) = @_;
    if ($m->log_to_class_file) {
        return BarnOwl::getvar('classlogpath');
    } else {
        return BarnOwl::getvar('logpath');
    }
}

sub should_log {
    my ($m) = @_;
    if ($m->log_to_class_file) {
        return BarnOwl::getvar('classlogging') eq 'on';
    } else {
        return BarnOwl::getvar('logging') eq 'on';
    }
}

1;
