my $RCS_Id = '$Id: Procmail.pm,v 1.4 2000-08-09 10:58:16+02 johanv Exp $ ';

# Author          : Johan Vromans
# Created On      : Tue Aug  8 13:53:22 2000
# Last Modified By: Johan Vromans CPWR
# Last Modified On:
# Update Count    : 116
# Status          : Unknown, Use with caution!

=head1 NAME

Mail::Procmail - Procmail-like facility for creating easy mail filters.

=head1 SYNOPSIS

    use Mail::Procmail;

    my $m_obj = pm_init (
			 logfile   => "/tmp/pm.log",
			 loglevel  => 3
			);

    my $m_from		    = pm_gethdr("from");
    my $m_to		    = pm_gethdr("to");
    my $m_subject		    = pm_gethdr("subject");

    my $default = "/var/spool/mail/".$ENV{USER};

    # Start logging.
    pm_log(1, "Mail from $m_from");
    pm_log(1, "To: $m_to");
    pm_log(1, "Subject: $m_subject");

    # Save a copy just in case.
    pm_deliver("/tmp/savemail", continue => 1);

    pm_ignore("Non-ASCII in subject")
      if $m_subject =~ /[\232-\355]{3}/;

    pm_resend("joan")
      if $m_to =~ /jk@/i;

    pm_deliver($default, continue => 1)
      if $m_subject =~ /getopt(ions|(-|::)?long)/i;

    # And so on ...

=head1 DESCRIPTION

F<procmail> is nasty. It has a tortuous and complicated recipe format,
and I don't like it. I wanted something flexible whereby I could
filter my mail using Perl tests.

C<Mail::Procmail> is inspired by Simon Cozen's C<Mail::Audit> that was
inspired by Tom Christiansen's F<audit_mail> and F<deliverlib>
programs. It allows a piece of email to be logged, examined, accepted
into a mailbox, filtered, resent elsewhere, rejected, and so on. It's
designed to allow you to easily create filter programs to stick in a
F<.forward> file or similar.

=head1 EXPORTED ROUTINES

Note that most delivery routines exit the program unless the attribute
"continue=>1" is passed.

Also, the delivery routines log the line number in the calling program
so it is easy to find out which 'rule' caused a specific delivery to
take place.

=cut

################ Common stuff ################

package Mail::Procmail;

$VERSION = 0.02;

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

use constant REJECTED	=> 100;
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

=item *

loglevel

The amount of information that will be logged.

=item *

test

If true, no actual delivery will be done. Suitable to test a new setup.

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

Example:

    $m_to = gethdr("to");

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

    pm_deliver("/var/spool/mail/".$ENV{USER});

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
    if ( $test ) {
	exit DELIVERED unless $atts{continue};
	return;
    }

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

	unless (link($tmp_path, $new_path) ) {
	    pm_log(0,"Couldn't link $tmp_path to $new_path : $!");
	    exit TEMPFAIL;
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
	print $fh ($m_obj->as_mbox_string);
	flock($fh, LOCK_UN)
	    or pm_log(1,"Couldn't unlock on $target");
	close($fh);
    }
    exit DELIVERED unless $atts{continue};
}


=head2 pm_pipe_to

This routine performs delivery to a command via a pipe.

If the name of a lockfile is supplied, multiple deliveries are throttled.

Example:

    pm_pipe_to("|procmail", lockfile => "/tmp/pm.lock");

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

    if ( $test && !$atts{testalso} ) {
	exit DELIVERED unless $atts{continue};
	return;
    }
    my $lock;
    my $lockfile = $atts{lockfile};
    $lock = pm_lockfile($lockfile) if $lockfile;
    local ($SIG{PIPE}) = 'IGNORE';
    eval {
	my $pipe = _new_fh();
	open ($pipe, "|".$target)
	  && $m_obj->print($pipe)
	    && close ($pipe);
    };
    pm_unlockfile($lock);
    printf STDERR ("command result = 0x%x\n", $?) if $? && $debug;
    exit DELIVERED unless $atts{continue};
    $?;
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
    if ( $test ) {
	exit DELIVERED unless $atts{continue};
	return;
    }
    $m_obj->smtpsend(To => $target);
    exit DELIVERED unless $atts{continue};
}

