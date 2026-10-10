## vdesk host

Chromium is already running. Do not run `patchright-cli open`, `patchright-cli close`, or `playwright-cli`. `open` starts a different browser and drops the vdesk profile. `close` is refused on the host context.

```bash
patchright-cli attach --cdp=http://127.0.0.1:9222 --context=host
```

`--context=host` is required. The default isolated context cannot see the profile cookies. Leave the browser with `patchright-cli detach`. After `vdesk` prints `restarted=yes`, run attach again before the next command.
