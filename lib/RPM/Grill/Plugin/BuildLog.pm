# -*- perl -*-
#
# RPM::Grill::Plugin::BuildLog - check for warnings in build logs
#
# $Id$
#
# Real-world packages that trigger errors in this module:
#
#    thunderbird-3.1.6-1.el6_0    IntegerOverflow
#
# See t/RPM::Grill/Plugin/90real-world.t
#
package RPM::Grill::Plugin::BuildLog;

use base qw(RPM::Grill);

use strict;
use warnings;
our $VERSION = '0.01';

use Carp;
use RPM::Grill::Util		qw(sanitize_text);
use Tie::File;
use Fcntl               qw(O_RDONLY);

# Program name of our caller
( our $ME = $0 ) =~ s|.*/||;

###############################################################################
# BEGIN user-configurable section

# Sequence number for this plugin
sub order {92}

# One-line description of this plugin
sub blurb { return "reports compile-time problems you may have missed" }

sub doc {
    return <<"END_DOC" }
This module scans the build logs (all arches), looking for
and griping about common warnings. These are warnings that
may still result in a successful build but which could result
in broken or insecure executables.
END_DOC

#
# These are the regexps we look for in the build log.  For any that we see,
# we gripe with the corresponding code and other details.  Format is:
#
#    # blah blah comments
#    string-starting-at-beginning-of-line is a one-line regex to look for
#       code    => SomeUniqueStudlyCapsName
#       context => optional list of lines before and after
#
my $Watch_For = <<'END_WATCH_FOR';
# RFE 250127
/var/tmp/rpm-tmp\\.[^:]+: line [0-9]+: fg: no job control
  code => 'MacroExpansion'
  diag => Possible error in macro expansion

# RFE 157465
will always overflow destination buffer
  code => 'BufferOverflow'

# RFE 225186
# 2011-02-16 this now has two variations. Deal with either one:
#  warning: dereferencing type-punned pointer will break strict-aliasing rules
#  warning: dereferencing pointer ‘foo’ does break strict-aliasing rules
break strict-aliasing rules
  code    => 'TypePun'
  diag    => gcc warnings
  context => -1

# bz642228: possible security-related check being optimized away
assuming signed overflow does not occur
  code => 'IntegerOverflow'
  diag => Possible integer overflow (this may be a security problem)
#  [WAIVER_NEEDS_SEC_RESPONSE]


memset used with constant zero length parameter
  code    => 'BrokenMemset'
  context => -4,+2

# RFE 438709: warn about patches that didn't get applied properly
missing header for unified diff at line
  code    => 'PatchApply'
  diag    => Possible failure to apply a patch
  context => -2

# Errors from make
# eg  make[1]: *** [linuxthreads/tests] Error 2
^make.* \*\*\* .* Error
  code    => 'MakeError'
  diag    => Possible error from 'make'
  context => -3

# 2011-04-07 see rsyslog-3.22.1-3.el5_5.1
# eg autom4te: /usr/bin/m4 failed with exit status: 63
failed with exit status:
  code    => 'MiscBuildError'
  diag    => Possible error in build
  context => -3
END_WATCH_FOR

