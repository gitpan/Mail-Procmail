Summary: This is MailTools, a set of perl modules related to mail applications
%define module MailTools
%define path   Mail
Name: perl-%{module}
Version: 1.15
Release: 1
Source: http://www.perl.com/CPAN/modules/by-module/%{path}/%{module}-%{version}.tar.gz
Copyright: Same as Perl
Group: Mail/Tools
Packager: Johan Vromans <jvromans@squirrel.nl>
BuildRoot: /usr/tmp/%{name}-buildroot
Requires: perl >= 5.6.0
BuildRequires: perl >= 5.6.0
BuildArchitectures: noarch

%description
This is MailTools, a set of perl modules related to mail applications.

This is the old (latest) version from Graham Barr.

%prep
%setup -n %{module}-%{version}

%build
perl Makefile.PL
make all
make test

%install
rm -fr $RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT/usr
make install PREFIX=$RPM_BUILD_ROOT/usr

# Remove some unwanted files
find $RPM_BUILD_ROOT -name .packlist -exec rm -f {} \;
find $RPM_BUILD_ROOT -name perllocal.pod -exec rm -f {} \;

# Compress manual pages
test -x /usr/lib/rpm/brp-compress && /usr/lib/rpm/brp-compress

# Build distribution list
( cd $RPM_BUILD_ROOT ; find * -type f -printf "/%p\n" ) > files

%files -f files
%doc README
