# Endpoint binding migration: raw pre-migration observation

Raw capture from the one-shot `endpoint_task_id` binding migration.
Committed before any analysis or repair, because the observed herdr session is volatile and this reading is unreproducible once it ends.

## Environment

```
captured_at_utc=2026-08-01T17:49:53Z
herdr_version=herdr 0.7.5
fm_home=/home/jamada/code/personal/firstmate
```

## Affected records: `window=` present, `endpoint_task_id=` absent

```
### fm-supervision-successor-arming.meta
window=1:wB:p1F
worktree=/home/jamada/.treehouse/firstmate-8bf1b0/2/firstmate
project=/home/jamada/code/personal/firstmate
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-fm-supervision-successor-arming
model=opus
effort=high
backend=herdr
herdr_session=1
herdr_workspace_id=wB
herdr_tab_id=wB:t1F
herdr_pane_id=wB:p1F
pr=https://github.com/mattadams-dev/firstmate/pull/3
pr_head=32b26f1edc256bd0a6c6d137792d6bb4af8da7ec

### observe-fixture-corpus.meta
window=1:wB:p1A
worktree=/home/jamada/.treehouse/observe-f7c3df/3/observe
project=/home/jamada/code/personal/firstmate/projects/observe
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-observe-fixture-corpus
model=opus
effort=high
backend=herdr
herdr_session=1
herdr_workspace_id=wB
herdr_tab_id=wB:t1A
herdr_pane_id=wB:p1A

### observe-m1-slice.meta
window=1:wB:p19
worktree=/home/jamada/.treehouse/observe-f7c3df/2/observe
project=/home/jamada/code/personal/firstmate/projects/observe
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-observe-m1-slice
model=opus
effort=high
backend=herdr
herdr_session=1
herdr_workspace_id=wB
herdr_tab_id=wB:t19
herdr_pane_id=wB:p19
pr=https://github.com/mattadams-dev/observe/pull/6
pr_head=a8a9dd4b3ed836b5a1a401bcd329f2d6dcbe8926

### observe-ocr-bakeoff.meta
window=1:wB:p1B
worktree=/home/jamada/.treehouse/observe-f7c3df/4/observe
project=/home/jamada/code/personal/firstmate/projects/observe
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-observe-ocr-bakeoff
model=opus
effort=high
backend=herdr
herdr_session=1
herdr_workspace_id=wB
herdr_tab_id=wB:t1B
herdr_pane_id=wB:p1B

## fm_backend_herdr_workspace_find_all 1 (home label: firstmate)
wB
## fm_backend_herdr_list_live 1
1:wB:p19	fm-observe-m1-slice
1:wB:p1A	fm-observe-fixture-corpus
1:wB:p1B	fm-observe-ocr-bakeoff
```

## Live herdr inventory read

```
## fm_backend_herdr_workspace_find_all 1 (home label: firstmate)
wB
## fm_backend_herdr_list_live 1
1:wB:p19	fm-observe-m1-slice
1:wB:p1A	fm-observe-fixture-corpus
1:wB:p1B	fm-observe-ocr-bakeoff
1:wB:p1F	fm-fm-supervision-successor-arming
```

## Raw herdr CLI output backing that read

```
## raw: herdr tab list --workspace wB (session 1)
{"id":"cli:tab:list","result":{"tabs":[{"agent_status":"idle","focused":false,"label":"fm-observe-m1-slice","number":41,"pane_count":1,"tab_id":"wB:t19","workspace_id":"wB"},{"agent_status":"working","focused":false,"label":"fm-observe-fixture-corpus","number":42,"pane_count":1,"tab_id":"wB:t1A","workspace_id":"wB"},{"agent_status":"idle","focused":false,"label":"fm-observe-ocr-bakeoff","number":43,"pane_count":1,"tab_id":"wB:t1B","workspace_id":"wB"},{"agent_status":"idle","focused":false,"label":"fm-fm-supervision-successor-arming","number":47,"pane_count":1,"tab_id":"wB:t1F","workspace_id":"wB"}],"type":"tab_list"}}

## raw: herdr pane list --workspace wB (session 1)
{"id":"cli:pane:list","result":{"panes":[{"agent":"claude","agent_status":"idle","cwd":"/home/jamada/code/personal/firstmate/projects/observe","focused":false,"foreground_cwd":"/home/jamada/.treehouse/observe-f7c3df/2/observe","pane_id":"wB:p19","revision":2,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":46},"tab_id":"wB:t19","terminal_id":"term_657e30e1a2ecb14","terminal_title":"✳ Build M1 static vertical slice for observer system","terminal_title_stripped":"Build M1 static vertical slice for observer system","workspace_id":"wB"},{"agent":"claude","agent_status":"working","cwd":"/home/jamada/code/personal/firstmate/projects/observe","focused":false,"foreground_cwd":"/home/jamada/.treehouse/observe-f7c3df/3/observe","pane_id":"wB:p1A","revision":2,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":46},"tab_id":"wB:t1A","terminal_id":"term_657e30e63d28815","terminal_title":"⠂ Build problem fixture corpus with simulator validation","terminal_title_stripped":"Build problem fixture corpus with simulator validation","workspace_id":"wB"},{"agent":"claude","agent_status":"idle","cwd":"/home/jamada/code/personal/firstmate/projects/observe","focused":false,"foreground_cwd":"/home/jamada/.treehouse/observe-f7c3df/4/observe","pane_id":"wB:p1B","revision":2,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":46},"tab_id":"wB:t1B","terminal_id":"term_657e30e9ec53f16","terminal_title":"✳ Run OCR engine bake-off and record selection decision","terminal_title_stripped":"Run OCR engine bake-off and record selection decision","workspace_id":"wB"},{"agent":"claude","agent_status":"idle","cwd":"/home/jamada/code/personal/firstmate","focused":false,"foreground_cwd":"/home/jamada/.treehouse/firstmate-8bf1b0/2/firstmate","pane_id":"wB:p1F","revision":2,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":46},"tab_id":"wB:t1F","terminal_id":"term_657ed95f20b3b1a","terminal_title":"✳ Fix supervisor successor arming and parked lane cadence","terminal_title_stripped":"Fix supervisor successor arming and parked lane cadence","workspace_id":"wB"}],"type":"pane_list"}}
```
