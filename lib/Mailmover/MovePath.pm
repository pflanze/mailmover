#
# Copyright 2007-2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::MovePath

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Mailmover::MovePath;
@ISA="Exporter"; require Exporter;
@EXPORT=qw(MovePath);
@EXPORT_OK=qw();
%EXPORT_TAGS=(all=>[@EXPORT,@EXPORT_OK]);

use strict; use warnings FATAL => 'uninitialized';

{
    package Mailmover::MovePath::MovePath;
    use Chj::Path::Truncator::MD5;
    use FP::Predicates "is_array";
    use FP::Array "array_append";

    use FP::Struct [[*is_array, "items"]];

    sub untruncated_string {
	@_==1 or die "wrong number of arguments";
	my $s=shift;
	join "/",
	    map {
		local $_= /^\./ ? "dot.$_" : $_;
		s{/}{--}sg
	    } @{$s->items};
    }

    sub string {
	@_==2 or die "wrong number of arguments";
	my ($s, $targetbase)=@_;
	my $truncator= Chj::Path::Truncator::MD5->new($targetbase,3);
	# XX: not totally safe as it might truncate away a folder
	# boundary if parent folders are long!
	$truncator->trunc($s->untruncated_string)
    }

    sub string_split {
	@_==2 or die "wrong number of arguments";
	my ($s, $targetbase)=@_;
	# sounds stupid first to stringify then split again, but,
	# proper escaping is being done this way (only?) *and
	# especially truncation*.
	split /\//, $s->string ($targetbase)
    }

    sub append {
	@_==2 or die "wrong number of arguments";
	my ($a,$b)=@_;
	UNIVERSAL::isa($b, "MovePath") or die "wrong type of $b";
	$a->items_set(array_append ($a->items, $b->items))
    }

    _END_
}

sub MovePath {
    Mailmover::MovePath::MovePath->new([@_])
}

1
