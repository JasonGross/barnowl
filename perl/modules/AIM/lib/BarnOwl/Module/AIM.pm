use strict;
use warnings;

package BarnOwl::Module::AIM;
=head1 NAME

BarnOwl::Module::AIM

=head1 DESCRIPTION

BarnOwl module implementing AIM support via Net::OSCAR

=cut

use BarnOwl;
use BarnOwl::Hooks;
use BarnOwl::Message::AIM;
use BarnOwl::Complete::AIM;
use BarnOwl::Timer;

use POSIX qw(strftime);
use Time::Duration;
use Data::Dumper;

use Net::OSCAR;

use Getopt::Long;
Getopt::Long::Configure(qw(no_getopt_compat prefix_pattern=-|--));

use utf8;

our %vars;

use constant {
    MIN_IDLE_SECONDS_TO_SET_IDLE => 60
};

#####################################################################
# XXX FIX:
#  * aimset foo alias bar doesn't persist between login sessions
#
# TODO:
#  * Implement typing notifications
#  * Completion for things other than aimwrite
#  * Maybe impplement the following?
#    - eviling
#    - sending files
#    - changing (and displaying?) buddy icons (ASCII art?)
#    - stealth mode
#    - confirm user's account?
#    - auto-away?
#    - buddy list transfers?
#    - group permissions?
#    - visibility
#    - permit/deny list
#    - get buddy list limits
#    - add/remove buddy list groups
#    - rename (and reorder?) buddy list groups
#    - get the group of a buddy?
#    - search for buddies by email (requires extending Net::OSCAR; see http://iserverd.khstu.ru/oscar/snac_0a_02.html)
# * support ICQ
#####################################################################

sub onStart {
    $vars{is_away} = 0;
    $vars{away_msg} = '';
    register_owl_commands();
    register_keybindings();
    register_filters();
    register_owl_variables();
    $BarnOwl::Hooks::getBuddyList->add("BarnOwl::Module::AIM::on_get_buddy_list");
    $BarnOwl::Hooks::getQuickstart->add("BarnOwl::Module::AIM::on_get_quick_start");
    $BarnOwl::Hooks::addBuddy->add("BarnOwl::Module::AIM::on_add_buddy");
    $BarnOwl::Hooks::deleteBuddy->add("BarnOwl::Module::AIM::on_delete_buddy");
    $BarnOwl::Hooks::awayOn->add("BarnOwl::Module::AIM::on_away_on");
    $BarnOwl::Hooks::awayOff->add("BarnOwl::Module::AIM::on_away_off");
    $BarnOwl::Hooks::getIsAway->add("BarnOwl::Module::AIM::on_get_is_away");
    # Net::OSCAR::Buddylist is a tied hash with screennames as keys.  This is what we want.
    $vars{oscars} = Net::OSCAR::Utility::bltie();
    $vars{chats} = Net::OSCAR::Utility::bltie();
    $vars{buddies} = Net::OSCAR::Utility::bltie(); # for preventing duplicate login/logout notifications
    BarnOwl::register_idle_watcher(name => "AIM Idle Watcher", after => MIN_IDLE_SECONDS_TO_SET_IDLE,
                                   callback => sub {
                                       my ($is_idle) = @_;
                                       my $idle_time = ($is_idle ? BarnOwl::getidletime() : 0);
                                       foreach my $oscar (get_oscars()) {
                                           $oscar->set_idle($idle_time);
                                       }
                                   });
}

$BarnOwl::Hooks::startup->add("BarnOwl::Module::AIM::onStart");

