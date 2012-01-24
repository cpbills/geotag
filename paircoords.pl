#!/usr/bin/perl
# paircoords.pl - correlates gps track data and photos using timestamps.
# Copyright (C) 2007 Christopher P. Bills (cpbills@fauxtographer.net)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
use strict;
use warnings;

use Image::ExifTool 'ImageInfo';
use POSIX 'mktime';
use Getopt::Long;
use LWP::UserAgent;
use XML::Simple;

# set to non-zero to perform a flush after every write to STDOUT
# allows you to print "status message..." then after time, "OK\n"
$| = 42;

my %cli_opts = ();
Getopt::Std::getopts('c:s:d:t:',\%cli_opts);

my $options_file = $cli_opts{c} || "${HOME}/.paircoords.conf";

my $options = read_options("$options_file");

# over-ride config file definitions with what was provided on the command line
$$options{'gpx_dir'} = $cli_opts{t} if ($cli_opts{t});
$$options{'src_dir'} = $cli_opts{s} if ($cli_opts{s});
$$optiosn{'dst_dir'} = $cli_opts{d} if ($cli_opts{d});

unless (verify_options($options)) {
    print STDERR "required options not provided\n";
    exit 1;
}

# Total seconds offset:
# ADDING this value to the timestamp of a photo will give us the relative
# time for the GPSr position at the time the photo was taken.
my $OFFSET = ($GPS_GMT - $CAM_GMT) * 3600 + $SYNC;
print $OFFSET,"\n"; exit;


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
            'hours=i'   =>  \$OFFSET
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
        sleep $DELAY;
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
        sleep $DELAY;
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

sub read_options {
    my $config  = shift;

    my %options = ();

    if (open FILE,'<',$config) {
        while (<FILE>) {
            my $line = $_;
            $line =~ s/^\s+//;
            $line =~ s/\s+$//;
            next if ($line =~ /^#/);
            next if ($line =~ /^$/);

            my ($option,$value) = split(/\s+/,$line,2);
            if ($options{$option}) {
                print "WARN: option $option previously defined in config\n";
            }
            $options{$option} = $value;
        }
        close FILE;
    } else {
        print STDERR "could not open file: $config: $!\n";
    }
    return \%options;
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
    my $stamp = mktime($6,($5-$MERR),($4-$OFFSET),$3,$2-1,$1-1900,0,0,0);
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
