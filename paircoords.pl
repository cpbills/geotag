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
use Getopt::Std;
use LWP::UserAgent;
use HTTP::Request;
use XML::Simple;
use Date::Parse;
use File::Copy;

# set to non-zero to perform a flush after every write to STDOUT
# allows you to print "status message..." then after time, "OK\n"
$| = 42;
my $VERBOSE = 0;
my $config_name = "paircoords.conf";
my @config_path = ();
if ($^O =~ /mswin/i) {
    @config_path = ("./${config_name}");
} else {
    @config_path = ( "/etc/${config_name}",
                     "$ENV{HOME}/.${config_name}",
                     "./${config_name}" );
}
my $options_file = '';
foreach my $config (@config_path) {
    $options_file = $config if (-e "$config" && -r "$config");
}

# command line options are:
# -c <config file>
# -s <source image directory>
# -d <destination image directory>
# -t <tracks/gpx file directory>
# -v : verbose output
my %cli_opts = ();
Getopt::Std::getopts('c:s:d:t:v',\%cli_opts);

$options_file = $cli_opts{c} if ($cli_opts{c});
my $options = read_options("$options_file");

# over-ride config file definitions with what was provided on the command line
$$options{gpx_dir} = $cli_opts{t} if ($cli_opts{t});
$$options{src_dir} = $cli_opts{s} if ($cli_opts{s});
$$options{dst_dir} = $cli_opts{d} if ($cli_opts{d});
$VERBOSE = $cli_opts{v} if ($cli_opts{v});

if (verify_options($options)) {
    print STDERR "required options not provided\n";
    exit 1;
}

# initiate an empty hash reference for holding our coordinate data
my $coords = {};

# open the directory containing the gpx files, and loop through each file
if (opendir GPX_DIR,"$$options{gpx_dir}") {
    print "reading gpx files: " if ($VERBOSE);
    foreach my $file (grep { /\.gpx$/i } readdir GPX_DIR) {
        read_tracks("$$options{gpx_dir}/$file",$coords);
    }
    print "done\n" if ($VERBOSE);
    closedir GPX_DIR;
} else {
    print STDERR "unable to open GPX dir: $$options{gpx_dir}: $!\n";
    exit 1;
}

# calculate the total seconds difference
my $offset = (($$options{camera_gmt} - $$options{gps_gmt}) * 60 * 60) +
                $$options{sync_seconds};

if (opendir SRC_DIR,"$$options{src_dir}") {
    foreach my $image (grep { /\.jpe?g$/i } readdir SRC_DIR) {
        # create the Really Awesome Hash Ref
        my $img_data = {};
        $$img_data{image} = $image;

        my $exiftool = new Image::ExifTool;
        my $exif = $exiftool->ImageInfo("$$options{src_dir}/$image");
        # get the timestamp from the image and add offset to pair with gps
        if ($$exif{DateTimeOriginal}) {
            $$img_data{time} = str2time($$exif{DateTimeOriginal}) + $offset;
        }
        find_coords($img_data,$options,$coords);

        # perform our geocoding searches, if we have the data
        if ($$img_data{lat} && $$img_data{lon}) {
            if ($$options{geonames}) {
                query_geonames($img_data,$$options{retry},$$options{sleep});
            }
            if ($$options{google}) {
                query_google($img_data,$$options{retry},$$options{sleep});
            }
            sleep $$options{sleep};
        }

        # finally, process and update the EXIF header of the image
        update_exif($img_data,$image,$options);
    }
    closedir SRC_DIR;
} else {
    print STDERR "could not open source directory: $$options{src_dir}: $!\n";
    exit 1;
}

exit;

