#
# Copyright 2007-2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::MailUtil

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Mailmover::MailUtil;
@ISA="Exporter"; require Exporter;
@EXPORT=qw();
@EXPORT_OK=qw(pick_out_of_anglebrackets
       	      pick_out_of_anglebrackets_or_original);
%EXPORT_TAGS=(all=>[@EXPORT,@EXPORT_OK]);

use strict; use warnings FATAL => 'uninitialized';

use Carp;

our $verbose=0;
our $raiseerrors=0;

sub pick_out_of_anglebrackets {
    my ($str)=@_;
    if (defined $str) {
	my @res= $str=~ /<([^>]*)>/g;
	if (wantarray){
	    @res
	} elsif (@res>1) {
	    my $msg= "multiple angle brackets found but only one expected";
	    if ($verbose) {
		warn $msg
	    }#naja, DBI like doppelwarn behaviour. is this liked?   [todo?]
	    if ($raiseerrors){
		croak $msg
	    } else {
		$res[0]
	    }
	} else {
	    $res[0]
	}
    } else {
	()
    }
}

sub pick_out_of_anglebrackets_or_original {
    my ($str)=@_;
    if (wantarray) {
	my @res= pick_out_of_anglebrackets $str;
	@res ? @res : ($str)
    } else {
	my $res= pick_out_of_anglebrackets $str;
	defined($res) ? $res : $str
    }
}

1
