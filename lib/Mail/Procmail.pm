my $RCS_Id = '$Id: Procmail.pm,v 1.7 2000-08-11 15:43:07+02 jv Exp $ ';

# Author          : Johan Vromans
# Created On      : Tue Aug  8 13:53:22 2000
# Last Modified By: Johan Vromans
# Last Modified On:
# Update Count    : 172
# Status          : Unknown, Use with caution!

=head1 NAME

Mail::Procmail - Procmail-like facility for creating easy mail filters.

=head1 SYNOPSIS

    use Mail::Procmail;

    # Set up. Log everything up to log level 3.
    my $m_obj = pm_init ( loglevel  => 3 );

    # Pre-fetch some interesting headers.
    my $m_from		    = pm_gethdr("from");
    my $m_to		    = pm_gethdr("to");
    my $m_subject	    = pm_gethdr("subject");

    # Default mailbox.
    my $default = "/var/spool/mail/".getpwuid($>);

    pm_log(1, "Mail from $m_from");

    pm_ignore("Non-ASCII in subject")
      if $m_subject =~ /[\232-\355]{3}/;

    pm_resend("jojan")
      if $m_to =~ /jjk@/i;

    # Make sure I see these.
    pm_deliver($default, continue => 1)
      if $m_subject =~ /getopt(ions|(-|::)?long)/i;

    # And so on ...

    # Final delivery.
    pm_deliver($default);

=head1 DESCRIPTION

F<procmail> is a great mail filter program, but it has weird recipe
format. It's pattern matching capabilities are basic and often
insufficient. I wanted something flexible whereby I could filter my
mail using the power of Perl.

I've been considering to write a procmail replacement in Perl for a
while, but it was Simon Cozen's C<Mail::Audit> module, and his article
in The Perl Journal #18, that set it off.

I first started using Simon's great module, and then decided to write
my own since I liked certain things to be done differently. And I
couldn't wait for his updates. Currently, Simon and I are in the
process of considering to port my enhancements to his code as well.

C<Mail::Procmail> allows a piece of email to be logged, examined,
delivered into a mailbox, filtered, resent elsewhere, rejected, and so
on. It is designed to allow you to easily create filter programs to
stick in a F<.forward> or F<.procmailrc> file, or similar.

=head1 DIFFERENCES WITH MAIL::AUDIT

Note that several changes are due to personal preferences and do not
necessarily imply defiencies in C<Mail::Audit>.

=over

=item General

Not object oriented. Procmail functionality typically involves one
single message. All (relevant) functions are exported.

=item Delivery

Each of the delivery methods is able to continue (except
I<reject> and I<ignore>).

Each of the delivery methods is able to pretend they did it
(for testing a new filter).

No default file argument for mailbox delivery, since this is system
dependent.

Each of the delivery methods logs the line number in the calling
program so one can deduce which 'rule' caused the delivery.

System commands can be executed for their side-effects.

I<ignore> logs a reason as well.

I<reject> will fake a "No such user" status to the mail transfer agent.

=item Logging

The logger function is exported as well. Logging is possible to
a named file, STDOUT or STDERR.

Since several deliveries can take place in parallel, logging is
protected against concurrent access, and a timestamp/pid is included
in log messages.

=item Robustness

Exit with TEMPFAIL instead of die in case of problems.

I<pipe> ignores  SIGPIPE.

I<pipe> returns the command exit status if continuation is selected.

Commands and pipes can be protected  against concurrent access using
lockfiles.

=back

=head1 EXPORTED ROUTINES

Note that most delivery routines exit the program unless the attribute
"continue=>1" is passed.

Also, the delivery routines log the line number in the calling program
so it is easy to find out which 'rule' caused a specific delivery to
take place.

=cut

################ Common stuff ################

package Mail::Procmail;

$VERSION = 0.03;

use strict;
use 5.005;
use vars qw(@ISA @EXPORT $pm_hostname);

my $verbose = 0;		# verbose processing
my $debug = 0;			# debugging
my $trace = 0;			# trace (show process)
my $test = 0;			# test mode.

my $logfile;			# log file
my $loglevel;			# log level

use Fcntl qw(:DEFAULT :flock);

use constant REJECTED	=> 67;	# fake "no such user"
use constant TEMPFAIL	=> 75;
use constant DELIVERED	=> 0;