my @Watch_For;
LINE:
for my $line ( split "\n", $Watch_For ) {
    next LINE if $line =~ /^\s*\#/;    # skip comments

    if ( $line =~ /^\S/ ) {
        push @Watch_For,
            {
            re      => qr/$line/,
            context => { '-' => 0, '+' => 0 },
            };
    }
    elsif ( $line =~ /^\s+(\S+)\s+=>\s+(.*)/ ) {
        my ( $key, $val ) = ( $1, $2 );

        # Strip quotation marks
        $val =~ s/^('|")(.*)\1$/$2/;

        if ( $key eq 'context' ) {
            $val =~ /^([+-])(\d+)(,([+-])(\d+))?$/
                or die "$ME: Internal error: invalid context '$val'";
            $Watch_For[-1]->{$key}->{$1} = $2;
            $Watch_For[-1]->{$key}->{$4} = $5 if $3;
        }
        else {

            # Anything else
            $Watch_For[-1]->{$key} = $val;
        }
    }
    elsif ( $line =~ /\S/ ) {
        die "$ME: Internal error: Cannot grok config line '$line'";
    }
}

# Sanity checks: make sure all regexps have a code
if ( my @missing = grep { !$_->{code} } @Watch_For ) {
    die "$ME: Internal error: Missing 'code' for $missing[0]->{re}";
}

# These arches do not need a build log
our %Does_Not_Need_Build_Log = map { $_ => 1 } qw(noarch maven win images);

# END   user-configurable section
###############################################################################

#
# Calls $self->gripe() with problems
#
sub analyze {
    my $self = shift;    # in: FIXME

    # Main loop: check build log for each arch
ARCH:
    for my $arch ( $self->non_src_arches ) {
        my $build_log = $self->path( $arch, 'build.log' );

        # @lines will be an array of lines in the file.  Relax,
        # this is memory-safe: it doesn't slurp the file into RAM.
        tie my @lines, 'Tie::File', $build_log, mode => O_RDONLY
            or do {
                warn "$ME: WARNING: Cannot read build log $build_log: $!\n"
                    unless $Does_Not_Need_Build_Log{$arch};
                next ARCH;
            };

        # Used to track rpm stages like %prep, %build, %install
        my $current_stage;

        for ( my $lineno = 0; $lineno < @lines; $lineno++ ) {
            my $line = $lines[$lineno];

            # Keep track of current rpm build stage, e.g.
            #
            #    Executing(%prep): /bin/sh -e /var/tmp/rpm-tmp.36453
            #
            if ( $line =~ /^Executing\((%.+)\):\s/ ) {
##                print $arch, " ", $1,"\n";
                $current_stage = $1;
            }

            for my $tuple (@Watch_For) {
                if ( $line =~ /$tuple->{re}/ ) {
                    my $from = $lineno - $tuple->{context}->{'-'};
                    my $to   = $lineno + $tuple->{context}->{'+'};

                    # Actual context lines
                    my @context = map { sanitize_text($_) } @lines[ $from .. $to ];

                    # Where that context is
                    my %context = (
                        path   => "$arch/build.log",
                        lineno => $lineno,
                        excerpt => \@context,
                    );
                    $context{sub} = "(in $current_stage)" if $current_stage;

        #                    print "\n", join("\n",@lines[$from .. $to]),"\n";
                    $self->gripe(
                        {   code    => $tuple->{code},
                            arch    => $arch,
                            diag    => $tuple->{diag} || 'Possible build error',
                            context => \%context,
                        }
                    );
                }
            }
        }
    }
}

1;

###############################################################################
#
# Documentation
#

=head1	NAME

FIXME - FIXME

=head1	SYNOPSIS

    use Fixme::FIXME;

    ....

=head1	DESCRIPTION

FIXME fixme fixme fixme

=head1	CONSTRUCTOR

FIXME-only if OO

=over 4

=item B<new>( FIXME-args )

FIXME FIXME describe constructor

=back

=head1	METHODS

FIXME document methods

=over 4

=item	B<method1>

...

=item	B<method2>

...

=back


=head1	EXPORTED FUNCTIONS

=head1	EXPORTED CONSTANTS

=head1	EXPORTABLE FUNCTIONS

=head1	FILES

=head1  DIAGNOSTICS

=over 4

=item   MacroExpansion

This test has not yet triggered. If it does, it probably means you
have something like this in your specfile:

    (cd subdir; %patch ...)

...which looks sane until you realize that C<%patch> only works
at the beginning of a line in the specfile, and something like
the above is interpreted by the shell, which uses percent as
job control.

=item   BufferOverflow

Your build log includes the words C<will always overflow destination buffer>,
which indicate a gcc warning that might be worth double-checking.

=item   TypePun

This can often be fixed by adding C<-fno-strict-aliasing> to CFLAGS.

=item   IntegerOverflow

See L<securecoding.cert.org|https://www.securecoding.cert.org/confluence/display/seccode/INT32-C.+Ensure+that+operations+on+signed+integers+do+not+result+in+overflow> for much more information.

=item   BrokenMemset

Your build log includes the words C<memset used with constant zero length parameter>.

=item   PatchApply

Possibly corrupt patch. You are encouraged to investigate.

=item   MakeError

Possible error trapped by 'make'. This indicates the presence of
C<make [...] Error> somewhere in the log.

=item   MiscBuildError

Possible error in the build log. This indicates the presence of
C<failed with exit status:> somewhere in the log.

=back

=head1	SEE ALSO

=head1	AUTHOR

Ed Santiago <santiago@redhat.com>

=cut
