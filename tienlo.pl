#!/usr/bin/perl

use strict;
use warnings;

use LWP::UserAgent;
use URL::Encode qw/url_encode_utf8/;
use HTML::TreeBuilder;
use Data::Dumper;
use DBI;
use DBD::SQLite;
use Cwd qw/abs_path getcwd/;
use File::Spec;
use WWW::Xunlei;

binmode STDOUT, ":encoding(UTF-8)";
#$WWW::Xunlei::DEBUG = 1;

my $site        = "http://www.mp4ba.com";
my $dir         = abs_path(getcwd);
my $config_file = File::Spec->catfile( $dir, 'config.json' );
my $config      = get_config($config_file);

my $cookie = File::Spec->catfile( $dir, 'cookie.txt' );
my $xunlei = WWW::Xunlei->new(
    $config->{'xunlei'}->{'username'},
    $config->{'xunlei'}->{'password'},
    'cookie_file' => $cookie
);

my $downloader = $xunlei->list_downloaders()->[0];

my $db = File::Spec->catfile( $dir, 'scroll.db' );
my $dbh = get_dbh($db);
my @last_record
    = $dbh->selectrow_array( "SELECT page_title FROM movies "
        . " WHERE site = '"
        . $site
        . "' ORDER BY id DESC LIMIT 1" );

my $last_movie_title = $last_record[0];

my $ua = LWP::UserAgent->new;
$ua->agent( 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:41.0)'
        . ' Gecko/20100101 Firefox/41.0' );

$ua->timeout(30);
# save cf_clearance cookie for passing the security protection from
# Baidu YunJiaSu (Cloud Accelerator).
$ua->cookie_jar({ file => $cookie });
my $response = $ua->get($site);

if (   $response->code == 503
    && $response->decoded_content =~ /yjs-browser-verification/ )
{
    my $content = $response->decoded_content;
    my $yjs_check_url = get_baidu_yjs_check_url($site, $content);
    #print "$yjs_check_url\n";
    sleep 5;
    $response = $ua->get($yjs_check_url);
    die "Unable to cheat Baidu YJS Browser Verification : " . $response->code
        unless $response->is_success;
    $response = $ua->get($site);
}

die "$site is not available now : " . $response->code
    unless $response->is_success;

my $tree = HTML::TreeBuilder->new;

$tree->parse( $response->decoded_content );

# $tree->parse_file('mp4ba.html');

my $table = $tree->find_by_attribute( 'id', 'data_list' );
my @rows;
my %downloads;
my %ratings;

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
            . "WHERE page_url = '"
            . $cols[2]
            . "'" );
    my $is_downloaded = $status[0] ? 1 : 0;
    next if $is_downloaded;
    my ($hash) = $cols[2] =~ /=(.*)$/;
    my $download_url
        = "magnet:?xt=urn:btih:"
        . $hash
        . "&tr=http://bt.mp4ba.com:2710/announce";
    my ( $title, $quality )
        = $cols[3] =~ /(.*?)\..*((?:BD|HD|TS|TC)(?:\d+)P|DVDRIP|DVDSRC)/;

    unless ( $ratings{$title} ) {
        $ratings{$title} = get_douban_rating($title);
    }

    if (   $ratings{$title} >= $config->{'rating'}
        && $quality =~ /(BD|HD)$config->{'quality'}/i )
    {
        eval { $downloader->create_task($download_url); };

        # print "Virtual Download The Following One:\n"
        #     . "$title -> ( Rating: $ratings{$title} ; Quality: $quality )\n";
        if ($@) {
            next;
        }
        else {
            $is_downloaded = 1;
        }
        $downloads{$title} = $is_downloaded;

        #send_notification( $config->{'email'}, $title, $is_downloaded );
    }

    @cols = ( @cols[ 3, 2 ], $download_url, $is_downloaded, $site );
    push @rows, \@cols;
}

send_notification( $config->{'email'}, %downloads ) if ( %downloads );

my $sth
    = $dbh->prepare( "INSERT INTO movies "
        . "(page_title, page_url, download_url, is_downloaded, site) "
        . " VALUES (?, ?, ?, ?, ?)" );

for ( my $i = $#rows; $i >= 0; $i-- ) {
    $sth->execute( @{ $rows[$i] } );
}

$dbh->commit;
#$dbh->disconnect;

sub get_dbh {
    my $db = shift;

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db", "", "",
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
        . url_encode_utf8($title)
        . "&cat=1002";

    my $response = $ua->get($url);
    unless ( $response->is_success ) { print $response->code, "\n"; return; }
    my $search_result = $response->content;
    my $tree          = HTML::TreeBuilder->new;
    $tree->parse($search_result);
    my @ratings
        = $tree->look_down( '_tag' => 'span', 'class' => 'rating_nums' );

    #ratings is empty if no result found.
    return $ratings[0]->as_text if @ratings;
}

sub send_notification {
    my ( $email, %downloads ) = @_;
    my $indicator = ( grep { $_ == 0 } values %downloads ) ? "WARN" : "INFO";
    my $subject   = "[$indicator] [Tienlo] [Movies Added to Xunlei Remote]";
    my $body      = "Details:\n";
    for ( keys %downloads ) {
        $body .= $_ . " ...... " . ( $downloads{$_} ? "SUCC" : "FAIL" ) . "\n";
    }
    use Email::Stuffer;
    my $hostname = qx(hostname -f);
    chomp $hostname;
    Email::Stuffer->to($email)
        ->from("tienlo\@$hostname")
        ->subject($subject)
        ->text_body($body)
        ->send;
}

sub get_config {
    my $file = shift;

    use JSON qw/decode_json/;
    open( my $fh, '<', $file ) or die "Unable to open $file: $!";
    my $content = join( '', <$fh> );
    my $config = decode_json($content);
    return $config;
}

sub get_baidu_yjs_check_url {
    my $site_url = shift;
    my $content = shift;

    use JE;
    use URI;

    my $uri = URI->new($site_url);
    my $je = new JE;
    my $tree = HTML::TreeBuilder->new;
    $tree->parse($content);
    #$tree->parse_file('bdsecurity.html');
    my $js = $tree->look_down("_tag", "script");
    $js = $js->as_HTML;
    $js =~ s/^\<\/?script.*|^\s+\/\/.*//gm;
    my ($first_assignment, $object, $key) =
        $js =~ /var t,r,a,f, ((\w+)\=\{"(\w+)\"\:.*)/;
    my ($multiple_caculation) = $js =~ /;(.*;)a\.value/;

    print $first_assignment . $multiple_caculation . "\n";
    my $final_number = $je->eval($first_assignment . $multiple_caculation);
    my $answer = $final_number + length($uri->host);
    my $form = $tree->look_down("_tag", "form");
    my $jschk_url = $site_url . $form->attr('action');
    my @inputs = $form->look_down("_tag", "input");
    my %query;
    for my $input ( @inputs ) {
        $query{$input->attr("name")} = $input->attr("value");
    }
    $query{'jschl_answer'} = $answer;
    #print Dumper(\%query);
    my @params;
    for ( keys %query ) {
        push @params, join('=', $_, $query{$_});
    }
    $jschk_url .= '?' . join('&', @params);
    return $jschk_url;
}
