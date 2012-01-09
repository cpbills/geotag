# directory where the GPSr track files are located
gpx_dir             /home/user/files/gps-tracks

# image source directory:
src_dir             /home/user/files/images/untagged

# image destination directory:
dst_dir             /home/user/files/images/tagged

# Camera GMT offset
camera_gmt          -5

# GPSr GMT offset
gps_gmt             0

# Seconds out of sync:
# Snap a picture of the time on your GPSr:
# GPSr is ahead of camera (Camera: 10:13:30, GPSr 10:15:02) = 148
# GPSr is behind camera   (Camera: 10:15:02, GPSr 10:14:30) = -32
sync_seconds        14


# fudge factor; if there isn't a track location at the time of the photo
# look on either side of the photo's timestamp this many seconds for a match
error_margin        900

# maximum number of times to attempt to get geocoding data for a location
geocode_try         10

# use google geocoding api v3 to get location and nearby points of interest?
# 0: do not use this method
# 1: use this method
geocode_google      1

# use geonames.org to get nearest location?
# 0: do not use this method
# 1: use this method
geocode_geonames    1

# number of seconds to sleep before new http requests to geocoding services?
geocode_sleep       5

# include camera make/model/lens information in tags?
# 0: do not use this method
# 1: use this method
camera_info         1