use Sys::Hostname;
$pm_hostname = hostname;

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw(
	     pm_init
	     pm_gethdr
	     pm_deliver
	     pm_reject
	     pm_resend
	     pm_pipe_to
	     pm_command
	     pm_ignore
	     pm_lockfile
	     pm_unlockfile
	     pm_log
	     $pm_hostname
	    );

################ The Process ################

use Mail::Internet;
use LockFile::Simple;

use Carp;

my $m_obj;			# the Mail::Internet object
my $m_head;			# its Mail::Header object

=head2 pm_init

This routine performs the basic initialisation. It must be called once.

Example:

    pm_init (logfile => "my.log", loglevel => 3, test => 1);

Attributes:

=over

=item *

logfile

The name of a file to log messages to. Each message will have a timestamp
attached.

The attribute may be 'STDOUT' or 'STDERR' to achieve logging to
standard output or error respectively.

=item *

loglevel

The amount of information that will be logged.

=item *

test

If true, no actual delivery will be done. Suitable to test a new setup.
Note that file locks are done, so lockfiles may be created and deleted.

=item *

debug

Provide some debugging info.

=item *

trace

Provide some tracing info, eventually.

=item *

verbose

Produce verbose information, eventually.

=back

=cut

sub pm_init {

    my %atts = (
		logfile   => '',
		loglevel  => 0,
		verbose   => 0,
		trace     => 0,
		debug     => 0,
		test      => 0,
		@_);
    $debug     = delete $atts{debug};
    $trace     = delete $atts{trace};
    $test      = delete $atts{test};
    $verbose   = delete $atts{verbose};
    $logfile   = delete $atts{logfile};
    $loglevel  = delete $atts{loglevel};
    $trace |= ($debug || $test);

    croak("Unprocessed attributes: ".join(" ",sort keys %atts))
      if %atts;

    $m_obj = Mail::Internet->new(\*STDIN);
    $m_head = $m_obj->head;  # Mail::Header

    $m_obj;
}

=head2 pm_gethdr

This routine fetches the contents of a header. The result will have
excess whitepace tidied up.

The header is reported using warn() if the debug attribute was passed
(with a true value) to pm_init();

Example:

    $m_to = pm_gethdr("to");

=cut

sub pm_gethdr {
    my $hdr = shift;
    my $val = $m_head->get($hdr);
    if ( $val ) {
	for ( $val ) {
	    s/^\s+//;
	    s/\s+$//;
	    s/\s+/ /g;
	    s/[\r\n]+$//;
	}
	if ( $debug ) {
	    $hdr =~ s/-(.)/"-".ucfirst($1)/ge;
	    warn (ucfirst($hdr), ": ", $val, "\n");
	}
    }
    $val || '';
}

=head2 pm_deliver

This routine performs delivery to a Unix style mbox file, or maildir.

In case of an mbox file, the file is locked first by acquiring
exclusive access.

Example:

    pm_deliver("/var/spool/mail/".getpwuid($>));

Attributes:

=over

=item *

continue

If true, processing will continue after delivery. Otherwise the
program will exit with a DELIVERED status.

=back

=cut

sub pm_deliver {
    my ($target, %atts) = @_;
    my $line = (caller(0))[2];
    pm_log(2, "deliver[$line]: $target");

    # Is it a Maildir?
    if ( -d "$target/tmp" && -d "$target/new" ) {
	my $msg_file = "/${\time}.$$.$pm_hostname";
	my $tmp_path = "$target/tmp/$msg_file";
	my $new_path = "$target/new/$msg_file";
	pm_log(3,"Looks like maildir, writing to $new_path");

	# since mutt won't add a lines tag to maildir messages,
	# we'll add it here
	unless ( gethdr("lines") ) {
	    my $body = $m_obj->body;
	    my $num_lines = @$body;
	    $m_head->add("Lines", $num_lines);
	    pm_log(4,"Adding Lines: $num_lines header");
	}
	my $tmp = _new_fh();
	unless (open ($tmp, ">$tmp_path") ) {
	    pm_log(0,"Couldn't open $tmp_path! $!");
	    exit TEMPFAIL;
	}
	print $tmp ($m_obj->as_mbox_string);
	close($tmp);

	unless ( $test ) {
	    unless (link($tmp_path, $new_path) ) {
		pm_log(0,"Couldn't link $tmp_path to $new_path : $!");
		exit TEMPFAIL;
	    }
	}
	unlink($tmp_path) or pm_log(1,"Couldn't unlink $tmp_path: $!");
    }
    else {
	# It's an mbox, I hope.
	my $fh = _new_fh();
	unless (open($fh, ">>$target")) {
	    pm_log(0,"Couldn't open $target! $!");
	    exit TEMPFAIL;
	}
	flock($fh, LOCK_EX)
	    or pm_log(1,"Couldn't get exclusive lock on $target");
	print $fh ($m_obj->as_mbox_string) unless $test;
	flock($fh, LOCK_UN)
	    or pm_log(1,"Couldn't unlock on $target");
	close($fh);
    }
    exit DELIVERED unless $atts{continue};
}