sub update_exif {
    my $img_data    = shift;
    my $image       = shift;
    my $options     = shift;

    my $filename = "$$options{src_dir}/$image";
    unless ($$options{in_place} || ($$options{src_dir} eq $$options{dst_dir})) {
        mkdir $$options{dst_dir} unless (-d $$options{dst_dir});
        copy("$$options{src_dir}/$image","$$options{dst_dir}/$image");
        $filename = "$$options{dst_dir}/$image";
    }

    # clean up / remove any old geo tag information
    foreach my $key (keys %{$$img_data{tags}}) {
        delete $$img_data{tags}{$key} if ($key =~ /^geo:/);
    }

    my $exiftool = new Image::ExifTool;
    my $exif = $exiftool->ImageInfo("$filename");

    # grab all possible existing tags, then insert into our hash
    my $tags = '';
    $tags = join(',',$tags,$$exif{Keywords}) if ($$exif{Keywords});
    $tags = join(',',$tags,$$exif{keywords}) if ($$exif{keywords});
    $tags = join(',',$tags,$$exif{Subject}) if ($$exif{Subject});
    $tags = join(',',$tags,$$exif{subject}) if ($$exif{subject});

    foreach my $tag (split(/,/,$tags)) {
        $tag =~ s/\s+$//;
        $tag =~ s/^\s+//;
        next if ($tag =~ /^$/);
        $$img_data{tags}{$tag} = 1;
    }

    # grab and format the camera and exposure details from exif
    if ($$exif{Lens}) {
        my $lens = $$exif{Lens};
        # 70.0-200.0 nooo! 70-200, yes!
        $lens =~ s/\.0//g;
        $lens =~ s/\ mm/mm/g;
        $$img_data{lens} = $lens;
    }
    if ($$exif{Model}) {
        my $model = lc($$exif{Model});
        $model =~ s/\b([a-z])/uc($1)/ge;
        $$img_data{model} = $model;
    }
    if ($$exif{ShutterSpeed}) {
        my $shutter = $$exif{ShutterSpeed} . 's';
        $$img_data{shutter} = $shutter;
    }
    if ($$exif{Aperture}) {
        my $aperture = $$exif{Aperture};
        $aperture =~ s/\.0$//;
        $$img_data{aperture} = "f/${aperture}";
    }
    if ($$exif{FocalLength}) {
        my $fl = $$exif{FocalLength};
        $fl =~ s/\.0\b//;
        $fl =~ s/\ mm/mm/;
        $$img_data{fl} = $fl;
    }
    $$img_data{iso} = "ISO $$exif{ISO}" if ($$exif{ISO});

    if ($$img_data{lat} && $$img_data{lon}) {
        my $lat = $$img_data{lat};
        my $lon = $$img_data{lon};
        my $ele = $$img_data{ele};

        my $latref = ($lat > 0)?"N":"S";
        my $lonref = ($lon > 0)?"E":"W";
        my $altref = ($ele < 0)?0:1;

        $$img_data{tags}{geotagged} = 1;
        $$img_data{tags}{"geo:lat=$lat"} = 1;
        $$img_data{tags}{"geo:lon=$lon"} = 1;

        $exiftool->SetNewValue('GPSAltitude',abs($ele),Type => 'ValueConv');
        $exiftool->SetNewValue('GPSAltitudeRef',$altref,Type => 'ValueConv');
        $exiftool->SetNewValue('GPSLongitude',abs($lon),Type => 'ValueConv');
        $exiftool->SetNewValue('GPSLongitudeRef',$lonref,Type => 'ValueConv');
        $exiftool->SetNewValue('GPSLatitude',abs($lat),Type => 'ValueConv');
        $exiftool->SetNewValue('GPSLatitudeRef',$latref,Type => 'ValueConv');
    }
    if ($$options{camera_info}) {
        $$img_data{tags}{$$img_data{model}} = 1 if ($$img_data{model});
        $$img_data{tags}{$$img_data{lens}} = 1 if ($$img_data{lens});
    }
    # include location data in tags
    my @items = qw( country county state locality route postal_code
                    administrative_area_level_1 administrative_area_level_3 );
    foreach my $item (@items) {
        if ($$img_data{google}{$item}) {
            $$img_data{tags}{$$img_data{google}{$item}} = 1;
        }
        if ($$img_data{geonames}{$item}) {
            $$img_data{tags}{$$img_data{geonames}{$item}} = 1;
        }
    }
    foreach my $tag (keys %{$$img_data{tags}}) {
        # remove any duplicate lowercased tags
        if (($$img_data{tags}{lc($tag)}) && $tag ne lc($tag)) {
            delete $$img_data{tags}{lc($tag)};
        }
    }
    # 'wipe out' old keywords... not sure this is needed
    $exiftool->SetNewValue('Keywords',undef);
    # set our keywords... we have to loop through these instead of doing
    # a 'join' and making one large string, because this function seems to
    # have a string length limit.
    foreach my $tag (keys %{$$img_data{tags}}) {
        $exiftool->SetNewValue('Keywords',"$tag");
    }
    # start building the image description:
    my $header = '';
    # get wild and crazy and assume we have more data from geonames, if we
    # have the distance... may need to re-visit and make this more 'strict'
    if ($$img_data{geonames}{distance}) {
        my $geonames = $$img_data{geonames};
        my $distance = sprintf("%02.2gkm",$$geonames{distance});
        $header .= "$distance from $$geonames{locality} in ";
        $header .= "$$geonames{county}, $$geonames{state}\n";
    }
    if ($$img_data{google}{address}) {
        $header .= "near $$img_data{google}{address}\n";
    }
    my $footer = '';
    if ($$options{desc_camera}) {
        $footer .= "$$img_data{model}" if ($$img_data{model});
        $footer .= " + " if ($$img_data{model} && $$img_data{lens});
        $footer .= "$$img_data{lens}" if ($$img_data{model});
        if ($$img_data{lens} && $$img_data{fl}
                && ($$img_data{fl} ne (split(/\ /,$$img_data{lens}))[0])) {
            $footer .= " @ $$img_data{fl}";
        }
    }
    if ($$options{desc_exposure}) {
        my @details = ();
        push @details,$$img_data{shutter} if ($$img_data{shutter});
        push @details,$$img_data{aperture} if ($$img_data{aperture});
        push @details,$$img_data{iso} if ($$img_data{iso});
        if (@details) {
            $footer .= ' - ' if ($footer ne '');
            $footer .= join(', ',@details);
        }
    }
    $footer .= "\n" if ($footer ne '');
    if ($$options{desc_copyright} && $$options{copyright}) {
        $$options{copyright} =~ s/\\n/\n/g;
        $footer .= "$$options{copyright}";
    }
    if ($header ne '' || $footer ne '') {
        $exiftool->SetNewValue('Description',"$header\n\n$footer");
    }

    $exiftool->WriteInfo("$filename");
}

