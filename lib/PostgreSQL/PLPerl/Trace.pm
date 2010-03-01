package PostgreSQL::PLPerl::Trace;

# based on Devel::Trace
# adds ability to show src for code outside Safe while
# executing from code inside Safe

=pod for full tracing

set env var:

    PERL5DB='BEGIN { use lib qw(/Users/timbo/pg/PostgreSQL-PLPerl-Trace/lib); require PostgreSQL::PLPerl::Trace }'

and add -d to PERL5OPT env var

=cut


our $VERSION = '0.10';
our $TRACE = 1;

my $main_glob = *{"main::"};
my $main_stash = \%{$main_glob};
my $file_sub_prev;


sub DB::DB { # magic sub

    return unless $TRACE;

    my ($p, $f, $l) = caller();

    my $code = \@{"::_<$f"};
    if (!@$code) { # probably inside Safe
        my $glob = $main_stash->{"_<$f"};
        $code = \@{$glob};
    }

    my $sub = (caller(1))[3];
    my $linesrc = $code->[$l];
    if (!$linesrc) { # should never happen
        my $submsg = $sub ? " for sub $sub" : "";
        $linesrc = "\t(missing src$submsg in $p)";
    }
    chomp $linesrc;

    my $file_sub = "$f/$sub";
    if ($file_sub ne $file_sub_prev) {
        print STDERR "-- in $sub:\n" if $sub;
        $file_sub_prev = $file_sub;
    }

    print STDERR ">> $f:$l: $linesrc\n";
}


$^P |= 0
#   |  0x001  # Debug subroutine enter/exit.
    |  0x002  # Line-by-line debugging & save src lines.
    |  0x004  # Switch off optimizations.
    |  0x008  # Preserve more data for future interactive inspections.
    |  0x010  # Keep info about source lines on which a subroutine is defined.
    |  0x020  # Start with single-step on.
#   |  0x080  # Report "goto &subroutine" as well.
    |  0x100  # Provide informative "file" names for evals
    |  0x200  # Provide informative names to anonymous subroutines
    |  0x400  # Save source code lines into "@{"_<$filename"}".
    ;


1;

# vim: ts=8:sw=4:et
