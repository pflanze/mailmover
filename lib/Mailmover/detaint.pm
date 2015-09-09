#
# Copyright 2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::detaint

=head1 SYNOPSIS

=head1 DESCRIPTION

There's sometHing on CPAN. But it's not on my system.

=cut


package Mailmover::detaint;
@ISA="Exporter"; require Exporter;
@EXPORT=qw(detaint);
@EXPORT_OK=qw(detaint1);
%EXPORT_TAGS=(all=>[@EXPORT,@EXPORT_OK]);

use strict; use warnings FATAL => 'uninitialized';

sub detaint1 {
    my ($v)=@_;
    $v=~ /^(.*)\z/s or die "??";
    $1
}

sub detaint {
    wantarray ?
      map {
	  detaint1 $_
      } @_
	: detaint1 $_[0]
}

1
