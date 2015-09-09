#
# Copyright 2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::FirstFoundPath

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Mailmover::FirstFoundPath;
@ISA="Exporter"; require Exporter;
@EXPORT=qw(xfirst_found_path);
@EXPORT_OK=qw();
%EXPORT_TAGS=(all=>[@EXPORT,@EXPORT_OK]);

use strict; use warnings FATAL => 'uninitialized';

use FP::Stream;
use Chj::singlequote qw(singlequote_many);

sub xfirst_found_path {
    my $found= stream(@_)->filter (sub { -e $_[0] });
    $found->is_null ? die "none of these paths exist: ".singlequote_many(@_)
      : $found->first
}

1
