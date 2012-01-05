#!/usr/bin/perl

use POSIX 'mktime';

use strict;
use warnings;

use Image::ExifTool 'ImageInfo';
use Getopt::Long;
use LWP::UserAgent;

$| = 42;

# GMT offset, Eastern = -5, etc.
# Check your camera and your gps, to be sure,
# you may have forgotten about DST, or something
# else might be wonky.
my $GMT     = -4;

# Number of minutes your camera is off from the GPSr.
# if your camera reads 5:04 and your GPSr reads 5:00
# enter '4', if your camera reads 4:56 enter '-4'
my $MERR    = 3;

my $MAXTS   = 900;              # Maximum number of seconds to match timestamps
my $LOC     = 1;                # Perform HTTP request to get location name
my $MAXTRY  = 10;               # Attempts to get location name
my $NICE    = 10;               # Number of seconds to sleep between requests
my $FTMETER = 3.2808399;        # number of feet in a meter

if (scalar(@ARGV) < 4) {
    # minimum arguments are 'paircoords.pl -g track.gpx -i image.jpg'
    help();
}
foreach my $arg (@ARGV) {
    # catch any attempt to get help
    help() if ($arg =~ /-help/i);
}

my @GPXOPT = ();
my @IMGOPT = ();

my $result = GetOptions(
            'gpx=s'     =>  \@GPXOPT,
            'img=s'     =>  \@IMGOPT,
            'minute=i'  =>  \$MERR,
            'sec=i'     =>  \$MAXTS,
            'hours=i'   =>  \$GMT
) or help();

@GPXOPT = split(/,/,join(',',@GPXOPT));
@IMGOPT = split(/,/,join(',',@IMGOPT));

my @TRACKS = ();
my @IMAGES = ();
my $FAIL = 0;

foreach my $GPX (@GPXOPT) {
    if (-d $GPX) {
        $GPX =~ s/\/$//;
        opendir DIR,$GPX;
        my @GPXDIR = grep { /\.gpx$/i } readdir DIR;
        closedir DIR;
        foreach my $gpx (@GPXDIR) {
            push(@TRACKS,"$GPX/$gpx");
        }
    } elsif (-e $GPX) {
        push(@TRACKS,$GPX);
    } else {
        print "$GPX not found\n";
        $FAIL = 1;
    }
}

foreach my $IMG (@IMGOPT) {
    if (-d $IMG) {
        $IMG =~ s/\/$//;
        opendir DIR,$IMG;
        my @IMGDIR = grep { /\.jpe?g$/i } readdir DIR;
        closedir DIR;
        foreach my $img (@IMGDIR) {
            push(@IMAGES,"$IMG/$img");
        }
    } elsif (-e $IMG) {
        push(@IMAGES,$IMG);
    } else {
        print "$IMG not found\n";
        $FAIL = 1;
    }
}
help() if ($FAIL);

my $points = readingpx(@TRACKS);

foreach my $image (@IMAGES) {
    my $ts = imagets($image);
    my ($lat,$lon,$ele,$offset) = correlate($points,$ts);
    my ($name1,$name2,$name3,$dist,$headline) = ('','','','','');
    my @tags = ();

    if ($LOC and ($lat and $lon)) {
        my $location = getplace($lat,$lon);
        if ($location) {
            ($name1) = $location =~ /<name>(.*?)</i;
            ($name2) = $location =~ /<adminname1>(.*?)</i;
            ($name3) = $location =~ /<adminname2>(.*?)</i;
            ($dist)  = $location =~ /<distance>(.*?)</i;
        }
        sleep $NICE;
        
    }
    if (($dist ne '') and ($name1 ne '') and ($name2 ne '')) {
        $headline = sprintf("%.2fkm from %s, %s",$dist,$name1,$name2);
    } elsif ($lat and $lon) {
        $headline = "Taken at $lat, $lon";
    } else {
        $headline = "No reliable GPS data";
    }
    print "$image $headline\n";
    push @tags,$name1 if ($name1 ne '');
    push @tags,$name2 if ($name2 ne '');
    push @tags,$name3 if ($name3 ne '');
    push @tags,("geotagged","geo:lat=$lat","geo:lon=$lon") if ($lat and $lon);

    setexif($image,$lat,$lon,$ele,$headline,\@tags);
}

exit;

sub help {
    print "HELP CALLED!\n";
    exit;
}

sub getplace {
# example geonames.org query:
# http://ws.geonames.org/findNearbyPlaceName?lat=41.1365&lng=-83.6601&style=FULL
    my $lat = shift;
    my $lon = shift;

    my $base    = 'http://ws.geonames.org/findNearbyPlaceName';
    my $place   = "$base?lat=$lat&lng=$lon&radius=100&maxRows=1&style=FULL";
    my $ua = LWP::UserAgent->new(timeout => 30);
    print "Aquiring placename for $lat, $lon";
    for my $i (0 .. $MAXTRY) {
        my $req = HTTP::Request->new(GET => $place);
        my $res = $ua->request($req);
        if ($res->is_success) {
            print " success!\n";
            return $res->content;
        }
        print ".";
        sleep $NICE;
    }
    print " failure!\n";
    return 0;
}

