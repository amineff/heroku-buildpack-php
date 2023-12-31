#!/usr/bin/env bash

set -eu
set -o pipefail

function s3cmd_get_progress() {
	len=0
	while read line; do
		if [[ "$len" -gt 0 ]]; then
			# repeat a backspace $len times
			# need to use seq; {1..$len} doesn't work
			printf '%0.s\b' $(seq 1 $len)
		fi
		echo -n "$line"
		len=${#line}
	done < <(grep --line-buffered -o -P '(?<=\[)[0-9]+ of [0-9]+(?=\])' | awk -W interactive '{print int($1/$3*100)"% ("$1"/"$3")"}') # filter only the "[1 of 99]" bits from 's3cmd get' output and divide using awk
}

remove=true

# process flags
optstring=":-:"
while getopts "$optstring" opt; do
	case $opt in
		-)
			case "$OPTARG" in
				no-remove)
					remove=false
					;;
				*)
					echo "Invalid option: --$OPTARG" >&2
					exit 2
					;;
			esac
	esac
done
# clear processed arguments
shift $((OPTIND-1))

if [[ $# -lt "2" || $# -gt "6" ]]; then
	cat >&2 <<-EOF
		Usage: $(basename $0) [--no-remove] DEST_BUCKET DEST_PREFIX [DEST_REGION [SOURCE_BUCKET SOURCE_PREFIX [SOURCE_REGION]]]
		  DEST_BUCKET:   destination S3 bucket name.
		  DEST_REGION:   destination bucket region, e.g. 's3.us-west-1'; default: '$\S3_REGION' or 's3'.
		  DEST_PREFIX:   destination prefix, e.g. '' or 'dist-stable/'.
		  SOURCE_BUCKET: source S3 bucket name; default: '\$S3_BUCKET'.
		  SOURCE_REGION: source bucket region; default: <DEST_REGION>.
		  SOURCE_PREFIX: source prefix; default: '\$S3_PREFIX'.
		  --no-remove: no removal of destination packages that are not in source bucket.
	EOF
	exit 2
fi

dst_bucket=$1; shift
dst_prefix=$1; shift
if [[ $# -gt 2 ]]; then
	# region name given
	dst_region=$1; shift
else
	dst_region=${S3_REGION:-"s3"}
fi

src_bucket=${1:-$S3_BUCKET}; shift || true
src_prefix=${1:-$S3_PREFIX}; shift || true
if [[ $# == "1" ]]; then
	# region name given
	src_region=$1; shift
else
	src_region=$dst_region
fi

s3cmd_src_host_options="--host=${src_region}.amazonaws.com --host-bucket=%(bucket)s.${src_region}.amazonaws.com"
s3cmd_dst_host_options="--host=${dst_region}.amazonaws.com --host-bucket=%(bucket)s.${dst_region}.amazonaws.com"

if [[ "$src_region" != "$dst_region" ]]; then
	echo "CAUTION: Source and destination regions differ. Sync may run into rate limits." >&2
	echo "" >&2
	s3cmd_cp_host_options=""
else
	s3cmd_cp_host_options=$s3cmd_src_host_options
fi

src_tmp=$(mktemp -d -t "src-repo.XXXXX")
dst_tmp=$(mktemp -d -t "dst-repo.XXXXX")
here=$(cd $(dirname $0); pwd)

# clean up at the end
trap 'rm -rf $src_tmp $dst_tmp;' EXIT

echo -n "Fetching source's manifests
  from s3://${src_bucket}/${src_prefix}... " >&2
(
	cd $src_tmp
	out=$(s3cmd ${s3cmd_src_host_options} --ssl get s3://${src_bucket}/${src_prefix}packages.json 2>&1) || { echo -e "No packages.json in source repo:\n$out" >&2; exit 1; }
	s3cmd ${s3cmd_src_host_options} --ssl --progress get s3://${src_bucket}/${src_prefix}*.composer.json 2>&1 | tee download.log | s3cmd_get_progress >&2 || { echo -e "failed! Error:\n$(cat download.log)" >&2; exit 1; }
	ls *.composer.json 2>/dev/null 1>&2 || { echo "failed; no manifests found!" >&2; exit 1; }
	rm download.log
)
echo "" >&2

# this mkrepo.sh call won't actually download, but use the given *.composer.json, and echo a generated packages.json
# we use this to compare to the downloaded packages.json
S3_REGION=$src_region $here/mkrepo.sh $src_bucket $src_prefix ${src_tmp}/*.composer.json 2>/dev/null | python -c 'import sys, json; sys.exit(json.load(open(sys.argv[1])) != json.load(sys.stdin))' ${src_tmp}/packages.json || {
	cat >&2 <<-EOF
		WARNING: packages.json from source does not match its list of manifests!
		 You should run 'mkrepo.sh' to update, or ask the bucket maintainers to do so.
	EOF
	read -p "Would you like to abort this operation? [Yn] " proceed
	[[ ! $proceed =~ [nN]o* ]] && exit 1 # yes is the default so doing yes | sync.sh won't do something stupid
}

echo -n "Fetching destination's manifests
  from s3://${dst_bucket}/${dst_prefix}... " >&2
(
	cd $dst_tmp
	s3cmd ${s3cmd_dst_host_options} --ssl --progress get s3://${dst_bucket}/${dst_prefix}*.composer.json 2>&1 | tee download.log | s3cmd_get_progress >&2 || { echo -e "failed! Error:\n$(cat download.log)" >&2; exit 1; }
	rm download.log
)
echo "" >&2

comm=$(comm <(cd $src_tmp; ls -1 *.composer.json) <(cd $dst_tmp; ls -1 *.composer.json 2> /dev/null)) # comm produces three columns of output: entries only in left file, entries only in right file, entries in both
add_manifests=$(echo "$comm" | grep '^\S' || true) # no tabs means output in col 1 = files only in src
remove_manifests=$(echo "$comm" | grep '^\s\S' | cut -c2- || true) # one tab means output in col 2 = files only in dst
common=$(echo "$comm" | grep '^\s\s' | cut -c3- || true) # two tabs means output in col 3 = files in both
update_manifests=()
ignore_manifests=()
for filename in $common; do
	result=0
	python <(cat <<-'PYTHON' # beware of single quotes in body
		from __future__ import print_function
		import sys, json, os, datetime
		# for python 2+3 compat
		def stderrprint(*args, **kwargs):
		    print(*args, file=sys.stderr, **kwargs)
		src_manifest = json.load(open(sys.argv[1]))
		dst_manifest = json.load(open(sys.argv[2]))
		# remove URLs so they don't interfere with comparison
		src_manifest.get("dist", {}).pop("url", None)
		dst_manifest.get("dist", {}).pop("url", None)
		# same for times, but we'll look at them
		try:
		    src_time = datetime.datetime.strptime(src_manifest.pop("time"), "%Y-%m-%d %H:%M:%S") # UTC
		except (KeyError, ValueError):
		    src_time = datetime.datetime.utcfromtimestamp(os.path.getmtime(sys.argv[1]))
		    stderrprint("WARNING: source manifest {} has invalid time entry, using mtime: {}".format(os.path.basename(sys.argv[1]), src_time.isoformat()))
		try:
		    dst_time = datetime.datetime.strptime(dst_manifest.pop("time"), "%Y-%m-%d %H:%M:%S") # UTC
		except (KeyError, ValueError):
		    dst_time = datetime.datetime.utcfromtimestamp(os.path.getmtime(sys.argv[2]))
		    stderrprint("WARNING: destination manifest {} has invalid time entry, using mtime: {}".format(os.path.basename(sys.argv[2]), dst_time.isoformat()))
		# a newer source time means we will copy
		if src_time > dst_time:
		    sys.exit(0)
		else:
		    # 1 = content identical, src_time = dst_time (up to date)
		    # 3 = content different, src_time = dst_time (weird)
		    # 5 = content identical, src_time < dst_time (probably needs sync the other way)
		    # 7 = content different, src_time < dst_time (probably needs sync the other way)
		    ret = 1
		    ret = ret | (src_manifest != dst_manifest)<<1
		    ret = ret | (src_time < dst_time)<<2
		    sys.exit(ret)
		PYTHON
	) $src_tmp/$filename $dst_tmp/$filename || result=$?
	if [[ $result -eq 0 ]]; then
		update_manifests+=($filename)
	elif [[ $result != "1" ]]; then
		case $result in
			3)
				ignore_manifests+=("$filename (contents differ, time fields identical!?)")
				;;
			5)
				ignore_manifests+=("$filename (contents match, destination manifest newer)")
				;;
			7)
				ignore_manifests+=("$filename (contents differ, destination manifest newer)")
				;;
		esac
	fi
done

cat >&2 <<-EOF

	WARNING: POTENTIALLY DESTRUCTIVE ACTION!

	The following packages will be IGNORED:
	$(IFS=$'\n'; echo "${ignore_manifests[*]:-(none)}" | sed -e 's/^/  - /' -e 's/.composer.json//')

	The following packages will be ADDED
	 from s3://${src_bucket}/${src_prefix}
	   to s3://${dst_bucket}/${dst_prefix}:
	$(echo "${add_manifests:-(none)}" | sed -e 's/^/  - /' -e 's/.composer.json$//')

	The following packages will be UPDATED (source manifest is newer)
	 from s3://${src_bucket}/${src_prefix}
	   to s3://${dst_bucket}/${dst_prefix}:
	$(IFS=$'\n'; echo "${update_manifests[*]:-(none)}" | sed -e 's/^/  - /' -e 's/.composer.json$//')

	The following packages will $($remove || echo -n "NOT ")be REMOVED
	 from s3://${dst_bucket}/${dst_prefix}$($remove && echo -n ":")$($remove || echo -ne "\n because '--no-remove' was given:")
	$(echo "${remove_manifests:-(none)}" | sed -e 's/^/  - /' -e 's/.composer.json$//')

EOF

# clear remove_manifests if --no-remove given
$remove || remove_manifests=

if [[ ! "$add_manifests" && ! "$remove_manifests" && "${#update_manifests[@]}" -eq 0 ]]; then
	echo "Nothing to do. Aborting." >&2
	exit
fi

read -p "Are you sure you want to sync to destination & regenerate packages.json? [yN] " proceed

[[ ! $proceed =~ [yY](es)* ]] && exit

echo "" >&2

copied_files=()
for manifest in $add_manifests ${update_manifests[@]:-}; do
	echo "Copying ${manifest%.composer.json}:" >&2
	if filename=$(cat ${src_tmp}/${manifest} | python <(cat <<-'PYTHON' # beware of single quotes in body
		import sys, json, re;
		manifest=json.load(sys.stdin)
		# pattern for basically "https://lang-php.(s3.us-east-1|s3).amazonaws.com/dist-heroku-22-stable/"
		# this ensures old packages are correctly handled even when they do not contain the region in the URL
		s3_url_re=re.escape("https://{}.".format(sys.argv[1]))
		s3_url_re+="(?:{}|s3)".format(re.escape(sys.argv[2]))
		s3_url_re+=re.escape(".amazonaws.com/{}".format(sys.argv[3]))
		s3_url_re+="(.+)"
		url=manifest.get("dist",{}).get("url","")
		r = re.match(s3_url_re, url)
		if r:
		    # rewrite dist URL in manifest to destination bucket
		    manifest["dist"]["url"] = "https://"+sys.argv[4]+"."+sys.argv[5]+".amazonaws.com/"+sys.argv[6]+r.group(1)
		    json.dump(manifest, open(sys.argv[7], "w"), sort_keys=True)
		    print(r.group(1))
		else:
		    # dist URL does not match https://${dst_bucket}.(${dst_region}|s3).amazonaws.com/${dst_prefix}
		    print(url)
		    sys.exit(1)
		PYTHON
	) $src_bucket $src_region $src_prefix $dst_bucket $dst_region $dst_prefix ${dst_tmp}/${manifest})
	then
		# the dist URL in the source's manifest points to the source bucket, so we copy the file to the dest bucket
		echo -n "  - copying '$filename'... " >&2
		out=$(s3cmd ${s3cmd_cp_host_options} --ssl cp s3://${src_bucket}/${src_prefix}${filename} s3://${dst_bucket}/${dst_prefix}${filename} 2>&1) || { echo -e "failed! Error:\n$out" >&2; exit 1; }
		copied_files+=("$filename")
		echo "done." >&2
	else
		# the dist URL points somewhere else, so we are not touching that
		echo "  - WARNING: not copying '$filename' (in manifest 'dist.url')!" >&2
		# just copy over the manifest (in the above branch, the Python script in the if expression already took care of that)
		cp ${src_tmp}/${manifest} ${dst_tmp}/${manifest}
	fi
	echo -n "  - copying manifest file '$manifest'... " >&2
	out=$(s3cmd ${s3cmd_cp_host_options} --ssl -m application/json put ${dst_tmp}/${manifest} s3://${dst_bucket}/${dst_prefix}${manifest} 2>&1) || { echo -e "failed! Error:\n$out" >&2; exit 1; }
	echo "done." >&2
done

remove_files=()
for manifest in $remove_manifests; do
	echo "Removing ${manifest%.composer.json}:" >&2
	if filename=$(cat ${dst_tmp}/${manifest} | python <(cat <<-'PYTHON' # beware of single quotes in body
		import sys, json, re;
		manifest=json.load(sys.stdin)
		# pattern for basically "https://lang-php.(s3.us-east-1|s3).amazonaws.com/dist-heroku-22-stable/"
		# this ensures old packages are correctly handled even when they do not contain the region in the URL
		s3_url_re=re.escape("https://{}.".format(sys.argv[1]))
		s3_url_re+="(?:{}|s3)".format(re.escape(sys.argv[2]))
		s3_url_re+=re.escape(".amazonaws.com/{}".format(sys.argv[3]))
		s3_url_re+="(.+)"
		url=manifest.get("dist",{}).get("url","")
		r = re.match(s3_url_re, url)
		if r:
		    print(r.group(1))
		else:
		    # dist URL does not match https://${dst_bucket}.(${dst_region}|s3).amazonaws.com/${dst_prefix}
		    print(url)
		    sys.exit(1)
		PYTHON
	) $dst_bucket $dst_region $dst_prefix)
	then
		# the dist URL in the destination manifest points to the destination bucket, so we remove that file at the end of the script...
		if [[ " ${copied_files[@]:-} " =~ " $filename " ]]; then
			# ...unless it was copied earlier (may happen if a new/updated manifest points to the same file name that this to-be-removed one is using)
			echo "  - NOTICE: keeping newly copied '$filename'!" >&2
		else
			echo "  - queued '$filename' for removal." >&2
			remove_files+=("$filename")
		fi
	else
		# the dist URL points somewhere else, so we are not touching that
		echo "  - WARNING: not removing '$filename' (in manifest 'dist.url')!" >&2
	fi
	echo -n "  - removing manifest file '$manifest'... " >&2
	out=$(s3cmd ${s3cmd_dst_host_options} --ssl rm s3://${dst_bucket}/${dst_prefix}${manifest} 2>&1) || { echo -e "failed! Error:\n$out" >&2; exit 1; }
	rm ${dst_tmp}/${manifest}
	echo "done." >&2
done

echo "" >&2

echo -n "Generating and uploading packages.json... " >&2
out=$(cd $dst_tmp; S3_REGION=$dst_region $here/mkrepo.sh --upload $dst_bucket $dst_prefix *.composer.json 2>&1) || { echo -e "failed! Error:\n$out" >&2; exit 1; }
echo "done!
$(echo "$out" | grep -E '^Public URL' | sed 's/^Public URL of the object is: http:/Public URL of the repository is: https:/')
" >&2

if [[ "${#remove_files[@]}" != "0" ]]; then
	echo "Removing files queued for deletion from destination:" >&2
	for filename in "${remove_files[@]}"; do
		echo -n "  - removing '$filename'... " >&2
		out=$(s3cmd ${s3cmd_dst_host_options} --ssl rm s3://${dst_bucket}/${dst_prefix}${filename} 2>&1) && echo "done." >&2 || echo -e "failed! Error:\n$out" >&2
	done
	echo "" >&2
fi

echo "Sync complete.
" >&2