sub query_geonames {
    # example geonames.org query:
    # http://ws.geonames.org/findNearbyPlaceName?lat=41.1365&lng=-83.6601&style=FULL
    my $img_data    = shift;
    my $retry       = shift;
    my $sleep       = shift;

    my $base = 'http://ws.geonames.org/findNearbyPlaceName';
    my $url  = "$base?lat=$$img_data{lat}&lng=$$img_data{lon}";
       $url .= '&radius=100&maxRows=1&style=FULL';

    my $success = 0;
    for (1 .. $retry) {
        last if ($success);
        print 'geonames: ' if ($VERBOSE);
        my $content = http_get("$url");
        if ($content) {
            my $xml = new XML::Simple (ForceArray => 1);
            my $infos = $xml->XMLin($content);
               $infos = $$infos{geoname}[0];
            $$img_data{geonames}{distance} = $$infos{distance}[0];
            $$img_data{geonames}{locality} = $$infos{name}[0];
            $$img_data{geonames}{state} = $$infos{adminName1}[0];
            $$img_data{geonames}{county} = $$infos{adminName2}[0];
            $$img_data{geonames}{country} = $$infos{countryName}[0];
            $$img_data{timezone} = $$infos{timezone}[0]{content};
            $success = 1;
        }
        if ($VERBOSE) {
            if ($success) {
                print "success\n";
            } else {
                print "fail\n";
            }
        }
        sleep $sleep unless ($success);
    }
}

