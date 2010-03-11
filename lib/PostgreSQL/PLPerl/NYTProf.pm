package PostgreSQL::PLPerl::NYTProf;

# vim: ts=8 sw=4 expandtab:

=head1 NAME

PostgreSQL::PLPerl::NYTProf - Profile PostgreSQL PL/Perl functions with Devel::NYTProf

=head1 SYNOPSIS

Load via a line in your F<plperlinit.pl> file:

    use PostgreSQL::PLPerl::NYTProf;

Load via the C<PERL5OPT> environment variable:

    $ PERL5OPT='-MPostgreSQL::PLPerl::NYTProf' pg_ctl ...

=head1 DESCRIPTION

Profile PL/Perl functions inside PostgreSQL database with C<Devel::NYTProf>. 

=head1 ENABLING

In order to use this module you need to arrange for it to be loaded when
PostgreSQL initializes a Perl interpreter.

Create a F<plperlinit.pl> file in the same directory as your
F<postgres.conf> file, if it doesn't exist already.

In the F<plperlinit.pl> file write the code to load this module:

    use PostgreSQL::PLPerl::NYTProf;

When it's no longer needed just comment it out by prefixing with a C<#>.

=head2 PostgreSQL 8.x

Set the C<PERL5OPT> before starting postgres, to something like this:

    PERL5OPT='-e "require q{plperlinit.pl}"'

The code in the F<plperlinit.pl> should also include C<delete $ENV{PERL5OPT};>
to avoid any problems with nested invocations of perl, e.g., via a C<plperlu>
function.

=head2 PostgreSQL 9.0

For PostgreSQL 9.0 you can still use the C<PERL5OPT> method described above.
Alternatively, and preferably, you can use the C<plperl.on_init> configuration
variable in the F<postgres.conf> file.

    plperl.on_init='require q{plperlinit.pl};'

=head2 Alternative Method

It you're not already using the C<PERL5OPT> environment variable to load a
F<plperlinit.pl> file, as described above, then you can use it as a quick way
to load the module for ad-hoc use:

    $ PERL5OPT='-MPostgreSQL::PLPerl::NYTProf' pg_ctl ...

=head1 USAGE

By default the NYTProf profile data files will be written into the database
directory, alongside your F<postgres.conf>, with the process id of the backend
appended to the name. For example F<nytprof.out.54321>.

You'll get one profile data file for each database connection. You can use the
C<nytprofmerge> utility to merge multiple data files.

To generate a remort from a data file, use a command like:

  nytprofhtml --file=$PGDATA/nytprof.out.54321 --open

=head1 LIMITATIONS

XXX Currently only PostgreSQL 9.0 is fully supported

=head2 PL/Perl Function Names Are Missing

The names of functions defined using CREATE FUNCTION don't show up in
NYTProf because they're compiled as anonymous subs using a string eval.
There's no easy way to determine the PL/Perl function name because it's only
known to the postgres internals.

XXX a workaround is being developed.

=head2 For PostgreSQL 8 an explicit call to DB::finish_profile is needed

Postgres 8 doesn't execute END blocks when it shuts down, so NYTProf
doesn't get a chance to terminate the profile cleanly. To get a usable profile
you need to explicitly call finish_profile() in your plperl code.

=head2 Can't use plperl and plperlu at the same time

Postgres uses separate Perl interpreters for the plperl and plperlu languages.
NYTProf is not multiplicity safe (as of version 3.02). It should just profile
whichever language was used first and ignore the second but at the moment the
initialization of the second interpreter fails.

=head1 SEE ALSO

L<Devel::NYTProf>

=head1 AUTHOR

B<Tim Bunce>, L<http://www.tim.bunce.name> and L<http://blog.timbunce.org>

=head1 COPYRIGHT AND LICENSE

  Copyright (C) 2009 by Tim Bunce.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

use strict;

use PostgreSQL::PLPerl::Injector qw(
    inject_plperl_with_names
);

use Devel::NYTProf::Core;

# set some default options (can be overridden via NYTPROF env var)
DB::set_option("endatexit", 1); # for pg 8.4
DB::set_option("savesrc", 1);
DB::set_option("addpid", 1);
# file defaults to nytprof.out.$pid in $PGDATA directory

inject_plperl_with_names(qw(
    DB::enable_profile
    DB::disable_profile
    DB::finish_profile
));

# load Sub::Name and make Sub::Name::subname available to plperl
use Sub::Name;
inject_plperl_with_names('Sub::Name::subname');

my $trace = $ENV{PLPERL_NYTPROF_TRACE} || 0;
my @on_init;
my $mkfuncsrc = "PostgreSQL::InServer::mkfuncsrc";

if (defined &{$mkfuncsrc}) {
    # We were probably loaded via plperlinit.pl
    fix_mkfuncsrc();
}
else {
    # We were probably loaded via PERL5OPT='-M...' and so we're executing very
    # early, before mkfuncsrc has even been defined.
    # So we need to defer wrapping it until later.
    # We do that by wrapping  PostgreSQL::InServer::Util::bootstrap
    # But that doesn't exist yet either. Happily it will do a INIT time
    # so we arrange to wrap it then. Got that?
    push @on_init, sub {
        hook_after_sub("PostgreSQL::InServer::Util::bootstrap", \&fix_mkfuncsrc);
    };
}

INIT { $_->() for @on_init }


sub fix_mkfuncsrc {

    # wrap mkfuncsrc with code that edits the returned code string
    # such that the code will call Sub::Name::subname to give a name
    # to the subroutine it defines.

    hook_after_sub("PostgreSQL::InServer::mkfuncsrc", sub {
        my ($argref, $code) = @_;
        my $name = $argref->[0];

        # $code = qq[ package main; undef *{'$name'}; *{'$name'} = sub { $BEGIN $prolog $src } ];
        #$code =~ s/; \s \*\{' (\w+?) '\} \s = \s sub (.*)/; sub $1 $2; warn my \$globref = \\*{'$1'}; \$\$globref;/x
        #$code =~ s/; \s \*\{' (\w+?) '\} \s = \s sub (.*)/; sub $1 $2; warn my \$globref = *$1\{GLOB}; \$\$globref;/x
        # XXX escape $name or extract from $code and use single quotes
        $code =~ s/= \s sub/= Sub::Name::subname qw($name), sub/x
            or warn "Failed to edit sub name in $code"
            if $name =~ /^\w+$/; # XXX just sane names for now

        return $code;
    });
}

sub hook_after_sub {
    my ($sub, $code, $force) = @_;

    warn "Wrapping $sub\n" if $trace;
    my $orig_sub = (defined &{$sub}) && \&{$sub};
    if (not $orig_sub and not $force) {
        warn "hook_after_sub: $sub isn't defined\n";
        return;
    }

    my $wrapped = sub {
        warn "Wrapped $sub(@_) called\n" if $trace;
        my @ret;
        if ($orig_sub) {
            # XXX doesn't handle context
            # XXX the 'package main;' here is a hack to make
            # PostgreSQL::InServer::Util::bootstrap do the right thing
            @ret = do { package main; $orig_sub->(@_) };
        }
        return $code->( [ @_ ], @ret );
    };

    no warnings 'redefine';
    no strict;
    *{$sub} = $wrapped;
}

require Devel::NYTProf; # init profiler - do this last

__END__
