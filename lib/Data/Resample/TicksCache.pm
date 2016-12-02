package Data::Resample::TicksCache;

use strict;
use warnings;

use 5.010;
use Moose;

use Scalar::Util qw( blessed );
use Sereal::Encoder;
use Sereal::Decoder;

extends 'Data::Resample';

my %prev_added_epoch;

=head1 SUBROUTINES/METHODS

=head2 tick_cache_insert

Also insert into resample cache if tick crosses 15s boundary.

=cut

sub tick_cache_insert {
    my ($self, $tick) = @_;

    $tick = $tick->as_hash if blessed($tick);

    my %to_store = %$tick;

    $to_store{count} = 1;    # These are all single ticks;
    my $key = $self->_make_key($to_store{symbol}, 0);

    # check for resample interval boundary.
    my $current_epoch = $tick->{epoch};
    my $prev_added_epoch = $prev_added_epoch{$to_store{symbol}} // $current_epoch;

    my $boundary = $current_epoch - ($current_epoch % $self->sampling_frequency->seconds);

    if ($current_epoch > $boundary and $prev_added_epoch <= $boundary) {
        if (
            my @ticks =
            map { $self->decoder->decode($_) }
            @{$self->redis_read->zrangebyscore($key, $boundary - $self->sampling_frequency->seconds - 1, $boundary)})
        {
            #do resampling
            my $agg = $self->_resample({
                symbol    => $to_store{symbol},
                end_epoch => $boundary,
                ticks     => \@ticks,
            });
        } elsif (
            my @agg = map {
                $self->decoder->decode($_)
            } reverse @{
                $self->redis_read->zrevrangebyscore(
                    $self->_make_key($to_store{symbol}, 1),
                    $boundary - $self->sampling_frequency->seconds,
                    0, 'LIMIT', 0, 1
                )})
        {
            my $tick = $agg[0];
            $tick->{agg_epoch} = $boundary;
            $tick->{count}     = 0;
            $self->_update($self->redis_write, $self->_make_key($to_store{symbol}, 1), $tick->{agg_epoch}, $self->encoder->encode($tick));
        }
    }

    $prev_added_epoch{$to_store{symbol}} = $current_epoch;

    return $self->_update($self->redis_write, $key, $tick->{epoch}, $self->encoder->encode(\%to_store));
}

=head2 tick_cache_get

Retrieve ticks from start epoch till end epoch .

=cut

sub tick_cache_get {
    my ($self, $args) = @_;
    my $symbol = $args->{symbol};
    my $start  = $args->{start_epoch} // 0;
    my $end    = $args->{end_epoch} // time;

    my @res = map { $self->decoder->decode($_) } @{$self->redis_read->zrangebyscore($self->_make_key($symbol, 0), $start, $end)};

    return \@res;
}

=head2 tick_cache_get_num_ticks

Retrieve num number of ticks from TicksCache.

=cut

sub tick_cache_get_num_ticks {

    my ($self, $args) = @_;

    my $symbol = $args->{symbol};
    my $end    = $args->{end_epoch} // time;
    my $num    = $args->{num} // 1;

    my @res;

    @res = map { $self->decoder->decode($_) } reverse @{$self->redis_read->zrevrangebyscore($self->_make_key($symbol, 0), $end, 0, 'LIMIT', 0, $num)};

    return \@res;
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;
