#!/usr/bin/env bash

set -euo pipefail

# need two arguments:
# 1. target
# 2. build
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <target_folder> <build_version>"
    exit 1
fi
TARGET=$1
BUILD=$2

# LOCATIONS:
DOWNLOAD_LOCATION=https://kircherlab.bihealth.org/download/CADD



# supported builds: GRCh37, GRCh38
if [ "$BUILD" != "GRCh37" ] && [ "$BUILD" != "GRCh38" ]; then
    echo "Usage: $0 <target_folder> <build_version>"
    echo "Supported builds: GRCh37, GRCh38"
    exit 1
fi

## ANNOTATIONS
echo "1. ANNOTATIONS"
mkdir -p $TARGET/annotations/
cd $TARGET/annotations/
URL="$DOWNLOAD_LOCATION/v1.7/$BUILD/${BUILD}_v1.7.tar.gz"
echo "  - download"
axel -a "$URL"
axel -a "$URL.md5"
echo "  - md5sum"
md5sum -c ${BUILD}_v1.7.tar.gz.md5
echo "  - untar"
tar -xzvf ${BUILD}_v1.7.tar.gz
rm ${BUILD}_v1.7.tar.gz
rm ${BUILD}_v1.7.tar.gz.md5

## PRESCORED
echo "2. PRESCORED"
mkdir -p $TARGET/prescored/${BUILD}_v1.7/noanno/
cd $TARGET/prescored/${BUILD}_v1.7/noanno/
URL="$DOWNLOAD_LOCATION/v1.7/$BUILD/whole_genome_SNVs.tsv.gz"
echo "  - download"
axel -a "$URL"
axel -a "$URL.md5"
axel -a "$URL.tbi"
axel -a "$URL.tbi.md5"
URL="$DOWNLOAD_LOCATION/v1.7/$BUILD/gnomad.genomes.r4.0.indel.tsv.gz"
axel -a "$URL"
axel -a "$URL.md5"
axel -a "$URL.tbi"
axel -a "$URL.tbi.md5"
echo "  - md5sum"
md5sum -c *.md5
rm *.md5




