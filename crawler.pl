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
use WWW::Xunlei;

my $site   = "http://www.mp4ba.com";
my $config = get_config('config.json');

my $xunlei = WWW::Xunlei->new( $config->{'xunlei'}->{'username'},
    $config->{'xunlei'}->{'password'} );

my $downloader = $xunlei->list_downloaders()->[0];

my $dbh = get_dbh('scroll.db');
my @last_record
    = $dbh->selectrow_array( "SELECT page_title FROM movies "
        . " WHERE site = '"
        . $site
        . "' ORDER BY id DESC LIMIT 1" );

my $last_movie_title = $last_record[0];

my $ua = LWP::UserAgent->new;
$ua->agent( 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:41.0)'
        . ' Gecko/20100101 Firefox/41.0' );

$ua->timeout(180);
my $response = $ua->get($site);
die "$site is not available now : " . $response->code
    unless $response->is_success;

my $tree = HTML::TreeBuilder->new;

$tree->parse( $response->content );

# $tree->parse_file('mp4ba.html');

my $table = $tree->find_by_attribute( 'id', 'data_list' );
my @rows;

for my $tr ( $table->look_down( '_tag', 'tr', sub { !$_[0]->attr('id') } ) ) {
    my @cols;

   # Acutally only the third td is valuable for me, but still loop all the tds
   # for future use.
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

    print "Processing " . $cols[3] . "\n";
    last if $last_movie_title && $last_movie_title eq $cols[3];
    my @status
        = $dbh->selectrow_array( "SELECT is_downloaded from movies "
            . "WHERE page_title = '"
            . $cols[3]
            . "'" );
    my $is_downloaded = $status[0] ? 1 : 0;
    next if $is_downloaded;
    my ($hash) = $cols[2] =~ /=(.*)$/;
    my $download_url
        = "magnet:?xt=urn:btih:"
        . $hash
        . "&tr=http://bt.mp4ba.com:2710/announce";
    my ( $title, $quality )
        = $cols[3] =~ /(.*?)\..*((?:BD|HD|TS|TC)(?:720|1080)P|DVDRIP|DVDSRC)/;
    print "Real Title => $title\n";
    my $rating = get_douban_rating($title);
    print "RATING => $rating\n";

    if (   $rating > $config{'rating'}
        && $quality =~ /(BD|HD)$config{'quality'}/i )
    {
        eval { $downloader->create_task($download_url); };

        # print "Virtual Download The Following One:\n"
        #     . "$title -> ( Rating: $rating ; Quality: $quality )\n";
        if ($@) {
            next;
        }
        else {
            $is_downloaded = 1;
        }
    }

    @cols = ( @cols[ 3, 2 ], $download_url, $is_downloaded, $site );
    push @rows, \@cols;
}

#print Dumper($rows[0]);

my $sth
    = $dbh->prepare( "INSERT INTO movies "
        . "(page_title, page_url, download_url, is_downloaded, site) "
        . " VALUES (?, ?, ?, ?, ?)" );

for ( my $i = $#rows; $i >= 0; $i-- ) {
    $sth->execute( @{ $rows[$i] } );
}

$sth->finish;

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

    # my $ua = LWP::UserAgent->new;
    # $ua->agent( 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:41.0)'
    #         . ' Gecko/20100101 Firefox/41.0' );
    my $response = $ua->get($url);
    return unless $response->is_success;
    my $search_result = $response->content;
    my $tree          = HTML::TreeBuilder->new;
    $tree->parse($search_result);
    my @ratings
        = $tree->look_down( '_tag' => 'span', 'class' => 'rating_nums' );
    return $ratings[0]->as_text;
}

sub send_notification {
    my ( $email, $message ) = @_;
}

sub get_config {
    my $file_name = shift;

    my $dir = abs_path(getcwd);
    my $file = File::Spec->catfile( $dir, $file_name );

    use JSON qw/decode_json/;
    open( my $fh, '<', $file ) or die "Unable to open $file: $!";
    my $content = join( '', <$fh> );
    my $config = decode_json($content);
    return $config;
}
