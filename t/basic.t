# $Id: basic.t,v 1.1 2002-05-08 14:17:54+02 jv Exp $	-*-perl-*-

print("1..4\n");

eval { require Mail::Procmail; Mail::Procmail->import; };
if ( $@ ) {
    print("require Mail::Procmail: $@\nnot ok 1\n");
    die("Aborted");
}
print("ok 1\n");

# It is tempting to use DATA, but this seems to give problems on some
# perls on some platforms.
unless ( open(STDIN, "t/basic.dat") ) {
    print ("t/basic.dat: $!\nnot ok 2\n");
    die("Test aborted\n");
}
print("ok 2\n");

my $m_obj = pm_init ( logfile => 'stderr', loglevel => 2 );

my $m_from		    = pm_gethdr("from");
my $m_to		    = pm_gethdr("to");
my $m_subject		    = pm_gethdr("subject");

my $m_header                = $m_obj->head->as_string || '';
my $m_body                  = join("", @{$m_obj->body});
my $m_size		    = length($m_body);
my $m_lines		    = @{$m_obj->body};

# Start logging.
pm_log(3, "Mail from $m_from");
pm_log(3, "To: $m_to");
pm_log(3, "Subject: $m_subject");

print("lines = $m_lines\nnot ") unless $m_lines == 1;
print("ok 3\n");

print("not ") unless $m_to =~ /jane/;
print("ok 4\n");
