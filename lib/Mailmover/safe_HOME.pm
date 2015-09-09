#
# Copyright 2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::safe_HOME - de-tainted, hopefully safe, HOME env var

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Mailmover::safe_HOME;
@ISA="Exporter"; require Exporter;
@EXPORT=qw(safe_HOME);
@EXPORT_OK=qw();
%EXPORT_TAGS=(all=>[@EXPORT,@EXPORT_OK]);

use strict; use warnings FATAL => 'uninitialized';

sub safe_HOME {
    my ($home)= $ENV{HOME}=~ m{^(/home/\w+)/?\z}
      or die "weird HOME: '$ENV{HOME}'";
    $home
}

1