sub register_owl_commands() {
    BarnOwl::new_command(aimlogin => \&cmd_aimlogin,
                         {
                             summary     => "login to an AIM account",
                             usage       => "aimlogin <screenname> [<password>]"
                         });
    BarnOwl::new_command(aimlogout => \&cmd_aimlogout,
                         {
                             summary     => "logout from an AIM account",
                             usage       => "aimlogout [<screenname> ...]"
                         });
    BarnOwl::new_command(aimwrite => \&cmd_aimwrite,
                         {
                             summary     => "send an AIM message",
                             usage       => 'aimwrite <user> [-a <screenname>] [-m <message...>]',
                             description => "Send an aim message to a user.\n\n"
                                          . "The following options are available:\n\n"
                                          . "-m    Specifies a message to send without prompting.\n\n"
                                          . "-a    Specifies a screenname to send from.  If not given,\n"
                                          . "      the account of the currently selected message, if\n"
                                          . "      available, is used.\n\n"
                                          . "Do not include any spaces in screennames."
                         });
    BarnOwl::new_command(alist => \&cmd_alist,
                         {
                             summary     => "List AIM users logged in",
                             usage       => "alist [<account> ...]",
                             description => "Print a listing of AIM users logged in"
                         });
    BarnOwl::new_command(aaway => \&cmd_aaway,
                         {
                             summary     => "Set, enable or disable AIM away message",
                             usage       => "aaway [ on | off | toggle ]\n"
                                          . "aaway <message>",
                             description => "Turn on or off the AIM away message for all accounts\n"
                                          . "you are logged in to.   If 'message' is specified,\n"
                                          . "turn on aaway with that message, otherwise use the\n"
                                          . "default.\n\n"
#                                          . "The message, if given, should be a quoted string.\n\n"
                                          . "Passing 'toggle' to aaway will set all accounts to be\n"
                                          . "away if none of them are currently away, and will set\n"
                                          . "all of them to be present if any of them are away."
                         });
    BarnOwl::new_command('aimaddbuddy' => \&cmd_add_buddy,
                         {
                             summary     => "add a buddy to an AIM buddylist",
                             usage       => "aimaddbuddy [-a <account>] [-g <group>] <buddy> ...",
                             description => "Add the named buddy or buddies to your buddylist.\n"
                                          . "If no group is specified, aim:default_buddy_group is\n"
                                          . "used.  If no account is specified, buddies are added\n"
                                          . "to all accounts to which you are logged in."
                         });
    BarnOwl::new_command('aimdelbuddy' => \&cmd_delete_buddy,
                         {
                             summary     => "deletes a buddy from an AIM buddylist",
                             usage       => "aimdelbuddy [-a <account>] [-g <group>] <buddy> ...",
                             description => "Add the named buddy or buddies to your buddylist.\n"
                                          . "If no group is specified, the buddy is deleted from\n"
                                          . "the first group in which it is found.  If no account\n"
                                          . "is specified, buddies are deleted from all accounts\n"
                                          . "to which you are logged in."
                         });
    BarnOwl::new_command('aimchat' => \&cmd_aim_chat,
                         {
                             summary     => "AIM chat group related commands",
                             usage       => "aimchat <command> [-a <account>] [<args>]",
                             description => "The following commands are available:\n\n"
                             # XXX TODO: Decide whether or not we actually want this 'exchange' parameter
                                          . "join [-a <account>] <chatroom> [<exchange>]\n"
                                          . "        Create and join the AIM chatroom with name `chatroom'.\n"
                                          . "        You should not use the `exchange' parameter unless\n"
                                          . "        you know what you are doing.  If you are signed in\n"
                                          . "        to multiple accounts, you must specify the account\n"
                                          . "        with which to join the chatroom.\n\n"
                                          . "invite [-a <account>] [-c <chatroom>] <user> [-m <message>]\n"
                                          . "        Invite `user' to a chatroom that you are in, prompting\n"
                                          . "        `user' with `message'.\n"
                                          . "        If you do not specify a message with -m, you will be\n"
                                          . "        prompted for one.\n"
                                          . "        Which chatroom is guessed from a combination of the\n"
                                          . "        `chatroom' and the `account'.\n\n"
                                          . "part [-a <account>] [-c <chatroom>]\n"
                                          . "        Leave the specified chatroom.  Which chatroom is\n"
                                          . "        guessed from a combination of `chatroom' and\n"
                                          . "        `account'.\n\n"
                                          . "accept [-a <account>] <chat url>\n"
                                          . "        Accept a chatroom invitation.\n\n"
                                          . "decline [-a <account>] <chat url>\n"
                                          . "        Decline a chatroom invitation."
                         });
    BarnOwl::new_command(join => \&cmd_join,
                         {
                             summary     => "join a chatroom",
                             # XXX TODO: Decide whether or not we actually want this 'exchange' parameter
                             usage       => "join aim [-a <account>] <chatroom> [<exchange>]",
                             description => "Create and join the AIM chatroom with name `chatroom'.\n"
                                          . "You should not use the `exchange' parameter unless\n"
                                          . "you know what you are doing.  If you are signed in\n"
                                          . "to more than one account, you must specify and account\n"
                                          . "with which to join the chat group.\n\n"
                                          . "NOTE: This command is deprecated in favor of the aimchat\n"
                                          . "command."
                         });
    BarnOwl::new_command('aimshow' => \&cmd_aim_show,
                         {
                             summary     => "get information about an AIM user",
                             usage       => "aimshow [-a <account>]\n"
                                          . "aimshow [-a <account>] [-g <group>] <buddy>",
                             description => "Show information either about yourself or about a buddy.\n"
                                          . "With no parameters, other than an optional account, aimshow\n"
                                          . "will show you information about the given account, or all of\n"
                                          . "the accounts to which you are logged in, if you don't provide one.\n\n"
                                          . "With a `buddy' parameter, aimshow will display some subset of the\n"
                                          . "following information:\n\n"
                                          # XXX TODO: Strip some of these?
                                          . "  alias           - the name under which the buddy will display on your\n"
                                          . "                    buddylist, login/logut notificaitons, IMs, etc.\n\n"
                                          . "  comment         - a comment you can associate with the buddy\n\n"
                                          . "  group           - the group on the buddy list this buddy is in\n"
                                          . "  online          - whether or not the buddy is online\n\n"
                                          . "  extended status - the buddy's extended status message\n\n"
                                          . "  trial           - whether or not the buddy's account is a trial\n\n"
                                          . "  AOL             - whether or not the buddy is using the AOL\n"
                                          . "                    Instant Messenger service from America OnLine.\n\n"
                                          . "  away            - whether or not the buddy is away\n\n"
                                          . "  admin           - whether or not the buddy is an administrator\n\n"
                                          . "  mobile          - whether or not the buddy is using a mobile device\n\n"
                                          . "  on since        - how long the buddy has been logged in\n\n"
                                          . "  idle since      - how long the buddy has been idle\n\n"
                                          . "  evil level      - the evil (warning) level for the buddy\n\n"
                                          . "The `account' parameter specifies which of your logged in screen\n"
                                          . "names to use.  If none is given, the information is gotten or set\n"
                                          . "for all accounts which know about that buddy.\n\n"
                                          . "The `group' parameter specifies which group on your buddy list to\n"
                                          # XXX TODO: Determine what happens if you specify a faulty group or account.  Maybe error manually.
                                          . "use.  If the buddy exists in only one group on your buddy list\n"
                                          . "(which is usually the case), you do not have to worry about this\n"
                                          . "parameter.  This command will fail if the buddy does not exist in\n"
                                          . "the group you specify.\n\n"
                         });
    BarnOwl::new_command('aimset' => \&cmd_aim_set,
                         {
                             summary     => "set information about a buddy on your buddylist",
                             usage       => "aimset [-a <account>] [-g <group>] <buddy> <key> <value>",
                             description => "Set information about a buddy on your buddy list. You may set\n"
                                          . "any of the following keys:\n\n"
                                          . "  alias   - the name under which the buddy will display on your\n"
                                          . "            buddylist, login/logut notificaitons, IMs, etc.\n\n"
                                          . "  comment - a comment you can associate with the buddy\n\n"
                                          . "  group   - the group on the buddy list this buddy is in\n"
                                          . "            NOTE: if you change this, BarnOwl will attempt\n"
                                          . "            to preserve data associated with the buddy, but\n"
                                          . "            some application specific data may be lost.\n\n"
                                          . "The 'account' parameter specifies which of your logged in screen\n"
                                          . "names to use.  If none is given, the information is gotten or set\n"
                                          . "for all accounts which know about that buddy.\n\n"
                                          . "The 'group' parameter specifies which group on your buddy list to\n"
                                          # XXX TODO: Determine what happens if you specify a faulty group or account.  Maybe error manually.
                                          . "use.  If the buddy exists in only one group on your buddy list\n"
                                          . "(which is usually the case), you do not have to worry about this\n"
                                          . "parameter.  This command will fail if the buddy does not exist in\n"
                                          . "the group you specify."
                         });
    BarnOwl::new_command('aimset_password' => \&cmd_aim_set_password,
                         {
                             summary     => "change your AIM password",
                             usage       => "aimset_password [-a <account>] [<old passowrd> [<new password>]]",
                             description => "Change your password.  If you are logged in to more than one account\n"
                                          . "you must specify an account with -a.  If you do not provide a password\n"
                                          . "you will be promped for it, and asked to confirm your new password."
                         });
    BarnOwl::new_command('aimset_extended_status' => \&cmd_aim_set_extended_status,
                         {
                             summary     => "change your AIM extended status message",
                             usage       => "aimset_extended_status [-a <account>] <status>",
                             description => "Change your extended status.  If you are logged in to more than one\n"
                                          . "account and do not specify an account with -a, your extended status\n"
                                          . "message will be changed on all accounts to which you are logged in."
                         });
    BarnOwl::new_command('aimset_email' => \&cmd_aim_set_email,
                         {
                             summary     => "change the email address associated with your AIM account",
                             usage       => "aimset_email [-a <account>] <email address>",
                             description => "Change your email address.  If you are logged in to more than one account\n"
                                          . "you must specify an account with -a.\n\n"
                                          . "You will be emailed instructions at the email address you specify, which\n"
                                          . "you must follow to complete the change.  You will be emailed instructions\n"
                                          . "about how to cancel the change request at your old email address, which\n"
                                          . "will be valid for three days."
                         });
    BarnOwl::new_command('aimset_screenname_format' => \&cmd_aim_set_screenname_format,
                         {
                             summary     => "change your AIM screenname format",
                             usage       => "aimset_screenname_format <screenname>",
                             description => "Change your screenname format.  Only spacing and capitalization can be\n"
                                          . "changed."
                         });
}

sub register_keybindings {
    BarnOwl::bindkey(qw(recv a command start-command), 'aimwrite ');
    BarnOwl::bindkey(qw(recv B command alist));
}

sub register_filters {
    BarnOwl::filter(qw(aim type ^aim$));
}