=head2 pm_pipe_to

This routine performs delivery to a command via a pipe.

Return the command exit status if the continue attribute is supplied.
If execution is skipped due to test mode, the return value will be 0.
See also attribute C<testalso> below.

If the name of a lockfile is supplied, multiple deliveries are throttled.

Example:

    pm_pipe_to("my_filter", lockfile => "/tmp/pm.lock");

Attributes:

=over

=item *

lockfile

The name of a file that is used to guard against multiple deliveries.
The program will try to exclusively create this file before proceding.
Upon completion, the lock file will be removed.

=item *

continue

If true, processing will continue after delivery. Otherwise the
program will exit with a DELIVERED status.

=item *

testalso

Do this, even in test mode.

=back

=cut

sub pm_pipe_to {
    my ($target, %atts) = @_;
    my $line = (caller(0))[2];
    pm_log(2, "pipe_to[$line]: $target");

    my $lock;
    my $lockfile = $atts{lockfile};
    $lock = pm_lockfile($lockfile) if $lockfile;
    local ($SIG{PIPE}) = 'IGNORE';
    my $ret = 0;
    eval {
	$ret = undef;
	my $pipe = _new_fh();
	open ($pipe, "|".$target)
	  && $m_obj->print($pipe)
	    && close ($pipe);
	$ret = $?;
    } unless $test && !$atts{testalso};

    pm_unlockfile($lock);
    pm_log (2, "pipe_to[$line]: command result = ".
	    (defined $ret ? sprintf("0x%x", $ret) : "undef"))
      unless defined $ret && $ret == 0;
    return $ret if $atts{continue};
    exit DELIVERED;
}

=head2 pm_command

Executes a system command for its side effects.

If the name of a lockfile is supplied, multiple executes are
throttled. This would be required if the command manipulates external
data in an otherwise unprotected manner.

Example:

    pm_command("grep foo some.dat > /tmp/pm.dat",
               lockfile => "/tmp/pm.dat.lock");

Attributes:

=over

=item *

lockfile

The name of a file that is used to guard against multiple executions.
The program will try to exclusively create this file before proceding.
Upon completion, the lock file will be removed.

testalso

Do this, even in test mode.

=back

=cut

sub pm_command {
    my ($target, %atts) = @_;
    my $line = (caller(0))[2];
    pm_log(2, "command[$line]: $target");

    my $lock;
    my $lockfile = $atts{lockfile};
    $lock = pm_lockfile($lockfile) if $lockfile;
    my $ret = 0;
    $ret = system($target) unless $atts{testalso};
    pm_unlockfile($lock);
    pm_log (2, "pipe_to[$line]: command result = ".
	    (defined $ret ? sprintf("0x%x", $ret) : "undef"))
      unless defined $ret && $ret == 0;
    $ret;
}

=head2 pm_resend

Send this message through to some other user.

Example:

    pm_resend("root");

Attributes:

=over

=item *

continue

If true, processing will continue after delivery. Otherwise the
program will exit with a DELIVERED status.

=back

=cut

sub pm_resend {
    my ($target, %atts) = @_;
    my $line = (caller(0))[2];
    pm_log(2, "resend[$line]: $target");
    $m_obj->smtpsend(To => $target) unless $test;
    exit DELIVERED unless $atts{continue};
}

=head2 pm_reject

Reject a message. The sender will get a mail back with the reason for
the rejection (unless stderr has been redirected).

Example:

    pm_reject("Non-existent address");

=cut

sub pm_reject {
    my $reason = shift;
    my $line = (caller(0))[2];
    pm_log(2, "reject[$line]: $reason");
    print STDERR ($reason, "\n") unless lc $logfile eq 'stderr';
    exit REJECTED;
}


=head2 pm_ignore

Ignore a message. The program will do nothing and just exit with a
DELIVERED status. A descriptive text may be passed to log the reason
for ignoring.

