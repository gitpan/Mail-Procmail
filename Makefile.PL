# Makefile.PL -- Makefile for Mail::Procmail
# Author          : Johan Vromans
# Created On      : Tue Aug  8 19:56:07 2000
# Last Modified By: Johan Vromans CPWR
# Last Modified On: Wed Aug  9 10:24:44 2000
# Update Count    : 13
# Status          : Stable

# Verify perl version.
require 5.005;

use ExtUtils::MakeMaker;

WriteMakefile
  (
   NAME         => 'Mail::Procmail',
   ($] >= 5.005) ?
   ( AUTHOR	=> 'Johan Vromans (jvromans@squirrel.nl)',
     ABSTRACT	=> 'Procmail-like functionality for mail filtering' ) : (),
   VERSION_FROM => "lib/Mail/Procmail.pm",
   PREREQ_PM	=> { 'Getopt::Long' => 2.00,
		     'Mail::Internet' => 0,
		     'LockFile::Simple' => 0 },
   # *.pm files will be picked up automatically from ./lib
 );