sub register_owl_variables {
    BarnOwl::new_variable_bool("aim:show_logins",
        {
            default => 0,
            summary => "Show AIM login/logout messages"
        });
    BarnOwl::new_variable_bool("aim:show_chat_logins",
        {
            default => 0,
            summary => "Show AIM chatroom enter/leave messages"
        });
    BarnOwl::new_variable_full("aaway", # XXX TODO: decide whether to deprecate this in favor of aim:away
        {
            default => 0,
            summary => "Set AIM away status",
            get_tostring => sub { $vars{is_away} ? "on" : "off" },
            set_fromstring => sub {
                die "Valid settings are on/off" unless $_[0] eq "on" || $_[0] eq "off";
                aaway($_[0] eq "on", BarnOwl::get("aaway_msg_default"));
            },
            validsettings => "on,off",
            takes_on_off => 1
        });
    BarnOwl::new_variable_full("aaway_msg", # XXX TODO: decide whether to deprecate this in favor of aim:away_message
        {
            default     => "",
            summary     => "AIM away message for responding when away",
            description => "This variable gets set to the value of aaway_msg_default\n"
                         . "whenever you go aaway.  You may change it afterwards to\n"
                         . "specify a non-default away message.\n\n"
                         . "SEE ALSO: aaway, aaway_msg_default",
            get_tostring => sub { $vars{away_msg} },
            set_fromstring => sub { aaway($_[0] ne "", $_[0]); },
            validsettings => "<string>",
        });
    BarnOwl::new_variable_string("aaway_msg_default", # XXX TODO: decide whether to deprecate this in favor of aim:away_message_default
        {
            default     => "I'm sorry, but I am currently away from the terminal and am not able to receive your message.",
            summary     => "default AIM away message for responding when away",
            description => "This variable controls the initial setting of your away\n"
                         . "message when you go aaway.  If you want to change your\n"
                         . "current away message, set aaway_msg.\n\n"
                         . "SEE ALSO: aaway, aaway_msg"
        });
    BarnOwl::new_variable_string("aim:default_buddy_group",
        {
            default     => "BarnOwl",
            summary     => "default group to which to add AIM buddies",
            description => "When you call 'addbuddy AIM buddy', this controls the\n"
                         . "group to which the buddy gets added."
        });
    BarnOwl::new_variable_int("aim_ignorelogin_timer", # XXX TODO: decide whether to deprecate this in favor of aim:ignore_login_timer
        {
            default     => 15,
            summary     => "number of seconds after AIM login to ignore login messages",
            description => "This specifies the number of seconds to wait after an\n"
                         . "AIM login before allowing the receipt of AIM login notifications.\n"
                         . "By default this is set to 15.  If you would like to view login\n"
                         . "notifications of buddies as soon as you login, set it to 0 instead."
        });
    BarnOwl::new_variable_bool("aim:show_offline_buddies",
        {
            default => 0,
            summary => 'Show offline buddies.'
        });
    BarnOwl::new_variable_bool("aim:spew",
        {
            default => 0,
            summary => 'Display unrecognized AIM messages.'
        });
    BarnOwl::new_variable_bool("aim:auto_unaway_on_aimwrite",
        {
            default => 1,
            summary => 'automatically come back from being away if you :aimwrite'
        });
}

sub on_connection_changed {
    my ($oscar, $connection, $status) = @_;
    my $fileno = fileno($connection->get_filehandle);
    if ($status eq 'deleted') {
        BarnOwl::remove_io_dispatch($fileno);
    } else {
        my $mode = '';
        $mode .= 'r' if $status =~ /read/;
        $mode .= 'w' if $status =~ /write/;
        BarnOwl::add_io_dispatch($fileno,
                                 $mode,
                                 sub {
                                     my $rin = '';
                                     my $win = '';
                                     vec($rin, $fileno, 1) = 1 if ($status =~ /read/);
                                     vec($win, $fileno, 1) = 1 if ($status =~ /write/);
                                     my $ein = $rin | $win;
                                     select($rin, $win, $ein, 0);
                                     my $read = vec($rin, $fileno, 1);
                                     my $write = vec($win, $fileno, 1);
                                     my $error = vec($ein, $fileno, 1);
                                     $connection->process_one($read, $write, $error);
                                 }
            ) if ($mode);
    }
}

sub on_error {
    my ($oscar, $connection, $errno, $desc, $fatal) = @_;
    # XXX TODO: Get this to autowrap
    #BarnOwl::error(sprintf("%sError $errno: $desc", $fatal ? 'Fatal AIM ' : ''));
    BarnOwl::error($desc);
}

sub on_admin_error {
    my ($oscar, $reqtype, $error, $errurl) = @_;
    BarnOwl::error("AIM Error from $reqtype:\n$error\nFor more information, visit $errurl");
}

