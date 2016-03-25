#!/bin/bash
####
#  These build helper convenience functions are used to access and manage github assets
#  as well as create and manage the freecad homebrew dependency ports cache
#
#  The helper functions that access GitHub accept, and expect, a "context variable" created by calling
#  create_helper_context() as the first argument following the optional arguments
#
##
shopt -s expand_aliases

####
#  Return a helper context object as a json string.  The context object contains
#  the GitHub repo, an OAUTH token and optionally a release identifier
#
#  create_helper_context repo auth_token release
#
#  repo = GitHub repo
#  auth_token = GitHub OAUTH token required for access to repo
#  release = GitHub release name to use for $repo (optional)
##
create_helper_context()
{
   local $*
   echo \{\"repo\":\"$repo\",\"auth_token\":\"$auth_token\",\"release\":\"$release\"\}
}

resolve_helper_context()
{
   eval "$(sed 's/^"\(.*\)"$/\1/' <<< ${1} | jq -r '@sh "repo=\(.repo); auth_token=\(.auth_token); release=\(.release)"')"
}

alias log='>&2 echo'

err()
{
   log "$*"
   return 1
}

realpath()
{
   echo "$(cd "$(dirname "$1")"; pwd)/$(basename "$1")"
}

####
#  Homebrew dependency ports cache convenience functions`
#
##
generate_ports_cache_descriptor()
{
   echo "homebrew-$(brew config | awk '/^HOMEBREW_VERSION/ {print $2}')-$(sw_vers -productVersion)-$(uname -m)"
}

ports_archive_filename()
{
   archive=${1-$(generate_ports_cache_descriptor)}
   echo "${archive}-$(date '+%Y.%m.%d').tgz"
}

####
#  Uninstall all installed ports
##
purge_local_ports_cache()
{
   brew list -1 | grep -v -e '^jq$' -e '^oniguruma$' | xargs brew uninstall --force
   return $?
}

####
#  Check the local ports cache state.  If any ports are outdated
#  then the cache is stale
##
local_ports_cache_is_stale()
{
   return $(( $(brew outdated | wc -l) > 0 ? 0 : 1 ))
}

####
#  Create a ports cache archive using tar -gzip
#
#  create_ports_cache_archive [archive path] [ports root]
#
#  $1 = ports root (defauls to homebrew --prefix)
#  $2 = tar archive path (defaults to $(ports_archive_filename))
##
create_ports_cache_archive()
{
   portsPrefix=${1-$(brew --prefix)}
   archive=$(realpath ${2-$(ports_archive_filename)})
   wd=$(pwd)

   log "Creating archive of ports stored in prefix ${portsPrefix} --> ${archive}"
   cd "${portsPrefix}"
   find . -maxdepth 1 ! -path . -print0 | xargs -0 tar --exclude='.git*' --exclude=var/postgres --exclude=lib/ocline --exclude=lib/node_modules/appium -czf ${archive}
   cd "${wd}"

   log "Archive: $(basename "${archive}"), size: $(du -h ${archive} | cut -f1)"
   echo ${archive}
}

restore_ports_cache_archive()
{
   portsPrefix=${1-$(brew --prefix)}
   archive=$(realpath ${2-$(ports_archive_filename)})

   log "Unarchiving ${archive} to ${portsPrefix}..."
   tar -xzf ${archive} -C $(brew --prefix)
   [ $? = 0 ] || return 1
}

####
#  Retrieve the GitHub download url for the latest port cache that
#  matches the port-cache descriptor/requirements.
#
#  contxt = GitHub context
#  latest_ports_cache_archive_url release
#  release = GitHub release name (defaults to latest GitHub release on the cache repo)
#
##
latest_GitHub_ports_cache_archive_url()
{
   resolve_helper_context ${1}
   rel=${2-${release}}

   cacheDescriptor=$(generate_ports_cache_descriptor)
   log "Searching GitHub ${repo} for a cache archive that matches descriptor ${cacheDescriptor} under release ${rel-latest}"

   if [ "${release}X" == "X" -a "${2}X" == "X" ]; then
      releaseAsJSON=$(gitHub_release_latest ${1})
   else
      releaseAsJSON=$(gitHub_release_named ${1} ${2-$release})
   fi
   [[ $releaseAsJSON == "" ]] && return 1

   cacheAssetAsJSON=$(echo $releaseAsJSON | jq -r --arg cacheDescriptor ${cacheDescriptor} '.assets | map(select(.name | contains($cacheDescriptor))?) | max_by(.id) | {name, created_at, browser_download_url}')
   [[ $cacheAssetAsJSON == "" ]] && return 1

   log "Found matching cache archive $(echo $cacheAssetAsJSON | jq -r '.name') created $(echo $cacheAssetAsJSON | jq -r '.created_at')..."
   echo $(echo $cacheAssetAsJSON | jq -r '.browser_download_url')
}

fetch_remote_ports_cache()
{
   downloadUrl=$(latest_GitHub_ports_cache_archive_url)
   log "Fetching remote ports cache: ${downloadUrl}"
   return 0
}

####
#  Initialize the local ports cache from GitHub ports archive
#
#  prime_local_ports_cache context release
#
#  context = github context object
#  release = ports-cache release (optional, defaults to context release)
prime_local_ports_cache()
{
   downloadURL=$(latest_GitHub_ports_cache_archive_url ${1} ${2})
   if [ "$downloadURL" == "" ]; then
      log "Port cache not currently available...  port caching is disabled."
      return 0
   fi
   cacheArchive="/tmp/$(basename $downloadURL)"

   log "Removing installed ports..."
   purge_local_ports_cache

   log "Updating homebrew formulae..."
   brew update

   log "Fetching lastest ports cache for FreeCAD ${release} from ${downloadURL} to ${cacheArchive}"

   curl -L -o ${cacheArchive} "${downloadURL}"
   if [ $? -ne 0 ]; then
      err "Failed to download ports cache"
      return 1
   fi

   log "Restoring ports archive..."
   restore_ports_cache_archive $(brew --prefix) ${cacheArchive}
   [ $? == 0 ] || return 1

   return 0
}

####
#  Return the releases available on context.repo as JSON
#
#  gitHub_relaeses context
#
#  context = gitHub context object
gitHub_releases()
{
   resolve_helper_context ${1}
   # Use an authentication token if available to reduce probability of failure due to GitHub rate limiting
   if [ {auth_token} != "" ]; then
       releasesAsJSON=$(curl -s -H "Authorization:token ${auth_token}"  "https://api.github.com/repos/${repo}/releases" | jq -c -r '.')
   else
       releasesAsJSON=$(curl -s "https://api.github.com/repos/${repo}/releases" | jq -c -r '.')
   fi
   if [ $? -ne 0 -o $(echo "$releasesAsJSON" | jq -r '(type == "object" and has("message"))') == "true" ]; then
      err "Failed to fetch available releases for repo" ${repo}
      log "${releasesAsJSON}"
      return 1
   fi
   echo "${releasesAsJSON}"
}

gitHub_release_named()
{
   namedReleaseAsJSON=$(gitHub_releases ${1} | jq -r --arg releaseName ${2-$release} '.[] | select(.name==$releaseName)')
   echo ${namedReleaseAsJSON}
}

gitHub_release_latest()
{
   latestReleaseAsJSON=$(gitHub_releases ${1} | jq -r 'max_by(.id)')
   echo ${latestReleaseAsJSON}
}

####
#  Deploy a release asset to the release named
#
#  gitHub_deploy_asset_to_releae_named archive name
#
#  context = GitHub context
#  archive = path to the cache archive to upload/deploy
#  release = GitHub cache repo release name.  Convention is FreeCAD release name.
#  replace = If set, replace existing assets with same name
##
gitHub_deploy_asset_to_release_named()
{
   resolve_helper_context ${1}

   assetPath=$(realpath ${2-$(ports_archive_filename)})
   assetName=$(basename ${assetPath})
   release=${3-$release}

   releaseAsJSON=$(gitHub_release_named ${1} ${release-latest})

   assetId=$(echo $releaseAsJSON | jq -r -c --arg assetName "${assetName}" '.assets[] | select(.name == $assetName) | .id')
   if [ "${assetId}" != "" ]; then
      log "Asset ${assetName} [$assetId] already exists will be replaced."
      gitHub_remove_release_asset_with_id ${1} ${assetId}
   fi

   log "Determining asset upload url for release: ${release-latest}"
   assetUploadUrl=$(echo $releaseAsJSON | jq -r ".upload_url" | cut -d '{' -f 1 | cut -c 1- )

   log "Deploying release asset $assetPath to $assetUploadUrl..."
   response=$(curl -X POST -H "Authorization:token ${auth_token}"  \
                   -H "Content-Type:application/x-compressed" --data-binary "@${assetPath}" \
                   "${assetUploadUrl}?name=${assetName}" | jq -r -c '.')
   if [ $? -ne 0 -o $(echo "$response" | jq -r '(type == "object" and has("message"))') == "true" ]; then
      err "Failed to upload release asset ${archive} to ${assetUploadUrl}"
      log "${response}"
      return 1
   fi
   return 0
}

gitHub_prune_assets_for_release_named()
{
   resolve_helper_context ${1}

   assetFilter=${2}
   retain=${3}
   release=${4-$release}

   if [ "${release}" == "" ]; then
      err "You must specify a release when uploading an asset to GitHub."
      return 1
   fi

   log "Cataloging assets for release ${release} on GitHub ${repo} that match filter ${2-all}"

   releaseAsJSON=$(gitHub_release_named ${1} ${release})
   [[ $releaseAsJSON == "" ]] && return 1

   assetsAsJSON=$(echo $releaseAsJSON | jq -r -c --arg assetNameFilter "${assetFilter}" \
               '[.assets | map(select(.name | contains($assetNameFilter))?) | sort_by(-.id)[] | {name: .name, id: .id, created: .created_at}]')
   [[ $assetsAsJSON == "" ]] && return 1

   log "Found $(echo $assetsAsJSON | jq '. | length') assets matching filter ${assetFilter} (listed in reverse chronological order):"
   unset archive; unset date; unset id
   while read -r line; do archive+=("$line"); done <<<"$(jq -r '.[] | .name'    <<<$assetsAsJSON)"
   while read -r line; do date+=("$line")   ; done <<<"$(jq -r '.[] | .created' <<<$assetsAsJSON)"
   while read -r line; do id+=("$line")     ; done <<<"$(jq -r '.[] | .id'      <<<$assetsAsJSON)"
   for (( i=0; i<${#archive[@]}; i++ )); do
       if [ $i -ge ${retain}  ]; then
          log "Delete $((i+1)): ${archive[$i]} [${id[$i]}] created: ${date[$i]}"
          gitHub_remove_release_asset_with_id ${1} ${id[$i]}
       else
          log "Retain $((i+1)): ${archive[$i]} [${id[$i]}] created: ${date[$i]}"
       fi
   done

   return 0
}

gitHub_remove_release_asset_with_id()
{
   resolve_helper_context ${1}
   assetId=${2}

   response=$(curl -w "%{response_code}" -X DELETE -s -H "Authorization:token ${auth_token}" "https://api.github.com/repos/${repo}/releases/assets/${assetId}")
   if [ $? -ne 0 -o "${response}" != "204" ]; then
       err "Failed to delete asset: ${assetId}..."
       log "$(jq -c -r '.' <<<${response})"
       return 1
   fi
   return 0
}


