#!/usr/bin/perl

use strict;
use warnings;

use utf8;
use LWP::UserAgent;
use URL::Encode qw/url_encode/;
use HTML::TreeBuilder;
use Data::Dumper;
use DBI;
use DBD::SQLite;
use Cwd qw/abs_path getcwd/;
use File::Spec;

#use WWW::Xunlei;

my $site = "http://www.mp4ba.com";

my $ua = LWP::UserAgent->new;
$ua->agent( 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:41.0)'
        . ' Gecko/20100101 Firefox/41.0' );
my $response = $ua->get($site);
die "$site is not available now" unless $response->is_success;

my $tree = HTML::TreeBuilder->new;
$tree->parse( $response->decoded_content );

#$tree->parse_file('mp4ba.html');

my $table = $tree->find_by_attribute( 'id', 'data_list' );
my @rows;

for my $tr ( $table->look_down( '_tag', 'tr', sub { !$_[0]->attr('id') } ) ) {
    my @cols;
    for my $td ( $tr->find_by_tag_name('td') ) {
        my $text = $td->as_text;
        if ( $td->attr('style') ) {
            my $a = $td->look_down( '_tag', 'a' );

            # my ( $hash ) = $a->attr('href') =~ /=(.*)$/;
            # push @cols, $hash;
            push @cols, $site . '/' . $a->attr('href');
            $text = $a->as_text;
        }
        $text =~ s/^\s+|\s+$//g;
        push @cols, $text;
    }

    #print "@cols\n";
    #FIFO
    unshift @rows, \@cols;
}

#print Dumper($rows[0]);

my $dbh = get_dbh('scroll.db');
my @last_record
    = $dbh->selectrow_array( "SELECT page_url FROM movies "
        . " WHERE site = '"
        . $site
        . "' ORDER BY id LIMIT 1" );

my $last_movie_title = $last_record[0];

my $sth
    = $dbh->prepare( "INSERT INTO movies "
        . "(page_title, page_url, download_url, is_downloaded, site) "
        . " VALUES (?, ?, ?, ?, ?)" );

for my $item (@rows) {
    print "Processing " . $item->[3] . "\n";
    last if $last_movie_title && $last_movie_title eq $item->[2];
    my ($hash) = $item->[2] =~ /=(.*)$/;
    my $download_url
        = "magnet:?xt=urn:btih:"
        . $hash
        . "&tr=http://bt.mp4ba.com:2710/announce";
    my ( $title, $quality )
        = $item->[3]
        =~ /(.*?)\..*((?:BD|HD|TS|TC)(?:720|1080)P|DVDRIP|DVDSRC)/;
    print "Real Title => $title \n";
    my $rating        = get_douban_rating($title);
    my $is_downloaded = 0;

    if ( $rating > 7 && $quality =~ /(BD|HD)720p/i ) {

        #$status = $downloader->create_task($download_url);
        print "This one should be DOWNLOADED:\n   "
            . "$title -> ( Rating: $rating ; Quality: $quality )\n";
        
        if ($@) {
            next;
        }
        else {
            $is_downloaded = 1;
        }
    }
    $sth->execute(
        ( $item->[3], $item->[2], $download_url, $is_downloaded, $site ) );
}

$dbh->finish;

sub get_dbh {
    my $db_name = shift;

    my $dir = abs_path(getcwd);
    my $db = File::Spec->catfile( $dir, $db_name );

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db",
        { RaiseError => 1, AutoCommit => 0 } );

    my $create = q#
        CREATE TABLE movies (
            id INTEGER PRIMARY KEY,
            page_title TEXT,
            page_url TEXT,
            download_url TEXT,
            is_downloaded BOOLEAN,
            site text
        );
    #;

    unless ( grep { '"main"."movies"' eq $_ } $dbh->tables ) {
        print "DB not exist. Create one.\n";
        $dbh->do($create);
    }
    return $dbh;
}

sub get_douban_rating {
    my $title = shift;

    my $url
        = "https://movie.douban.com/subject_search?search_text="
        . url_encode($title)
        . "&cat=1002";
    my $ua = LWP::UserAgent->new;
    $ua->agent( 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:41.0)'
            . ' Gecko/20100101 Firefox/41.0' );
    my $response = $ua->get($url);
    return unless $response->is_success;
    my $search_result = $response->content;
    my $tree          = HTML::TreeBuilder->new;
    $tree->parse($search_result);
    my @ratings
        = $tree->look_down( '_tag' => 'span', 'class' => 'rating_nums' );
    return $ratings[0]->as_text;
}

