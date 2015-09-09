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

# COPY from Chj/xhome.pm, just don't want to depend on File::HomeDir
# or something until it's clear which one to use (and how to write
# files portably...)
sub xeffectiveuserhome () {
    my $uid= $>;
    my ($name,$passwd,$_uid,$gid,
	$quota,$comment,$gcos,$dir,$shell,$expire)
      = getpwuid $uid
	or die "unknown user for uid $uid";
    $dir
}
# /COPY

*safe_HOME= *xeffectiveuserhome;

1
