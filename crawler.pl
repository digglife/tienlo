#!/usr/bin/perl

use strict;
use warnings;

use LWP::UserAgent;
use HTML::TreeBuilder;

use Data::Dumper;

my $site = "http://www.mp4ba.com";
my $ua = LWP::UserAgent->new;
$ua->agent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:41.0) Gecko/20100101 Firefox/41.0');
$response = $ua->get($site);
die "$site is not available now" unless $response->is_sucess;



