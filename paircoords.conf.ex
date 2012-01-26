# directory where the GPSr track files are located
gpx_dir             /home/user/files/gps-tracks

# image source directory:
src_dir             /home/user/files/input

# modify images in place, instead of copying to the dst_dir and then modifying
# this is assumed / implied if src_dir == dst_dir
in_place            0

# image destination directory:
dst_dir             /home/user/files/output

# display camera / lens information in image description
desc_camera         1

# display exposure settings in image description
desc_exposure       1

# display copyright notice in image description
desc_copyright      1

# copyright notice to put in the image description
copyright           Copyright © 2012 John User. All rights reserved.

# Camera GMT offset
camera_gmt          -3

# GPSr GMT offset
gps_gmt             0

# alter the DateTimeOriginal field in exif to reflect the 'accurate'
# time recorded by the GPSr and set the time to be proper for the timezone
# caution; this will make successive coord pairing attempts skew the time
time_warp           0

# Seconds out of sync:
# Snap a picture of the time on your GPSr:
# GPSr is ahead of camera (Camera: 10:13:30, GPSr 10:15:02) = 148
# GPSr is behind camera   (Camera: 10:15:02, GPSr 10:14:30) = -32
sync_seconds        18

# fudge factor; if there isn't a track location at the time of the photo
# look on either side of the photo's timestamp this many seconds for a match
error_margin        900

# maximum attempts to make an http request
retry               5

# number of seconds to sleep between new http requests
sleep               5

# use google geocoding api v3 to get location and nearby points of interest?
# 0: do not use this method
# 1: use this method
google              1

# use geonames.org to get nearest location?
# 0: do not use this method
# 1: use this method
geonames            1

# include camera make/model/lens information in tags?
# 0: do not use this method
# 1: use this method
camera_info         1
