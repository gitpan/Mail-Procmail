print("1..4\n");

eval { require Mail::Procmail; Mail::Procmail->import; };
print("$@\nnot ") if $@;
print("ok 1\n");

open(STDIN, "<&DATA");

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

print("ok 2\n");

print("lines = $m_lines\nnot ") unless $m_lines == 1;
print("ok 3\n");

print("not ") unless $m_to =~ /jane/;
print("ok 4\n");

__END__
From: Joe User <joe@user.org>
To: Jane Doe <jane@user.org>, postmaster@acme.org
Subject: Fee Fie Foo Fum

Blah