sub setexif {
# EXIF tags we're going to set with this:
# Headline - XKm from Place
# GPSAltitude
# GPSAltitudeRef 0/1 0 = above sea level, 1 = below sea level
# GPSLatitude 
# GPSLatitudeRef N/S
# GPSLongitude
# GPSLongitudeRef E/W
# GPSPosition 'lat,lon'
    my ($image,$lat,$lon,$ele,$hl,$tags) = @_;

    my $latref = ($lat > 0)?"N":"S";
    my $lonref = ($lon > 0)?"E":"W";
    my $altref = ($ele < 0)?0:1;

    my $exif = new Image::ExifTool;
    my $info = $exif->ImageInfo($image);

    my @keywords = ();
    push @keywords,split(/,/,$$info{Keywords}) if ($$info{Keywords});
    push @keywords,split(/,/,$$info{keywords}) if ($$info{keywords});

    if ($$info{Lens}) {
        my $lens = $$info{Lens};
        # 70.0-200.0 lens? nooo! 70-200, yes!
        $lens = s/\\.0//g;
        push @keywords,$lens;
    }

    push @keywords,$$info{Model} if ($$info{Model});
    
    # Adobe Lightroom likes to put keywords in 'subject' as well.
    push @keywords,split(/,/,$$info{subject}) if ($$info{subject});
    push @keywords,split(/,/,$$info{Subject}) if ($$info{Subject});
    
    my %dupe = ();

    # remove any previous 'geo:' tags from the list
    foreach my $keyword (@keywords) {
        $keyword =~ s/^\s*//;
        $keyword =~ s/\s*$//;
        $dupe{lc($keyword)} = 1 unless ($keyword =~ /geo:/);
    }

    # add new tags to the list
    foreach my $keyword (@$tags) {
        $keyword =~ s/^\s*//;
        $keyword =~ s/\s*$//;
        $dupe{lc($keyword)} = 1;
    }
    @keywords = keys %dupe;

    # wipe out 'Keywords' to start fresh.
    $exif->SetNewValue('Keywords',undef);

    # append each keyword, separately
    foreach my $keyword (@keywords) {
        $exif->SetNewValue('Keywords',$keyword);
    }

    $exif->SetNewValue('Headline',$hl);
    $exif->SetNewValue('GPSAltitude',abs($ele), Type => 'ValueConv');
    $exif->SetNewValue('GPSAltitudeRef',$altref,Type => 'ValueConv');
    $exif->SetNewValue('GPSLongitude',abs($lon), Type =>'ValueConv');
    $exif->SetNewValue('GPSLongitudeRef',$lonref,Type =>'ValueConv');
    $exif->SetNewValue('GPSLatitude',abs($lat), Type => 'ValueConv');
    $exif->SetNewValue('GPSLatitudeRef',$latref,Type => 'ValueConv');
    $exif->WriteInfo($image);
}

sub correlate {
    my $points = shift;
    my $timestamp = shift;

    if (defined($$points{$timestamp}{lon})) {
        return  $$points{$timestamp}{lat},
                $$points{$timestamp}{lon},
                $$points{$timestamp}{ele},
                0;
    } else {
        for my $i (1 .. $MAXTS) {
            if (defined($$points{$timestamp-$i}{lon})) {
                return  $$points{$timestamp-$i}{lat},
                        $$points{$timestamp-$i}{lon},
                        $$points{$timestamp-$i}{ele},
                        $i;

            }
            if (defined($$points{$timestamp+$i}{lon})) {
                return  $$points{$timestamp+$i}{lat},
                        $$points{$timestamp+$i}{lon},
                        $$points{$timestamp+$i}{ele},
                        $i;
            }
        }
        return 0,0,0,0;
    }
}

sub imagets {
# reads exif time from image, returns adjusted unix timestamp
# The format I have in my photos is specified below, and for this
# to work with other cameras, work may need to be done here.
# DateTimeOriginal = 'YYYY:MM:DD HH:MM:SS.SS-XX:XX'
    my $image = shift;
    
    my $exif = ImageInfo($image);
    $$exif{DateTimeOriginal} =~
        /([0-9]+):([0-9]+):([0-9]+)\s+([0-9]+):([0-9]+):([0-9]+)/;
    my $stamp = mktime($6,($5-$MERR),($4-$GMT),$3,$2-1,$1-1900,0,0,0);
    return $stamp;
}


sub readingpx {
    my @files = @_;
    
    my %points = ();
    foreach my $file (@files) {
        open GPX,$file;
        my @lines = <GPX>;
        close GPX;
        chomp(@lines);
        my $content = join('',@lines);
        my @points = $content =~ /<trkpt(.*?)<\/trkpt>/sig;
        foreach my $point (@points) {
            # GPSr should be using GMT for a timezone, code
            # may need to be modified to allow for a non-GMT GPSr

            my ($time) = $point =~ /<time>(.*?)<\/time>/i;

            # this regex may fail if your GPSr doesn't record time as:
            # 'YYYY-MM-DDTHH:MM:SSZ', where T and Z are literal
            $time =~ /([0-9]+)-([0-9]+)-([0-9]+).([0-9]+):([0-9]+):([0-9]+)/;
                    

            # convert human readable time to unix timestamp,
            # this will make finding the closest match much easier.
            my $stamp = mktime($6,$5,$4,$3,$2-1,$1-1900,0,0,0);

            ($points{$stamp}{lat}) = $point =~ /lat=['"](.*?)['"]/i;
            ($points{$stamp}{lon}) = $point =~ /lon=['"](.*?)['"]/i;
            ($points{$stamp}{ele}) = $point =~ /<ele>(.*?)<\/ele>/i;
        }

    }
    # return a hash reference of all the points, keyed by unix timestamp
    return \%points;
}
