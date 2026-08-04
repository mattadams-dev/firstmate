# Fork freshness: readings taken 2026-08-04 during fm-fork-freshness-sweep implementation

Enumeration completeness probe and per-fork compare-status, captured before the instrument existed.

```
$ gh repo list mattadams-dev --limit 100 --json nameWithOwner,isFork,isPrivate,isArchived,parent
mattadams-dev/firstmate fork=true private=false archived=false parent=kunchenguid/firstmate
mattadams-dev/dotfiles fork=false private=true archived=false parent=-/-
mattadams-dev/observe fork=false private=true archived=false parent=-/-
mattadams-dev/gnhf fork=true private=false archived=false parent=kunchenguid/gnhf
mattadams-dev/diagram fork=false private=true archived=false parent=-/-
mattadams-dev/fleet-evidence fork=false private=true archived=false parent=-/-
mattadams-dev/no-mistakes fork=true private=false archived=false parent=kunchenguid/no-mistakes
mattadams-dev/mobile_development_testing fork=false private=true archived=false parent=-/-

$ gh api "users/mattadams-dev/repos?per_page=100" --jq length   # public-only endpoint
3

$ gh api repos/kunchenguid/firstmate/compare/kunchenguid:main...mattadams-dev:main
{"ahead_by":6,"behind_by":20,"status":"diverged"}
$ gh api repos/kunchenguid/gnhf/compare/kunchenguid:main...mattadams-dev:main
{"ahead_by":2,"behind_by":0,"status":"ahead"}
$ gh api repos/kunchenguid/no-mistakes/compare/kunchenguid:main...mattadams-dev:main
{"ahead_by":0,"behind_by":28,"status":"behind"}
```
