# FreeCAD Ports Cache

## Overview

This repo hosts the [FreeCAD](http://www.freecadweb.org) ports [cache](https://en.wikipedia.org/wiki/Cache_(computing)) used to significantly reduce the FreeCAD [Travis-CI](http://www.travis-ci.org) build time on MacOS X.

## Motivation and Approach

Travis-CI limits Open Source build times to 50 minutes total per build.  FreeCAD, being a cross-platform QT application, requires installing Unix ports that consume nearly half of the availalble build time just to satisfy the pre-requisites causing frequent build timeouts.  In order to significantly reduce the build cycle time, the ports dependencies are pre-computed and deployed to GitHub as a cache archive for use during continuous integration builds. Early tests show that a ports [cache](https://en.wikipedia.org/wiki/Cache_(computing)) can be restored in just 3 to 4 minutes reducing the OSX build times by 20-25 minutes per cycle.  This enables reliable continuous integration builds for Mac OS X for all users and ensures that FreeCAD is a **good Travis-CI citizen** (use shared resources wisely).

The ports cache itself is maintained using [Travis-CI](https://travis-ci.org) to pre-compute, build and deploy the cache as a GitHub release asset.  FreeCAD continuous integration builds can optionally fetch and restore a ports cache before building FreeCAD by defining a single environment variable ```OSX_PORTS_CACHE``` in their respecitive [Travis-CI configuration file][freecad-config] and use [convenience functions](travis-helpers.sh) to simplify cache creation, deployment and usage from Travis.

Port cache archives are deployed on the [FreeCAD ports cache repo](.) under a release tag that corresponds to a specific FreeCAD version.  The cache is identitfied by a _cache descriptor_ of the form ```package_manager-pm_version-os_version-arch-build_date``` that is used to fetch and restore a suitable ports cache for the given build environment.  The combination of these two descriminators enable caching ports for specific package managers on various operating systems and architectures for any given FreeCAD release (currently only the [Homebrew package manager](http://brew.sh) is recommended and supported).  For example, the port cache archive named ```homebrew-0.9.5-10.9.5-x86_64-2016.03.21.tgz``` deployed under _release_ ```0.16``` on the FreeCAD-ports-cache GitHub repo is a FreeCAD 0.16 port cache for Homebrew 0.9.5 running on a 64-bit architecture under OS X 10.9.5 (Mavericks).  The 2016.03.21 suffix is merely a referential date; the helper functions will always fetch the latest cache file that satisfies the build environment requirements.

## Ports Cache Build Status <img src="https://cdn.travis-ci.org/images/travis-mascot-150-3791701416eeee8479e23fe4bb7edf4f.png" height="25"/>

| Master | 0.16 | 0.17 |
|:------:|:----:|:----:|
|[![Master][cache-build-status-master]][travis-branches]|[![0.16][cache-build-status-0.16]][travis-branches]|[![0.17][cache-build-status-0.17]][travis-branches]|

<!--Define URL handles for document porting between repos -->
[cache-build-status-0.16]: https://travis-ci.org/FreeCAD/FreeCAD-ports-cache.svg?branch=v0.16
[cache-build-status-0.17]: https://travis-ci.org/FreeCAD/FreeCAD-ports-cache.svg?branch=v0.17
[cache-build-status-master]: https://travis-ci.org/FreeCAD/FreeCAD-ports-cache.svg?branch=master
[travis-builds]: https://travis-ci.org/FreeCAD/FreeCAD-ports-cache/builds
[travis-branches]: https://travis-ci.org/FreeCAD/FreeCAD-ports-cache/branches

[freecad-repo]: https://github.com/FreeCAD/FreeCAD/
[freecad-config]: https://github.com/bblacey/FreeCAD-MacOS-CI/blob/unified/.travis.yml
<!--[freecad-config]: https://github.com/FreeCAD/FreeCAD/blob/unified/.travis.yml-->

## Installation and Usage

In order to use a ports cache, one must first be pre-computed (i.e. built) and deployed to GitHub. The ports cache [travis config file](.travis.yml) will fully initialize (i.e. bootstrap) a ports cache repo that contains nothing more than the config file itself.  Once available, clients can use a short list of convenience functions to employ am appropriate ports cache during a Travis CI build.

#### Cache Usage

To use an existing cache, only two convenience functions need be called after instantiating them in the current Travis shell context.  One function is used to set a cache context and the other to prime the local ports cache using the cache context.    Below, are the relevant excerpts that shows the cache usage.

```
before_install:
- |
# 1. Fetch helper functions and instantiate them in the Travis shell context
eval "$(curl -fsSL "https://raw.githubusercontent.com/${OSX_PORTS_CACHE}/travis-helpers/travis-helpers.sh")"

# 2. Create a helper cache context used by the convenience functions.  auth_token is only required if you are deploying a new cache to GitHub (see Deploying a Cache below)
cacheContext=$(create_helper_context repo="${OSX_PORTS_CACHE}" auth_token=${GH_TOKEN} release=${FREECAD_RELEASE})

# 3. Fetch the latest cache that matches the build requirement
prime_local_ports_cache $cacheContext
```
In FreeCAD, the [travis config file][freecad-config] controls the cache usage by setting the ```OSX_PORTS_CACHE``` environment variable that refers to the ports cache repo.  If the ```OSX_PORTS_CACHE``` variable is set, then the referenced ports cache repo will be used.

**NOTE:** The travis-helpers.sh may be moved to the main FreeCAD repo (decision pending)
#### Deploying a Cache
When forking the FreeCAD-ports-cache repo for development, you will need to create a GitHUB OAUTH token with deployment privileges and assign it to a secure Travis Environment variable via the Travis-CI Settings for use within the forked ports cache's [travis config file](.travis.yml).  Currently the environment variable used is ```GH_TOKEN```.  This is required for the ```gitHub_deploy_asset_to_release_named``` convenience function.  Below is an excerpt from the [.travis.yml](.travis.yml) file for creating and deploying a new cache archive.

```
GH_TOKEN=[secure]

script:
- |
# 1.  Create an archive of the installed ports with a cache descriptor for the current build environment
 portsArchive=$(create_ports_cache_archive /usr/local ${TRAVIS_BUILD_DIR}/$(ports_archive_filename))
 
 #2.  Deploy the cache archive to GitHub for the appropriate FreeCAD release
gitHub_deploy_asset_to_release_named $cacheContext $portsArchive ${FREECAD_RELEASE}
```

## Cache Maintenance

The cache is designed to be nearly self-maintaining however under some circumstances, the following manual maintenance steps are required to refresh and deploy new version of the ports cache. Furthermore, if the cache is not refreshed, then the cache benefits should gracefully degrade from missing or outdated ports available the cache that will need to be rebuilt during the FreeCAD process (e.g. port changes during a FreeCAD release version development cycle) to no cache available (e.g. port cache not created for new FreeCAD version development or new OS X).

* **Port Dependency Changes**
  * Updates to Homebrew formulae or Build Environment

		If a Homebrew formula is updated or the Travis environment changes, a refreshed cache can easily be built and deployed by simply restarting the last Travis-CI job.
		
  * Changed FreeCAD port dependency

		Whenever a port dependency is added to the [FreeCAD .travis.yml config file][freecad-config] the change must also be incorporated into to the [Ports Cache .travis.yml config file](.travis.yml).  Pushing the updated .travis.yml file to the FreeCAD-ports-cache repo on GitHub will start a Travis-CI job that will build and deploy the new ports cache archive.

* **New FreeCAD Release**

	When the development cycle commences for a new version of FreeCAD commences (e.g. **0.16** release -> **0.17** development), the corresponding release identifier must be created for the FreeCAD-ports-cache repo and defined in the .travis.yml configuration file to create the initial cache.

## Repo Branching Model
[GitFlow like](http://nvie.com/posts/a-successful-git-branching-model/)

## Futures
Longer term, we will develop a FreeCAD\_dependencies homebrew forumla to install the FreeCAD port dependencies.  The FreeCAD_dependencies formula will be a single ports dependency definition that both the FreeCAD cache and FreeCAD CI builds will use.

## Ports Cache Repo Maintainers
@ianrrees, @peterl94, @sgrogan, @wwmeyer, @yorik, @bblacey
