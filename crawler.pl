#!/usr/bin/perl

use strict;
use warnings;

use LWP::UserAgent;
use HTML::TreeBuilder;
use Data::Dumper;
use DBI;
use DBD::SQLite;
use Cwd qw/abs_path getcwd/;
use File::Spec;


my $site = "http://www.mp4ba.com";

my $ua = LWP::UserAgent->new;
$ua->agent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:41.0) Gecko/20100101 Firefox/41.0');
my $response = $ua->get($site);
die "$site is not available now" unless $response->is_success;

my $tree = HTML::TreeBuilder->new;
$tree->parse($response->decoded_content);
# $tree->parse_file('mp4ba.html');

my $table = $tree->find_by_attribute('id', 'data_list');
my @rows;
for my $tr ( $table->look_down('_tag', 'tr', sub { ! $_[0]->attr('id') }) ){
    my @cols;
    for my $td ( $tr->find_by_tag_name('td') ) {
        my $text = $td->as_text;
        if ( $td->attr('style') ) {
            my $a = $td->look_down('_tag', 'a');
            # my ( $hash ) = $a->attr('href') =~ /=(.*)$/;
            # push @cols, $hash;
            push @cols, $site . '/' . $a->attr('href');
            $text = $a->as_text;
        }
        $text =~ s/^\s+|\s+$//g;
        push @cols, $text;
    }
    print "@cols\n";
    push @rows, \@cols;
}

#print Dumper($rows[0]);

my $dir = abs_path(getcwd);
my $db = File::Spec->catfile($dir, 'scroll.db');
init_db($db) unless ( -e $db);


sub init_db {
    my $db_name = shift;

    my $dbh = DBI->connect("dbi:SQLite:dbname=$db", "", "");
    my @statements = ( q#
        CREATE TABLE sites (
            id INT PRIMARY_KEY,
            url TEXT,
            name TEXT
        );
        #,
        q#
        CREATE TABLE movies (
            id INT PRIMARY KEY,
            title TEXT,
            resolution TEXT,
            publish_date DATE,
            page_url TEXT,
            download_url TEXT,
            is_downloaded BOOLEAN,
            site_id INT
        );
        #
    );

    $dbh->do($_) for @statements;
}

