#!/usr/bin/perl

use strict;
use warnings;

use LWP::UserAgent;
use HTML::TreeBuilder;

use Data::Dumper::AutoEncode;

my $site = "http://www.mp4ba.com";

my $ua = LWP::UserAgent->new;
$ua->agent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:41.0) Gecko/20100101 Firefox/41.0');
my $response = $ua->get($site);
die "$site is not available now" unless $response->is_success;

my $tree = HTML::TreeBuilder->new;
$tree->parse($response->decoded_content);
#$tree->parse_file('mp4ba.html');

my $table = $tree->find_by_attribute('id', 'data_list');
my @rows;
for my $tr ( $table->look_down('_tag', 'tr', sub { ! $_[0]->attr('id') }) ){
    my @cols;
    for my $td ( $tr->find_by_tag_name('td') ) {
        my $text = $td->as_text;
        if ( $td->attr('style') ) {
            my $a = $td->look_down('_tag', 'a');
            my ( $hash ) = $a->attr('href') =~ /=(.*)$/;
            push @cols, $hash;
            $text = $a->as_text;
        }
        $text =~ s/^\s+|\s+$//g;
        push @cols, $text;
    }
    print "@cols\n";
    push @rows, \@cols;
}

#print Dumper($rows[0]);