Example:

    pm_ignore("Another make money fast message");

=cut

sub pm_ignore {
    my $reason = shift;
    my $line = (caller(0))[2];
    pm_log(2, "ignore[$line]: $reason");
    exit DELIVERED;
}

=head2 pm_lockfile

The program will try to get an exclusive lock using this file.

Example:

    $lock_id = pm_lockfile("my.mailbox.lock");

The lock id is returned, or undef on failure.

=cut

my $lockmgr;
sub pm_lockfile {
    my ($file) = @_;

    $lockmgr = LockFile::Simple->make(-hold => 600, -stale => 1,
				      -autoclean => 1, 
				      -wfunc => sub { pm_log(2,@_) },
				      -efunc => sub { pm_log(0,@_) },
				     )
      unless $lockmgr;

    $lockmgr->lock($file, "%f");
}

=head2 pm_unlockfile

Unlocks a lock acquired earlier using pm_lockfile().

Example:

    pm_unlockfile($lock_id);

If unlocking succeeds, the lock file is removed.

=cut

sub pm_unlockfile {
    shift->release if $_[0];
}

=head2 pm_log

Logging facility. If pm_init() was supplied the name of a log file,
this file will be opened, created if necessary. Every log message
written will get a timestamp attached. The log level (first argument)
must be less than or equal to the loglevel attribute used with
pm_init(). If not, this message will be skipped.

Example:

    pm_log(2,"Retrying");

=cut

my $logfh;
sub pm_log {
    return unless $logfile;
    return if shift > $loglevel;

    # Use sysopen/syswrite for atomicity.
    unless ( $logfh ) {
	$logfh = _new_fh();
	print STDERR ("Opening logfile $logfile\n") if $debug;
	if ( lc($logfile) eq "stderr" ) {
	    open ($logfh, ">&STDERR");
	}
	elsif ( lc($logfile) eq "stdout" || $logfile eq "-" ) {
	    open ($logfh, ">&STDOUT");
	}
	else {
	    sysopen ($logfh, $logfile, O_WRONLY|O_CREAT|O_APPEND)
	      || print STDERR ("$logfile: $!\n");
	}
    }
    my @tm = localtime;
    my $msg = sprintf ("%04d%02d%02d%02d%02d%02d.%05d %s\n",
		       $tm[5]+1900, $tm[4]+1, $tm[3], $tm[2], $tm[1], $tm[0],
		       $$, "@_");
    print STDERR ($msg) if $debug;
    syswrite ($logfh, $msg);
}

sub _new_fh {
    return if $] >= 5.006;	# 5.6 will take care itself
    require IO::File;
    IO::File->new();
}

=head1 USING WITH PROCMAIL

The following lines at the start of .procmailrc will cause a copy of
each incoming message to be saved in $HOME/syslog/mail, after which
the procmail-pl is run as a TRAP program (see the procmailrc
documentation). As a result, procmail will transfer the exit status of
procmail-pl to the mail transfer agent that invoked procmail (e.g.,
sendmail, or postfix).

    LOGFILE=$HOME/syslog/procmail
    VERBOSE=off
    LOGABSTRACT=off
    EXITCODE=
    TRAP=$HOME/bin/procmail-pl

    :0:
    $HOME/syslog/mail

The original contents of the .procmailrc can be safely left in place
after these lines.

=head1 EXAMPLE

An extensive example can be found in the examples directory of the
C<Mail::Procmail> kit.

=head1 SEE ALSO

L<Mail::Internet>

L<LockFile::Simple>

procmail documentation.

=head1 AUTHOR

Johan Vromans, Squirrel Consultancy <jvromans@squirrel.nl>

Some parts are shamelessly stolen from Mail::Audit by Simon Cozens
<simon@cpan.org>, who admitted that he stole most of it from programs
by Tom Christiansen.

=head1 COPYRIGHT and DISCLAIMER

This program is Copyright 2000 by Squirrel Consultancy. All
rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of either: a) the GNU General Public License as
published by the Free Software Foundation; either version 1, or (at
your option) any later version, or b) the "Artistic License" which
comes with Perl.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See either the
GNU General Public License or the Artistic License for more details.

=cut

1;

# Local Variables:
# compile-command: "perl -wc Procmail.pm && install -m 0555 Procmail.pm $HOME/lib/perl5/Mail/Procmail.pm"
# End:
