use strict;
use warnings;

package BarnOwl::Logging;

=head1 BarnOwl::Logging

=head1 DESCRIPTION

C<BarnOwl::Logging> implements the internals of logging.  All customizations
to logging should be done in the appropriate subclass of L<BarnOwl::Message>.

=head2 USAGE

Modules wishing to customize how messages are logged should override the
relevant subroutines in the appropriate subclass of L<BarnOwl::Message>.

Modules wishing to log errors sending outgoing messages should call
L<BarnOwl::Logging::log_outgoing_error> with the message that failed
to be sent.

=head2 EXPORTS

None by default.

=cut

use Exporter;

our @EXPORT_OK = qw();

our %EXPORT_TAGS = (all => [@EXPORT_OK]);

use File::Spec;

=head2 get_filenames MESSAGE

Returns a list of filenames in which to log the passed message.

This method calls C<log_filenames> on C<MESSAGE> to determine the list
of filenames to which C<MESSAGE> gets logged.  All filenames are
relative to C<MESSAGE->log_base_path>.  If C<MESSAGE->log_to_all_file>
returns true, then the filename C<"all"> is appended to the list of
filenames.

In any filename, the characters C<"/">, C<"\0">, and C<"~"> get
replaced by underscores.  If the resulting filename is empty or equal
to C<"."> or C<"..">, it is replaced with C<"weird">.

=cut

sub get_filenames {
    my ($m) = @_;
    my @filenames = $m->log_filenames;
    my @rtn;
    my $log_base_path = BarnOwl::Internal::makepath($m->log_base_path);
    push @filenames, 'all' if $m->log_to_all_file;
    foreach my $filename (@filenames) {
        $filename =~ s/[\/\0~]/_/g;
        if ($filename eq '' || $filename eq '.' || $filename eq '..') {
            $filename = 'weird';
        }
        # XXX Check that $filename isn't weird in some other way,
        # and/or strip more bad characters?
        # The original C code also removed characters less than '!'
        # and greater than or equal to '~', marked file names
        # beginning with a non-alphanumeric or non-ASCII character as
        # 'weird', and rejected filenames longer than 35 characters.
        push @rtn, File::Spec->catfile($log_base_path, $filename);
    }
    return @rtn;
}

=head2 should_log_message MESSAGE

Determines whether or not the passed message should be logged.

To customize the behavior of this method, override
L<BarnOwl::Message::should_log>.

=cut

sub should_log_message {
    my ($m) = @_;
    # If there's a logfilter and this message matches it, log
    return 1 if BarnOwl::message_matches_filter($m, BarnOwl::getvar('logfilter'));
    # otherwise we do things based on the logging variables
    # skip login/logout messages if appropriate
    return 0 if $m->is_loginout && BarnOwl::getvar('loglogins') eq 'off';
    # check direction
    return 0 if $m->is_outgoing && BarnOwl::getvar('loggingdirection') eq 'in';
    return 0 if $m->is_incoming && BarnOwl::getvar('loggingdirection') eq 'out';
    return $m->should_log;
}

=head2 log MESSAGE

Call this method to (potentially) log a message.

To customize the behavior of this method for your messages, override
L<BarnOwl::Message::log>, L<BarnOwl::Message::should_log>,
L<BarnOwl::Message::log_base_path>, and/or
L<BarnOwl::Message::log_filenames>.

=cut

sub log {
    my ($m) = @_;
    return unless BarnOwl::Logging::should_log_message($m);
    my $log_text = $m->log;
    foreach my $filename (BarnOwl::Logging::get_filenames($m)) {
        BarnOwl::Logging::enqueue_text($log_text, $filename);
    }
}

=head2 log_outgoing_error MESSAGE

Call this method to (potentially) log an error in sending an
outgoing message.  Errors get logged to the same file(s) as
successful messages.

To customize the behavior of this method for your messages, override
L<BarnOwl::Message::log_outgoing_error>,
L<BarnOwl::Message::should_log>,
L<BarnOwl::Message::log_base_path>, and/or
L<BarnOwl::Message::log_filenames>.

=cut

sub log_outgoing_error {
    my ($m) = @_;
    return unless BarnOwl::Logging::should_log_message($m);
    my $log_text = $m->log_outgoing_error;
    foreach my $filename (BarnOwl::Logging::get_filenames($m)) {
        BarnOwl::Logging::enqueue_text($log_text, $filename);
    }
}

1;