=head2 pm_reject

Reject a message. The sender will get a mail back with the reason for
the rejection.

Example:

    pm_reject("Non-existent address");

=cut

sub pm_reject {
    my $reason = shift;
    my $line = (caller(0))[2];
    pm_log(2, "reject[$line]: $reason");
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
    my $msg = sprintf ("%04d/%02d/%02d %02d:%02d:%02d %s\n",
		       $tm[5]+1900, $tm[4]+1, $tm[3], $tm[2], $tm[1], $tm[0],
		       "@_");
    print STDERR ($msg) if $debug;
    syswrite ($logfh, $msg);
}

sub _new_fh {
    return if $] >= 5.006;	# 5.6 will take care itself
    require IO::File;
    IO::File->new();
}

=head1 EXAMPLE

A live example from my personal mail filter.

    # Log file and log level.
    my $logfile = "test.log";
    my $loglevel = 3;

    # The default mailbox for delivery.
    my $default = "/var/spool/mail/".$ENV{USER};

    # Save a copy here, just in case.
    my $copy = $ENV{HOME}."/syslog/mail";

    # A pattern to break out words in email names.
    my $wordpat = qr/[-a-zA-Z0-9_.]+/;

    # Destination for special emails.
    sub incoming { $ENV{HOME}."/Mail/Incoming/".$_[0].".spool" }

    # Destination for mailing lists.
    sub maillist { incoming("maillists.".$_[0]) }

    # Destination for SPAM.
    my $spam = incoming("spam");

    use Mail::Procmail;

    # Setup Procmail.
    my $m_obj = pm_init (
			 logfile   => $logfile,
			 loglevel  => $loglevel,
			);

    # Init local values for often used headers.
    my $m_from		    = pm_gethdr("from");
    my $m_to		    = pm_gethdr("to");
    my $m_cc		    = pm_gethdr("cc");
    my $m_subject	    = pm_gethdr("subject");
    my $m_sender	    = pm_gethdr("sender");
    my $m_apparently_to	    = pm_gethdr("apparently-to");
    my $m_resent_to	    = pm_gethdr("resent-to");
    my $m_resent_cc	    = pm_gethdr("resent-cc");
    my $m_resent_from	    = pm_gethdr("resent-from");
    my $m_resent_sender	    = pm_gethdr("resent-sender");
    my $m_apparently_resent_to  = pm_gethdr("apparently-resent-to");

    my $m_header            = $m_obj->head->as_string || '';
    my $m_body              = join("\n", @{$m_obj->body});

    my $m_TO                = join("\n", $m_to, $m_cc, $m_apparently_to,
				     $m_resent_to, $m_resent_cc,
				     $m_apparently_resent_to);
    my $m_FROM              = join("\n", $m_from, $m_sender,
				     $m_resent_from, $m_resent_sender);

    # Start logging.
    pm_log(1, "Mail from $m_from");
    pm_log(1, "To: $m_to");
    pm_log(1, "Subject: $m_subject");

    # Save a copy just in case.
    pm_deliver($copy, continue => 1);

    ################ Get rid of spams ################

    pm_ignore("Non-ASCII in subject")
      if $m_subject =~ /[\232-\355]{3}/;

    pm_ignore("Bogus address: \@internet.squirrel.nl")
      if $m_TO =~ /\@internet.squirrel.nl/mi;

    ################ Dispatching ################

    # External mail to xxx@squirrel.nl is delivered to me. Dispatch here.
    # Internal mail to xxx@squirrel.nl is delivered via aliases.

    if ( $m_TO =~ /jkensen@/mi ) {
	# Maybe CC to me?
	pm_deliver($default, continue => 1)
	  if $m_TO =~ /jv(romans)?@/mi;
	# Send to Joan.
	pm_resend("joan");
    }

    ################ Intercepting ################

    pm_deliver($default, continue => 1)
      if $m_header =~ /getopt(ions|(-|::)?long)/i
      || $m_body   =~ /getopt(ions|(-|::)?long)/i;

    pm_deliver($default)
      if $m_subject =~ /MODERATE/;

    ################ Mailing lists ################

    if ( $m_sender =~ /owner-($wordpat)@($wordpat)/i ) {
	my ($topic, $host) = ($1, $2);

	if ( $host eq "perl.org" ) {
	    $topic = "perl-" . $topic
	      unless $topic =~ /^perl/;
	}
	elsif ( $topic eq "announce" ) {
	    if ( $host eq "htmlscript.com" ) {
		$topic = "htmlscript";
	    }
	}

	pm_deliver(maillist($topic));
    }

    for ( pm_gethdr("x-mailing-list"),
	  pm_gethdr("list-post"),
	  pm_gethdr("mailing-list") ) {

	my ($topic, $host);

	if ( ($topic, $host) = /($wordpat)@($wordpat)/i ) {

	    if ( $host eq "perl.org" ) {
		$topic = "perl-" . $topic
		  unless $topic =~ /^perl/;
		$topic =~ s/-help$//;
	    }
	}

	pm_deliver(maillist($topic)) if defined $topic;
    }

    ###### Miscellaneous

    pm_deliver(maillist("perl-xml"))
      if pm_gethdr("x-listname") =~ /perl-xml/i
      || pm_gethdr("list-id") =~ /<perl-xml\./i;

    pm_deliver(maillist("perlpoint"))
      if $m_TO =~ /perlpoint@/mi;

    pm_deliver(maillist("perl-friends"))
      if pm_gethdr("x-loop") =~ /^perl-friends/i;

    if ( $m_TO =~ /(info|bug-)?vm[@%]/mi ) {
	deliver_continue($default)
	  if $m_subject =~ /^\[announcement\]/i;

	# VM mailing lists catches a lot of SPAM.
	# Make sure VM is at least mentioned in the body...
	pm_deliver(maillist("vm"))
	  if $m_body =~ /\bvm\b/i;
	spam("VM spam");
    }

    pm_deliver(incoming("pause"))
      if $m_FROM =~ /PAUSE.*upload[@%]/mi
      || $m_TO =~ /cpan-testers\@perl.org/mi;

    pm_deliver(maillist("ttf2pt1"))
      if pm_gethdr("list-id") =~ /ttf2pt1-(users|announce|devel)\./i;

    # $pm_hostname is exported by Mail::Procmail and can be used
    # for system-dependent filtering.
    if ( $pm_hostname eq "phoenix.squirrel.nl" ) {
	if ( $m_from =~ /\(johan vromans\)/i
	     && $m_subject =~ /plume updates/i
	     && $m_TO =~ /jvromans\@squirrel\.nl/mi ) {
	    my $cmd = $ENV{HOME}."/etc/pm_getxfer";
	    pm_pipe_to ($cmd, lockfile => $cmd.".lock");
	}

    }

    ################ Despamming ################

    # Discard mail that is not addressed to or from me.

    spam("Not for me")
      if $m_apparently_to =~ /<(jv|johan)/i;

    spam("Not for me")
      unless $m_TO =~ /(jv@|jvromans@|johan|squirrel|cron|newsletter@)/mi
      || $m_FROM   =~ /(jv@|jvromans@|johan|squirrel|cron|newsletter@)/mi;

    # Run separate despam filter.
    my $lock = pm_lockfile($ENV{HOME}."/bin/x-despam.lock");
    eval {
	my $pipe;
	open ($pipe, "|".$ENV{HOME}."/bin/x-despam")
	  && $m_obj->print($pipe)
	    && close ($pipe);
	pm_unlockfile($lock);
	printf STDERR ("command result = 0x%x\n", $?) if $? && $debug;
	spam("Rejected by despam filter, result = ". sprintf("0x%x", $?))
	  if $? && 0xff00;
    };
    pm_unlockfile($lock);

    # If we get here, it's good mail.
    pm_deliver($default);

    sub spam {
	my ($reason, %atts) = @_;
	my $line = (caller(0))[2];
	pm_log(2, "spam[$line]: $reason");
	pm_deliver($spam, %atts);
    }

=head1 SEE ALSO

L<Mail::Internet>

L<LockFile::Simple>

procmail documentation.

=head1 AUTHOR

Johan Vromans, Squirrel Consultancy <jvromans@squirrel.nl>

Some parts are shamelessly stolen from Mail::Audit by Simon Cozens
<simon@cpan.org>, who admitted that he stole most of it from Tom
Christiansen.

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