sub on_snac_unknown {
    my ($oscar, $connection, $snac, $data) = @_;
    return unless BarnOwl::getvar('aim:spew') eq 'on';
    my $account = $oscar->screenname;
    my %props = (
        type              => 'AIM',
        direction         => 'in',
        body              => 'Unrecognized SNAC: ' . Dumper($snac) . "\nData: " . Dumper($data),
        data              => $data,
        connection        => $connection,
        snac              => Dumper($snac),
        recipient         => $account
    );
    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub on_im_in {
    my ($oscar, $sender, $message, $is_away) = @_;
    BarnOwl::Complete::AIM::add_user($sender);
    my $buddy_info = $oscar->buddy($sender);
    my $account = $oscar->screenname;
    my %props = (
        type              => 'AIM',
        direction         => 'in',
        sender            => $sender,
        origbody          => $message,
        away              => $is_away,
        body              => zformat($message, $is_away),
        recipient         => $account
    );
    $props{sender_alias} = $buddy_info->{alias} if $buddy_info->{alias};
    BarnOwl::queue_message(BarnOwl::Message->new(%props));

    return if $is_away; # prevent infinite auto-away loops

    aaway($vars{is_away}); # Kludge to get around the fact that we don't have hooks for setting variables
    if ($vars{is_away}) {
        send_away_message($oscar, $sender, $vars{away_msg});
    }
}

sub on_chat_im_in {
    my ($oscar, $sender, $chat, $message) = @_;
    BarnOwl::Complete::AIM::add_user($sender);
    my $account = $oscar->screenname;
    my $buddy_info = $oscar->buddy($sender);
    my %props = (
        type              => 'AIM',
        direction         => 'in',
        sender            => $sender,
        body              => $message,
        recipient         => $chat->name,
        chatroom          => $chat->name,
        chaturl           => $chat->url,
        chatexchange      => $chat->exchange,
        account           => $account,
        private           => 0
    );
    $props{sender_alias} = $buddy_info->{alias} if $buddy_info->{alias};
    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub send_away_message($$$) {
    my ($oscar, $to, $message) = @_;
    my $account = $oscar->screenname;
    my $buddy_info = $oscar->buddy($to);
    $oscar->send_im($to, $message, 1);
    my %props = (
        type              => 'AIM',
        direction         => 'out',
        sender            => $account,
        origbody          => $message,
        away              => 1,
        body              => zformat($message, 1),
        recipient         => $to
    );
    $props{recipient_alias} = $buddy_info->{alias} if $buddy_info->{alias};
    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub on_signon_done {
    my $oscar = shift;
    # register initial completion
    # login notifications don't occur if we're logged in somewhere else
    foreach my $group ($oscar->groups) {
        foreach my $buddy ($oscar->buddies($group)) {
            if ($oscar->buddy($buddy, $group)->{online}) {
                register_buddy_inout_completion('in', $oscar, $buddy);
            }
        }
    }
}

sub register_buddy_inout_completion {
    my ($inout, $oscar, $from, $group, $buddy_info) = @_;
    if ($inout eq 'in') {
        BarnOwl::Complete::AIM::on_user_login($from);
    } else { # $inout eq 'out'
        BarnOwl::Complete::AIM::on_user_logout($from);
    }
}

sub on_buddy_inout {
    my ($inout, $oscar, $from, $group, $buddy_data) = @_;
    register_buddy_inout_completion(@_);
    my $to = $oscar->screenname;
    my $buddy_info = $oscar->buddy($from); # the given buddy data is incomplete if the user has just logged out
    my $onoffline;
    if ($inout eq 'in') {
        $onoffline = 'online';
    } else { # $inout eq 'out'
        $onoffline = 'offline';
    }

    return unless BarnOwl::getvar('aim:show_logins') eq 'on';

    # Net::Oscar displays logout notifications for all of your buddies
    # that are offline when you first log in.  Hide this initial flood
    # of logout notifications.
    return if $onoffline eq 'offline' && !defined get_buddy_onoffline_status($oscar, $from);
    # prevent duplicate notifications
    return if get_buddy_onoffline_status($oscar, $from) && get_buddy_onoffline_status($oscar, $from) eq $onoffline; # XXX is there a better way to supress the 'Use of uninitialized value in string eq' warning?
    set_buddy_onoffline_status($oscar, $from, $onoffline);

    my %props = (
        recipient         => $to,
        sender            => $from,
        type              => 'AIM',
        direction         => 'in',
        loginout          => "log$inout",
        body              => "$from is now $onoffline.",
        data              => Dumper($buddy_data)
    );
    $props{sender_alias} = $buddy_info->{alias} if $buddy_info->{alias};

    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub on_chat_buddy_inout {
    my ($inout, $oscar, $from, $chat, $buddy_info) = @_;
    my $to = $oscar->screenname;
    $buddy_info = $oscar->buddy($from); # the given buddy data is incomplete if the user has just logged out
    my $action;
    my $roomname = $chat->name;
    if ($inout eq 'in') {
        $action = 'entered';
    } else { # $inout eq 'out'
        $action = 'left';
    }

    return unless BarnOwl::getvar('aim:show_chat_logins') eq 'on';

    my %props = (
        recipient         => $to,
        sender            => $from,
        type              => 'AIM',
        direction         => 'in',
        loginout          => "log$inout",
        body              => "$from had $action chatroom $roomname.",
        chatroom          => $chat->name,
        chaturl           => $chat->url,
        chatexchange      => $chat->exchange
    );
    $props{sender_alias} = $buddy_info->{alias} if $buddy_info->{alias};

    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub cmd_aimlogin {
    my ($cmd, $user, $pass) = @_;
    if (!defined $user) {
        BarnOwl::error("usage: $cmd screenname [password]");
    } elsif (get_oscar($user)) {
        BarnOwl::error("You are already logged in to AIM as $user.");
    } elsif (!defined $pass) {
        BarnOwl::start_password("AIM Password for $user: ",
                                sub {
                                    BarnOwl::Module::AIM::cmd_aimlogin($cmd, $user, @_);
                                });
    } else {
        my $oscar = Net::OSCAR->new(capabilities => [qw(extended_status)]);
        $oscar->set_callback_im_in(
            sub { BarnOwl::Module::AIM::on_im_in(@_) });
        $oscar->set_callback_connection_changed(
            sub { BarnOwl::Module::AIM::on_connection_changed(@_) });
        $oscar->set_callback_error(
            sub { BarnOwl::Module::AIM::on_error(@_) });
        $oscar->set_callback_snac_unknown(
            sub { BarnOwl::Module::AIM::on_snac_unknown(@_) });

        $oscar->set_callback_signon_done(
            sub { BarnOwl::Module::AIM::on_signon_done(@_) });

        $oscar->set_callback_chat_joined(
            sub { BarnOwl::Module::AIM::on_chat_joined(@_) });
        $oscar->set_callback_chat_buddy_in(
            sub { BarnOwl::Module::AIM::on_chat_buddy_inout('in', @_) });
        $oscar->set_callback_chat_buddy_out(
            sub { BarnOwl::Module::AIM::on_chat_buddy_inout('out', @_) });
        $oscar->set_callback_chat_im_in(
            sub { BarnOwl::Module::AIM::on_chat_im_in(@_) });
        $oscar->set_callback_chat_invite(
            sub { BarnOwl::Module::AIM::on_chat_invite(@_) });
        $oscar->set_callback_chat_closed(
            sub { BarnOwl::Module::AIM::on_chat_closed(@_) });

        my $enable_login_notifications = sub {
            my $timer = shift;
            $timer->stop if defined $timer;
            $oscar->set_callback_buddy_in(
                sub { BarnOwl::Module::AIM::on_buddy_inout('in', @_) });
            $oscar->set_callback_buddy_out(
                sub { BarnOwl::Module::AIM::on_buddy_inout('out', @_) });
        };
        my $signon_done = sub {
            BarnOwl::admin_message('AIM',
                                   'Logged in to AIM as ' . shift->screenname);
            BarnOwl::message($oscar->screenname . ' logged in');
        };
        if (BarnOwl::getvar('aim_ignorelogin_timer') > 0) {
            $oscar->set_callback_buddy_in(
                sub { BarnOwl::Module::AIM::register_buddy_inout_completion('in', @_) });
            $oscar->set_callback_buddy_out(
                sub { BarnOwl::Module::AIM::register_buddy_inout_completion('out', @_) });
            $oscar->set_callback_signon_done(
                sub {
                    $signon_done->();
                    BarnOwl::Timer->new({
                        name  => 'AIM Ignore Login Timer',
                        cb    => $enable_login_notifications,
                        after => BarnOwl::getvar('aim_ignorelogin_timer')
                    })
            });
        } else {
            $oscar->set_callback_signon_done($signon_done);
            $enable_login_notifications->();
        }

        $oscar->signon(
            screenname => $user,
            password => $pass
            );
        push_oscar($oscar);
    }
}

sub cmd_aimlogout {
    my ($cmd, @users) = @_;
    my @oscars = get_oscars(@users);

    if (!@oscars) {
        die "AIM user(s) not logged in.\n";
    }

    my $screennames = 'Screenname';
    $screennames .= 's' if scalar @oscars != 1;
    $screennames .= ' ' . join(", ", map { $_->screenname } @oscars);

    # XXX TODO: Make completion deal with buddies who disappeared via my logout
    logout_oscars(@oscars);

    BarnOwl::admin_message('AIM', "$screennames logged out.");
}

sub cmd_aaway {
    my $cmd = shift;
    my $message = BarnOwl::quote(@_); # TODO: Enforce properly quoted strings?
    #die "<message> must be single properly quoted string\n" if scalar @_ != 1;
    undef $message if $message eq '';

    my $onoff = $message // 'on';
    if ($onoff eq 'toggle') {
        $onoff = $vars{is_away} ? 'off' : 'on';
    }

    if ($onoff eq 'off') {
        undef $message;
    } elsif ($onoff eq 'on') {
        if (!defined $message) { # safer to do this here, and not at the beginning, because what if aaway_msg_default is 'on' or 'off' or 'toggle'
            $message = BarnOwl::getvar('aaway_msg_default');
        }
    } else {
        $onoff = 'on';
        # $message is already set to something non-empty
    }

    aaway($onoff eq 'on', $message);
    if ($onoff eq 'on') {
        $message =~ s/\n/\\n/g;
        BarnOwl::message("AIM away set ($message)");
    } else {
        BarnOwl::message("AIM away off");
    }
}

# sets or unsets awayness.  Note that we default to aaway_msg and not
# aaway_msg_default.
sub aaway {
    $vars{is_away} = shift;
    if ($vars{is_away}) {
        $vars{away_msg} = shift // $vars{away_msg};
    } else {
        $vars{away_msg} = ''; # passing '' to set_away will make you be marked as no longer being away
    }
    foreach my $oscar (get_oscars()) {
        $oscar->set_away($vars{away_msg});
    }
}

sub on_away_on {
    my $message = shift // BarnOwl::getvar('aaway_msg_default');
    aaway(1, $message);
}

sub on_away_off {
    aaway(0);
}

sub on_get_is_away {
    return $vars{is_away};
}

sub cmd_aimwrite {
    my ($account, $body);
    my $full_cmd = BarnOwl::quote(@_); # TODO: reconstruct command like jabber?
    my $cmd = shift;
    Getopt::Long::Configure('pass_through', 'no_getopt_compat');
    Getopt::Long::GetOptionsFromArray(\@_,
        'account=s' => \$account,
        'message=s' => \$body
    ) or die "Usage: aimwrite <user> [-a <screenname>] [-m <message...>]\n";
    my $recipient = shift;
    if (scalar @_ || !defined $recipient) {
        die "Usage: aimwrite <user> [-a <screenname>] [-m <message...>]\n";
    }
    my $oscar = get_current_oscar($account, $recipient);

    if (BarnOwl::getvar('aim:auto_unaway_on_aimwrite') eq 'on') {
        aaway(0);
    }

    return process_aimwrite($oscar, $body, $recipient) if defined $body;
    BarnOwl::message('Type your message below.  End with a dot on a line by itself.  ^C will quit.');
    BarnOwl::start_edit_win($full_cmd,
                            sub { $body = shift;
                                  BarnOwl::message(''); # kludge to clear the 'Type your message...'
                                  process_aimwrite($oscar, $body, $recipient);
                            });
}

sub process_aimwrite($$$) {
    my ($oscar, $body, $recipient) = @_;
    my $sender = $oscar->screenname;
    my $buddy_info = $oscar->buddy($recipient);
    $oscar->send_im($recipient, $body);
    my %props = (
        type               => 'AIM',
        direction          => 'out',
        sender             => $sender,
        origbody           => $body,
        away               => 0,
        body               => zformat($body, 0),
        recipient          => $recipient
    );
    $props{recipient_alias} = $buddy_info->{alias} if $buddy_info->{alias};
    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub on_get_quick_start {
    return <<'EOF'
@b(AIM:)
Type ':aimlogin @b(screenname)' to log in to AIM. You can send an IM
to somebody by typing ':aimwrite @b(somebody)' or just 'a @b(somebody)'.
If you are logged in to multiple accounts, you can specify which
screenname to send your IM from by typing ':aimwrite -a @b(me) @b(somebody)'.
EOF
}

sub cmd_alist {
    my $cmd = shift;
    my @accounts = @_;
    my @oscars = get_oscars(@accounts);
    if (!@oscars) {
        die "You are not logged in to AIM.\n" if !@accounts;
        die "You are not logged in to any of the AIM accounts you specified.\n";
    }
    BarnOwl::popless_ztext(on_get_buddy_list(@oscars));
}

sub blist_list_buddy($$$) {
    my ($oscar, $screenname, $show_offline) = @_;
    my $blistStr .= "    ";
    my $buddy_info = $oscar->buddy($screenname);

    return unless $show_offline || $buddy_info->{online};

    my $alias = $buddy_info->{alias};
    my $idle_since = $buddy_info->{idle_since};

    # XXX TODO: Format this better
    $blistStr .= sprintf '%-20s %-20s', $alias, $screenname;

    if ($buddy_info->{away}) {
        $blistStr .= " [away]";
        $blistStr = BarnOwl::Style::boldify($blistStr) if $show_offline;
    } elsif ($buddy_info->{online}) {
        $blistStr .= " [online]";
        $blistStr .= " Idle for: " . format_duration(time - $idle_since) if defined $idle_since;
        $blistStr = BarnOwl::Style::boldify($blistStr) if $show_offline;
    } else {
        $blistStr .= " [offline]";
    }
    return "$blistStr\n";
}

# Sort, ignoring markup.
sub blist_sort {
    return uc(BarnOwl::ztext_stylestrip($a)) cmp uc(BarnOwl::ztext_stylestrip($b));
}

sub get_single_buddy_list($$) {
    my ($oscar, $show_offline) = @_;
    return "" unless $oscar->is_on;
    my $blist = "";
    $blist .= BarnOwl::Style::boldify("AIM buddylist for " . $oscar->screenname . "\n");
    my @g_texts = ();
    foreach my $group ($oscar->groups()) {
        my @buddies = $oscar->buddies($group);
        my @b_texts = ();
        foreach my $buddy (@buddies) {
            my $text = blist_list_buddy($oscar, $buddy, $show_offline);
            push @b_texts, $text if defined $text;
        }
        push @g_texts, "  Group: $group\n" . join('', sort blist_sort @b_texts) if @b_texts;
    }
    @g_texts = sort blist_sort @g_texts;
    $blist .= join('', @g_texts);
    return $blist;
}

sub on_get_buddy_list {
    my @oscars = @_ ? @_ : get_oscars();
    my $show_offline = BarnOwl::getvar('aim:show_offline_buddies') eq 'on';
    my $blist = '';
    foreach my $oscar (@oscars) {
        $blist .= get_single_buddy_list($oscar, $show_offline);
    }
    return $blist;
}

sub add_delete_buddy($$$@) {
    my ($add_delete, $oscar, $group, @buddies) = @_;
    if ($add_delete eq 'add') {
        $oscar->add_buddy($group, @buddies);
    } elsif ($add_delete eq 'delete') {
        if (!defined $group) {
            foreach my $buddy (@buddies) {
                $group = $oscar->findbuddy($buddy);
                $oscar->remove_buddy($group, $buddy) if defined $group;
            }
        } else {
            $oscar->remove_buddy($group, @buddies);
        }
    } else {
        die "You cannot '$add_delete' buddies, you can only 'add' them or 'delete' them.";
    }
    # XXX TODO:
    # > After calling this method, your program MUST not call it again
    # > until either the buddylist_ok or buddylist_error callbacks are
    # > received.
    # We should make sure that the last call to commit_buddylist
    # returned before calling it here.  Until then, hope that
    # the user doesn't execute commands too quickly.
    $oscar->commit_buddylist();
}

sub cmd_add_delete_buddy {
    my $add_delete = shift;
    my $cmd = shift;
    my (@accounts, @groups);
    Getopt::Long::Configure('pass_through', 'no_getopt_compat');
    Getopt::Long::GetOptionsFromArray(\@_,
        'account=s' => \@accounts,
        'group=s' => \@groups
    ) or die "Usage: $cmd [-a account] [-g group] buddy\n";
    my @buddies = @_;
    if (!@buddies) {
        die "Usage: $cmd [-a account] [-g group] buddy\n";
    }
    my @oscars = get_oscars(@accounts);
    if (!@groups) {
        if ($add_delete eq 'add') {
            @groups = (BarnOwl::getvar('aim:default_buddy_group'));
        } else {
            @groups = (undef);
        }
    }
    foreach my $oscar (@oscars) {
        foreach my $group (@groups) {
            add_delete_buddy($add_delete, $oscar, $group, @buddies);
        }
    }
    if ($add_delete eq 'add') {
        BarnOwl::message(join(' ', @buddies) . ' added as AIM budd' . (scalar @buddies > 1 ? 'ies' : 'y'));
    } else {
        BarnOwl::message(join(' ', @buddies) . ' deleted as AIM budd' . (scalar @buddies > 1 ? 'ies' : 'y'));
    }
}

sub on_add_delete_buddy($@) {
    my ($add_delete, $protocol, @buddies) = @_;
    return unless $protocol =~ /^AIM(:.+)?$/i;
    my $screenname = $protocol;
    $screenname =~ s/^AIM:?//i;
    my @oscars = ($screenname eq '') ? get_oscars() : (get_oscar($screenname));
    foreach my $oscar (@oscars) {
        add_delete_buddy($add_delete, $oscar, BarnOwl::getvar('aim:default_buddy_group'), @buddies);
    }
    return 1;
}

sub cmd_add_buddy { cmd_add_delete_buddy('add', @_) }
sub cmd_delete_buddy { cmd_add_delete_buddy('delete', @_) }
sub on_add_buddy { on_add_delete_buddy('add', @_) }
sub on_delete_buddy { on_add_delete_buddy('delete', @_) }

sub on_chat_joined {
    my ($oscar, $chatname, $chat) = @_;
    my $screenname = $oscar->screenname;
    add_chat($oscar, $chat);
    queue_admin_msg("You ($screenname) have entered AIM chat room `$chatname'.");
}

sub on_chat_closed {
    my ($oscar, $chat, $error) = @_;
    my $screenname = $oscar->screenname;
    my $chatname = $chat->name;
    delete_chat($oscar, $chat);
    queue_admin_msg("You ($screenname) have been disconnected from AIM chat room `$chatname' due to error $error.");
}

sub on_chat_invite {
    my ($oscar, $who, $message, $chat, $chaturl) = @_;
    BarnOwl::Complete::AIM::add_user($who);
    my $account = $oscar->screenname;
    my $chatname = $chat->name;
    my $body;
    my $buddy_info = $oscar->buddy($who);
    if ($buddy_info->{alias}) {
        $body = $buddy_info->{alias} . " ($who)";
    } else {
        $body = $who;
    }
    $body .= " has invited $account to join chatroom `$chatname'\n"
           . $message . "\n"
           . "Join? (Answer with the `yes' or `no' commands.)";
    my %props = (
        type         => 'admin',
        adminheader  => 'AIM chatroom: invite',
        direction    => 'in',
        question     => 'true',
        sender       => $who,
        body         => $body,
        recipient    => $account,
        yescommand   => BarnOwl::quote(qw(aimchat accept -a), $account, $chaturl),
        nocommand    => BarnOwl::quote(qw(aimchat decline -a), $account, $chaturl)
    );
    $props{sender_alias} = $buddy_info->{alias} if $buddy_info->{alias};
    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub cmd_aim_chat {
    my $full_cmd = BarnOwl::quote(@_);
    my $cmd = shift;
    my $subcmd = shift;
    Getopt::Long::Configure('pass_through', 'no_getopt_compat');
    if ($subcmd eq 'join') {
        my $account;
        Getopt::Long::GetOptionsFromArray(\@_,
            'account=s' => \$account,
        ) or die "Usage: $cmd $subcmd [-a <account>] <chatroom> [<exchange>]\n";
        my $chatroom = shift;
        my $exchange = shift;
        die "Usage: $cmd $subcmd [-a <account>] <chatroom> [<exchange>]\n" unless defined $chatroom && !@_;

        my $oscar;
        if (defined $account) {
            $oscar = get_oscar($account);
        } else {
            $oscar = get_current_oscar();
        }
        $account = $oscar->screenname;

        if (defined $exchange) {
            $oscar->chat_join($chatroom, $exchange);
        } else {
            $oscar->chat_join($chatroom);
        }
        BarnOwl::message("You ($account) have opened chatroom `$chatroom'.");
    } elsif ($subcmd eq 'invite') {
        my ($account, $chatroom, $message);
        Getopt::Long::GetOptionsFromArray(\@_,
            'account=s'  => \$account,
            'chatroom=s' => \$chatroom,
            'message=s'  => \$message
        ) or die "Usage: $cmd $subcmd [-a <account>] [-c <chatroom>] <user> [-m <message>]\n";
        my $recipient = shift;
        die "Usage: $cmd $subcmd [-a <account>] [-c <chatroom>] <user> [-m <message>]\n" unless defined $recipient && !@_;

        my $chat = get_chat($account, $chatroom);
        my $oscar;
        if (defined $account) {
            $oscar = get_oscar($account);
        } else {
            $oscar = get_current_oscar();
        }

        return process_aim_chat_invite($oscar, $recipient, $chat, $message) if defined $message;
        BarnOwl::message('Type your chat invitation below.  End with a dot on a line by itself.  ^C will quit.');
        BarnOwl::start_edit_win($full_cmd,
                            sub { $message = shift;
                                  BarnOwl::message(''); # kludge to clear the 'Type your message...'
                                  process_aim_chat_invite($oscar, $recipient, $chat, $message);
                            });
    } elsif ($subcmd eq 'part') {
        my ($account, $chatroom, $message);
        Getopt::Long::GetOptionsFromArray(\@_,
            'account=s'  => \$account,
            'chatroom=s' => \$chatroom,
        ) or die "Usage: $cmd $subcmd [-a <account>] [-c <chatroom>]\n";
        my $recipient = shift;
        die "Usage: $cmd $subcmd [-a <account>] [-c <chatroom>]\n" if @_;

        my ($oscar, $chat) = get_oscar_chat_pair($account, $chatroom);
        $chat->part();
        my $screenname = $oscar->screenname;
        delete_chat($oscar, $chat);
        queue_admin_msg("You ($screenname) have left AIM chat room `$chatroom'.");
    } elsif ($subcmd eq 'accept' || $subcmd eq 'decline') {
        my $account;
        Getopt::Long::GetOptionsFromArray(\@_,
            'account=s'  => \$account,
        ) or die "Usage: $cmd $subcmd [-a <account>] <chat url>\n";
        my $chaturl = shift;
        die "Usage: $cmd $subcmd [-a <account>] <chat url>\n" if @_;

        my $oscar;
        if (defined $account) {
            $oscar = get_oscar($account);
        } else {
            $oscar = get_current_oscar();
        }

        if ($subcmd eq 'accept') {
            $oscar->chat_accept($chaturl);
        } else {
            $oscar->chat_decline($chaturl);
        }
    } else {
        die "You cannot $cmd `$subcmd', you can only `join', `invite', `part', `accept', and `decline'.\n";
    }
}

sub process_aim_chat_invite($$$$) {
    my ($oscar, $recipient, $chat, $message) = @_;
    $chat->invite($recipient, $message);
    # XXX TODO?: Change the type of this message?
    my %props = (
        type           => 'AIM',
        direction      => 'out',
        sender         => $oscar->screenname,
        body           => $message,
        recipient      => $recipient,
        chaturl        => $chat->url,
        chatroom       => $chat->name,
        chatexchange   => $chat->exchange
    );
    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub cmd_join {
    my $cmd = shift;
    my $aim = shift;
    die "Usage: $cmd aim [-a account] <chatroom> [exchange]\n" unless lc($aim) eq 'aim'; # XXX TODO: Figure out why this is the syntax.
    BarnOwl::error("You are using the deprecated command 'join'.  Use 'aimchat join' instead.");
    cmd_aim_chat('aimchat', 'join', @_);
}

sub cmd_aim_show {
    my $cmd = shift;
    my ($account, $group);
    Getopt::Long::Configure('pass_through', 'no_getopt_compat');
    Getopt::Long::GetOptionsFromArray(\@_,
        'account=s' => \$account,
        'group=s' => \$group
    ) or die "Usage: $cmd [-a <account>] [[-g <group>] <buddy>]\n";
    my $buddy = shift;
    die "Usage: $cmd [-a <account>] [[-g <group>] <buddy>]\n" unless defined $buddy || !defined $group;
    if (defined $buddy) {
        my @oscars;
        if (defined $account) {
            @oscars = (get_oscar($account));
        } else {
            @oscars = get_oscars();
        }
        my @buddies;
        if (defined $group) {
            @oscars = grep { $_->buddy($buddy, $group) } @oscars;
            @buddies = map { $_->buddy($buddy, $group) } @oscars;
        } else {
            @oscars = grep { $_->buddy($buddy) } @oscars;
            @buddies = map { $_->buddy($buddy) } @oscars;
        }
        my $display = '';
        if (scalar @buddies == 0) {
            $display .= "Buddy `$buddy' not found";
            $display .= " for account `$account'" if defined $account;
            $display .= ".";
        } else {
            my $buddy_info = $buddies[0];
            my $oscar = $oscars[0];
            $display = "Information for " . $buddy_info->{screenname};
            $group = $group // $oscar->findbuddy($buddy);
            $display .= " in group $group" if defined $group;
            $display = BarnOwl::Style::boldify($display) . "\n";
            $display .= "    Alias:           " . $buddy_info->{alias} . "\n";
            $display .= "    Online:          " . ($buddy_info->{online} ? 'yes' : 'no') . "\n";
            # XXX TODO: Find a good way to format time durations
            $display .= "    Online For:      " . format_duration(time - $buddy_info->{onsince}) . "\n"        if defined $buddy_info->{onsince};
            $display .= "    Idle:            " . ((time - $buddy_info->{idle_since} > 0) ? 'yes' : 'no') . "\n" if defined $buddy_info->{idle_since};
            $display .= "    Idle For:        " . format_duration(time - $buddy_info->{idle_since}) . "\n"                      if defined $buddy_info->{idle_since};
            $display .= "    Away:            " . ($buddy_info->{away}   ? 'yes' : 'no') . "\n" if $buddy_info->{away}   || $buddy_info->{online};
            $display .= "    Comment:         " . $buddy_info->{comment} . "\n";
            $display .= "    Extended Status: " . $buddy_info->{extended_status} . "\n"         if defined $buddy_info->{extended_status};
            $display .= "    Trial:           " . ($buddy_info->{trial}  ? 'yes' : 'no') . "\n" if $buddy_info->{trial}  || $buddy_info->{online};
            $display .= "    AOL:             " . ($buddy_info->{aol}    ? 'yes' : 'no') . "\n" if $buddy_info->{aol}    || $buddy_info->{online};
            $display .= "    Admin:           " . ($buddy_info->{admin}  ? 'yes' : 'no') . "\n" if $buddy_info->{admin}  || $buddy_info->{online};
            $display .= "    Mobile:          " . ($buddy_info->{mobile} ? 'yes' : 'no') . "\n" if $buddy_info->{mobile} || $buddy_info->{online};
            $display .= "    Member Since:    " . format_date($buddy_info->{membersince}) . "\n" if defined $buddy_info->{membersince};
            $display .= "    Evil Level:      " . $buddy_info->{evil} . "\n"             if defined $buddy_info->{evil};
        }
        BarnOwl::popless_ztext($display);
    } else {
        my @oscars;
        if (defined $account) {
            @oscars = (get_oscar($account));
        } else {
            @oscars = get_oscars();
        }
        my $display = '';
        foreach my $oscar (@oscars) {
            $display .= BarnOwl::Style::boldify("Information for " . $oscar->screenname) . "\n"
                     . "    Email:   " . $oscar->email . "\n"
                     . "    Profile: " . $oscar->profile . "\n\n";
        }
        BarnOwl::popless_ztext($display);
    }
}

sub cmd_aim_set {
    my $cmd = shift;
    my ($account, $group);
    Getopt::Long::Configure('pass_through', 'no_getopt_compat');
    Getopt::Long::GetOptionsFromArray(\@_,
        'account=s' => \$account,
        'group=s' => \$group
    ) or die "Usage: $cmd [-a <account>] [-g <group>] <buddy> <key> <value>\n";
    my $buddy = shift;
    my $key = shift;
    my $value = shift;
    die "Usage: $cmd [-a <account>] [-g <group>] <buddy> <key> <value>\n" unless defined $buddy && defined $key && defined $value && !@_;
    my @oscars = defined $account ? (get_oscar($account)) : get_oscars();
    foreach my $oscar (@oscars) {
        next unless defined $oscar->findbuddy($buddy);
        my $use_group = $group // $oscar->findbuddy($buddy);
        if ($key eq 'alias') {
            $oscar->set_buddy_alias($use_group, $buddy, $value);
        } elsif ($key eq 'comment') {
            $oscar->set_buddy_comment($use_group, $buddy, $value);
        } elsif ($key eq 'group') {
            if ($value ne $use_group) {
                my $buddy_info = $oscar->buddy($buddy, $use_group);
                my $alias = $buddy_info->{alias};
                my $comment = $buddy_info->{comment};
                $oscar->remove_buddy($use_group, $buddy);
                $oscar->add_buddy($value, $buddy);
                $oscar->set_buddy_alias($value, $buddy, $alias);
                $oscar->set_buddy_comment($value, $buddy, $comment);
            }
        } else {
            die "You cannot set `$key', only `alias', `comment', and `group'.\n";
        }
        # XXX TODO:
        # > After calling this method, your program MUST not call it again
        # > until either the buddylist_ok or buddylist_error callbacks are
        # > received.
        # We should make sure that the last call to commit_buddylist
        # returned before calling it here.  Until then, hope that
        # the user doesn't execute commands too quickly.
        $oscar->commit_buddylist();
    }
    BarnOwl::message("Set `$key' of `$buddy' to `$value'.");
}

sub cmd_aim_set_password {
    my $cmd = shift;
    my $account;
    Getopt::Long::Configure('pass_through', 'no_getopt_compat');
    Getopt::Long::GetOptionsFromArray(\@_,
        'account=s' => \$account,
    ) or die "Usage: $cmd [-a <account>] [<old passowrd> [<new password>]]\n";
    my $oscar = get_single_oscar($account);
    my $old_password = shift;
    my $new_password = shift;
    if (!defined $old_password) {
        BarnOwl::start_password('Old Password: ',
                                sub {
                                    $old_password = shift;
                                    get_confirmed_password(sub { handle_set_password($oscar, $old_password, shift) },
                                                           undef,
                                                           'New');
                                    });
    } elsif (!defined $new_password) {
        get_confirmed_password(sub { handle_set_password($oscar, $old_password, shift) },
                               undef,
                               'New');
    } else {
        handle_set_password($oscar, $old_password, $new_password);
    }
}

sub handle_set_password {
    my ($oscar, $old_password, $new_password) = @_;
    $oscar->change_password($old_password, $new_password);
    BarnOwl::message("You have changed the password for " . $oscar->screenname . ".");
}

sub cmd_aim_set_extended_status {
    my $cmd = shift;
    my $account;
    Getopt::Long::Configure('pass_through', 'no_getopt_compat');
    Getopt::Long::GetOptionsFromArray(\@_,
        'account=s' => \$account,
    ) or die "Usage: $cmd [-a <account>] <status>\n";
    my $message = shift;
    die "Usage: $cmd [-a <account>] <status>\n" if @_;
    my @oscars = defined $account ? (get_oscar($account)) : get_oscars();
    foreach my $oscar (@oscars) {
        $oscar->set_extended_status($message);
    }
    BarnOwl::message("Set AIM extended status message to `$message'.");
}

sub cmd_aim_set_email {
    my $cmd = shift;
    my $account;
    Getopt::Long::Configure('pass_through', 'no_getopt_compat');
    Getopt::Long::GetOptionsFromArray(\@_,
        'account=s' => \$account,
    ) or die "Usage: $cmd [-a <account>] <email address>\n";
    my $email = shift;
    die "Usage: $cmd [-a <account>] <email address>\n" unless defined $email && !@_;
    my $oscar = get_single_oscar($account);
    $oscar->change_email($email);
    BarnOwl::message("Changed email address for " . $oscar->screenname . ".  You must check your email to complete the change.");
}

sub cmd_aim_set_screenname_format {
    my $cmd = shift;
    my $screenname = shift;
    die "Usage: $cmd <screenname>\n" unless defined $screenname && !@_;
    my @oscars = get_oscars($screenname);
    die "You are not logged in with screename `$screenname'.\n" unless scalar @oscars == 1;
    my $oscar = $oscars[0];
    my $old_screenname = $oscar->screenname;
    $oscar->format_screenname($screenname);
    BarnOwl::message("Changed screenname from `$old_screenname' to `$screenname'.");
}

### helpers ###

sub queue_admin_msg($) {
    my $err = shift;
    BarnOwl::admin_message('AIM', $err);
}

sub zformat($$) {
    # TODO subclass HTML::Parser
    my ($message, $is_away) = @_;
    if ($is_away) {
        return BarnOwl::Style::boldify('[away]') . " $message";
    } else {
        return $message;
    }
}

sub get_confirmed_password {
    my $success_handler = shift;
    my $failure_handler = shift;
    my $tag = shift // '';
    $tag .= " " if $tag ne '';
    my $prompt = $tag . 'Password: ';
    my $confirm_prompt = "Confirm " . $tag . 'Password: ';
    BarnOwl::start_password($prompt,
                            sub {
                                my $password = shift;
                                BarnOwl::start_password($confirm_prompt,
                                                        sub {
                                                            my $confirm = shift;
                                                            if ($confirm ne $password) {
                                                                BarnOwl::message('Error: Your ' . $tag . 'passowrd does not match your confirmation.');
                                                                &$failure_handler();
                                                            } else {
                                                                &$success_handler($password);
                                                            }
                                                        });
                                });
}

sub add_chat($$) {
    my ($oscar, $chat) = @_;
    $vars{chats}->{$oscar->screenname}->{$chat->url} = {
        oscar => $oscar,
        chat  => $chat
    };
}

sub _get_all_chats() {
    my @chats;
    foreach my $chatrooms_ref (values %{$vars{chats}}) {
        push @chats, values %$chatrooms_ref;
    }
    return @chats;
}

sub get_oscar_chat_pair { # guess which chatroom we want
    my ($screenname, $chatroom, $chaturl)  = @_;
    my @matching_chat_pairs = _get_chat_pairs_matching(@_);
    my @match;
    push @match, "screenname = `$screenname'" if defined $screenname;
    push @match, "chatroom = `$chatroom'"     if defined $chatroom;
    push @match, "chat url = `$chaturl'"      if defined $chaturl;
    my $match_string = join(', ', @match);

    die "No AIM chatrooms match $match_string\n" unless scalar @matching_chat_pairs;
    die "Insufficient specification of chatroom to guess which chatroom you want ($match_string).\n" unless scalar @matching_chat_pairs == 1;
    return ($matching_chat_pairs[0]->{oscar}, $matching_chat_pairs[0]->{chat});
}

sub get_chat { # guess which chatroom we want
    my ($oscar, $chat) = get_oscar_chat_pair(@_);
    return $chat;
}

sub _get_chat_pairs_matching {
    my ($screenname, $chatroom, $chaturl)  = @_;
    my @chats = _get_all_chats();
    @chats = grep { $_->{oscar}->screenname eq $screenname } @chats if defined $screenname;
    @chats = grep { lc($_->{chat}->name) eq lc($chatroom) } @chats  if defined $chatroom;
    @chats = grep { $_->{chat}->url eq $chatroom } @chats           if defined $chaturl;

    return @chats;
}

sub delete_chat($$) {
    my ($oscar, $chat) = @_;
    return delete $vars{chats}->{$oscar->screenname}->{$chat->url};
}

sub get_buddy_onoffline_status {
    my ($oscar, $buddy) = @_;
    return $vars{buddies}->{$oscar->screenname}->{$buddy};
}

sub set_buddy_onoffline_status($$$) {
    my ($oscar, $buddy, $status) = @_;
    $vars{buddies}->{$oscar->screenname}->{$buddy} = $status;
}

sub get_current_oscar {
    my $screenname = shift;
    my $recipient = shift;
    if (defined $screenname) {
        my $oscar = get_oscar($screenname);
        return $oscar if defined $oscar;
        die "You are not logged in to AIM as $screenname.\n";
    }
    if (scalar get_oscars() == 0) { # there's a bug in tied hashes where scalar context doesn't work
        die "You are not logged in to AIM.\n";
    } elsif (scalar get_oscars() == 1) {
        return (get_oscars())[0];
    } else {
        if (defined $recipient) {
            my @current_oscars = grep { $_->findbuddy($recipient) } get_oscars();
            return $current_oscars[0] if scalar @current_oscars == 1;
        }
        my $m = BarnOwl::getcurmsg();
        if ($m && $m->type eq 'AIM') {
            return get_oscar($m->recipient) if get_oscar($m->recipient);
        }
    }
    die "You must specify an account with -a\n";
}

sub get_oscars {
    my @screennames = map { Net::OSCAR::Screenname->new($_) } @_;
    my @oscars = @screennames ? (map { $vars{oscars}->{$_} } @screennames) : (values %{$vars{oscars}});
    return grep { $_ && $_->is_on } @oscars;
}

sub logout_oscars { return delete_oscars_by_oscar(@_); }

sub delete_oscars_by_screenname {
    return unless @_;
    my @oscars = get_oscars(@_);
    delete_oscars_by_oscar(@oscars);
    return @oscars;
}

sub delete_oscars_by_oscar {
    my @oscars = @_;
    my @rtn;
    foreach my $oscar (@oscars) {
        push @rtn, $oscar->screenname if $oscar;
        delete $vars{buddies}->{$oscar->screenname};
        delete $vars{oscars}->{$oscar->screenname};
        $oscar->signoff() if $oscar->is_on; # this must come last, because $oscar->screenname is not available after this
    }
}

# makes no changes if any user is already logged in
sub push_oscars {
    my @oscars = @_;
    foreach my $oscar (@oscars) {
        my $screenname = $oscar->screenname;
        if (get_oscar($screenname)) {
            die "You are already logged in to AIM as " . $oscar->screenname . ".\n";
        }
    }
    foreach my $oscar (@oscars) {
        my $screenname = $oscar->screenname;
        $vars{oscars}->{$screenname} = $oscar;
        $vars{buddies}->{$screenname} = Net::OSCAR::Utility::bltie();
    }
}

sub get_single_oscar {
    my $account = shift;
    my @oscars = defined $account ? get_oscars($account) : get_oscars();
    die "You must specify an account with -a.\n" unless scalar @oscars == 1;
    return $oscars[0];
}
sub get_oscar($) {
    my @oscars = get_oscars(shift);
    return $oscars[0];
}
sub push_oscar($) { return push_oscars(shift); }

sub format_date($) {
    my $date = shift;
    my $dateformat = BarnOwl::time_format('get_time_format');
    return strftime($dateformat, localtime($date));
}

sub format_duration($) {
    # TODO?: Let the user specify the format?
    return duration(shift);
}

################################################################################
### Completion

BarnOwl::Complete::AIM::register_completer($vars{oscars});

1;

# vim: set sw=4 et cin:
