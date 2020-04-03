#!/bin/bash

file=$1
tmp=temp.mkv

# Check if the file is open
lsof | grep "${file}" >/dev/null 2>&1 ||

(
    # Check if the file is encoded with DTS or TrueHD or PGS
    probe=$(ffprobe -i "${file}" 2>&1) &&
    (
        echo "${probe}" | grep -Eq "Audio: (truehd|dts)" ||
        echo "${probe}" | grep -Eq "Subtitle: pgs"
    ) &&

    # Create a subtitle stream that exludes all PGS streams
    substream=$(echo "${probe}" | grep -E "Subtitle: pgs" | sed -E 's/.*(0:[0-9]+).*/-map -0:\1/' | tr '\n' ' ') &&
    echo "substream=${substream}" &&

    # Only convert DTS, TrueHD, and FLAC streams to EAC3
    acstream=$(echo "${probe}" | grep -E "Audio: (truehd|dts|flac)" | sed -E 's/.*0:([0-9]+).*/-c:\1 eac3 -ac:\1 6 -b:\1 1536k/' | tr '\n' ' ') &&
    echo "acstream=${acstream}" &&

    # Convert!
    ffmpeg -i "${file}" -map 0 ${substream} -c:a copy ${acstream} -c:v copy -c:s copy -f matroska temp.mkv &&

    # Replace the original mkv with the newly converted file
    mv "${temp}" "${file}"
)