sub find_coords {
    my $img_data    = shift;
    my $options     = shift;
    my $coords      = shift;

    print "matching: $$options{src_dir}/$$img_data{image}: " if ($VERBOSE);
    unless ($$img_data{time}) {
        print "not found: no image time\n" if ($VERBOSE);
        return;
    }
    for my $fuzzy (0 .. $$options{error_margin}) {
        # if someone knows of a more 'efficient' way to express this flip-flop
        # please let me know... i hate redundant code... although, i imagine
        # there is a lot of it in this script already...
        my $time = $$img_data{time}-$fuzzy;
        if ($$coords{$time}) {
            my $location = $$coords{$time};
            $$img_data{lat} = $$location{lat};
            $$img_data{lon} = $$location{lon};
            $$img_data{ele} = $$location{ele};
            print "found: -${fuzzy}s\n" if ($VERBOSE);
            return;
        }
        $time = $$img_data{time}+$fuzzy;
        if ($$coords{$time}) {
            my $location = $$coords{$time};
            $$img_data{lat} = $$location{lat};
            $$img_data{lon} = $$location{lon};
            $$img_data{ele} = $$location{ele};
            print "found: +${fuzzy}s\n" if ($VERBOSE);
            return;
        }
    }
    print "not found\n" if ($VERBOSE);
    return;
}

sub query_google {
    # example query:
    # http://maps.googleapis.com/maps/api/geocode/xml?latlng=34.520994,-117.308356&sensor=false
    my $img_data    = shift;
    my $retry       = shift;
    my $sleep       = shift;

    my @pois = qw(establishment point_of_interest park natural_feature);
    my $base = 'http://maps.googleapis.com/maps/api/geocode/xml';
    my $url = "$base?latlng=$$img_data{lat},$$img_data{lon}&sensor=false";

    my $success = 0;
    for (1 .. $retry) {
        last if ($success);
        print 'google: ' if ($VERBOSE);
        my $content = http_get("$url");
        if ($content) {
            my $xml = new XML::Simple (ForceArray => 1);
            my $infos = $xml->XMLin($content);
               $infos = $$infos{result}[0];
            $$img_data{google}{address} = $$infos{formatted_address}[0];
            foreach my $piece (@{$$infos{address_component}}) {
                my $name = $$piece{long_name}[0];
                my $type = $$piece{type}[0];
                my $poi = 0;
                foreach my $poi_type (@pois) {
                    if ($type =~ /$poi_type/i) {
                        $$img_data{tags}{$name} = 1;
                    }
                }
                $$img_data{google}{$type} = $name;
            }
            $success = 1;
        }
        if ($VERBOSE) {
            if ($success) {
                print "success\n";
            } else {
                print "fail\n";
            }
        }
        sleep $sleep unless ($success);
    }
}

sub http_get {
    my $url     = shift;

    my $browser = new LWP::UserAgent;
       $browser->timeout(10);
       $browser->requests_redirectable(['POST','GET','HEAD']);
    my $request = new HTTP::Request('GET',"$url");
    my $response = $browser->request($request);

    if ($response->is_success) {
        return $response->content;
    }
    return undef;
}

sub read_tracks {
    # slurp each file in with XML::Simple and then process the track segments
    # to populate a hash for future lookup against photo timestamps.
    my $file        =   shift;
    my $coord_hash  =   shift;

    # the ForceArray bit is needed to ensure that we can deal with
    # GPX files that only have one track segment, and XML::Simple
    # is tempted to just collapse it...
    my $xml = new XML::Simple (ForceArray => 1);
    my $tracks = $xml->XMLin($file);
    my $segments = $$tracks{trk};
    foreach my $segment (@$segments) {
        my $points = $$segment{trkseg}[0]{trkpt};
        foreach my $point (@$points) {
            if (defined $$point{time}[0]) {
                my $time = str2time($$point{time}[0]);
                $$coord_hash{$time}{lat} = $$point{lat};
                $$coord_hash{$time}{lon} = $$point{lon};
                $$coord_hash{$time}{ele} = $$point{ele}[0];
            }
        }
    }
}

sub verify_options {
    # really basic check to make sure we have directories specified and
    # that they can be used for what we need them for. gives us a spot to
    # check for something more complex if needed in the future.
    my $option_hash = shift;
    my $fail = 0;

    foreach my $dir ('src_dir', 'gpx_dir') {
        if ($$option_hash{$dir}) {
            my $directory = $$option_hash{$dir};
            if (! -d "$directory") {
                print STDERR "$dir: \'$directory\' is not a directory\n";
                $fail = 1;
            } elsif (! -r "$directory") {
                print STDERR "$dir: \'$directory\' is not readable\n";
                $fail = 1;
            }
        } else {
            print STDERR "$dir: not defined\n";
            $fail = 1;
        }
    }
    return $fail;
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
